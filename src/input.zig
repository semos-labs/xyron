// input.zig — Input subsystem: line editor + key parser + display + history.
//
// Phase 8: integrated syntax highlighting. refreshLine uses the
// highlight module to emit ANSI-colored output when a highlight
// context is available.

const std = @import("std");
const posix = std.posix;
const keys = @import("keys.zig");
const editor_mod = @import("editor.zig");
const history_mod = @import("history.zig");
const highlight = @import("highlight.zig");
const environ_mod = @import("environ.zig");
const complete_mod = @import("complete.zig");
const complete_help = @import("complete_help.zig");
const overlay = @import("overlay.zig");
const lua_api = @import("lua_api.zig");
const history_search = @import("history_search.zig");
const history_db_mod = @import("history_db.zig");

/// Highlight context passed through from the shell.
pub const HighlightCtx = struct {
    cache: *highlight.CommandCache,
    env: *const environ_mod.Environ,
    help_cache: ?*complete_help.HelpCache = null,
    lua: ?lua_api.LuaState = null,
};

pub const ReadResult = union(enum) {
    line: []const u8,
    interrupt,
    eof,
};

/// Number of extra lines in the prompt (0 = single line).
pub var prompt_extra_lines: usize = 0;

/// Set to true for the first render of a new prompt (after command output).
/// Prevents moving up over command output.
pub var prompt_fresh: bool = true;

/// Estimated cursor row (1-based). Updated by the shell after output/clear.
/// Used by the overlay to decide above/below when DSR is unavailable.
pub var cursor_row_estimate: usize = 0;

/// Read a line with history navigation and syntax highlighting.
pub fn readLine(
    ed: *editor_mod.Editor,
    prompt_str: []const u8,
    hist: ?*history_mod.History,
    hl: ?*const HighlightCtx,
) !ReadResult {
    const stdout = std.fs.File.stdout();

    if (hist) |h| h.beginNavigation(ed.content());

    // Cache cursor row for overlay direction (DSR is safe here,
    // before the key loop starts — no input to interfere with).
    if (overlay.enabled) complete_mod.cachePromptRow();

    // If a background git refresh is in-flight (e.g. cold start), wait
    // briefly for it to finish so the first prompt shows git info without
    // requiring a keystroke. This only fires once per readLine entry.
    {
        const git_info_mod = @import("git_info.zig");
        if (git_info_mod.isRefreshing()) {
            var waited: usize = 0;
            while (waited < 500) {
                // Check stdin so we bail immediately if the user types
                var fds: [1]std.posix.pollfd = .{
                    .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
                };
                const ready = std.posix.poll(&fds, 50) catch break;
                if (ready > 0) break;
                waited += 50;
                if (!git_info_mod.isRefreshing()) break;
            }
            if (!git_info_mod.isRefreshing()) {
                // Git data arrived — rebuild and overwrite the current prompt
                const prompt_mod = @import("prompt.zig");
                var pctx = prompt_mod.buildContext(prompt_last_exit, prompt_last_duration, prompt_job_count);
                pctx.vim_normal = (ed.mode == .normal or ed.mode == .visual);
                var pbuf: [prompt_mod.MAX_PROMPT]u8 = undefined;
                const pr = prompt_mod.render(&pbuf, &pctx, prompt_lua);
                refreshLine(stdout, pr.text, ed, hl);
                prompt_extra_lines = if (pr.line_count > 1) pr.line_count - 1 else 0;
            }
        }
    }

    // Pending operator for vim (e.g., 'd' waiting for motion)
    var pending_op: u8 = 0;

    while (true) {
        const key = try keys.readKey();

        // Keys that work in both modes
        switch (key) {
            .paste_begin => {
                // Bracketed paste: read all input until paste_end,
                // insert it all at once, then do a single refresh.
                complete_mod.dismissInline(stdout);
                var paste_buf: [editor_mod.MAX_LINE]u8 = undefined;
                var paste_len: usize = 0;
                while (true) {
                    const pk = keys.readKey() catch break;
                    switch (pk) {
                        .paste_end => break,
                        .char => |ch| {
                            if (paste_len < paste_buf.len) {
                                paste_buf[paste_len] = ch;
                                paste_len += 1;
                            }
                        },
                        .utf8 => |u| {
                            const slice = u.bytes[0..u.len];
                            if (paste_len + slice.len <= paste_buf.len) {
                                @memcpy(paste_buf[paste_len..][0..slice.len], slice);
                                paste_len += slice.len;
                            }
                        },
                        .enter => {
                            // Newlines in paste come as enter keys — insert literal newline
                            if (paste_len < paste_buf.len) {
                                paste_buf[paste_len] = '\n';
                                paste_len += 1;
                            }
                        },
                        .tab => {
                            if (paste_len < paste_buf.len) {
                                paste_buf[paste_len] = '\t';
                                paste_len += 1;
                            }
                        },
                        else => {},
                    }
                }
                if (paste_len > 0) {
                    ed.insertBytes(paste_buf[0..paste_len]);
                }
                refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                continue;
            },
            .resize => {
                // Terminal resized — re-render prompt cleanly.
                // Block re-rendering requires terminal emulator support
                // (Attyx tracks blocks via events and re-renders on its side).
                complete_mod.dismissInline(stdout);
                const ts = overlay.getTermSize();
                cursor_row_estimate = @min(cursor_row_estimate, ts.rows);
                refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                continue;
            },
            .enter => {
                // If overlay is active, accept the selection — unless typed
                // text already matches the selected candidate exactly (just
                // dismiss and execute instead of re-inserting with a space).
                if (complete_mod.inline_state.active and complete_mod.inline_state.scored_count > 0) {
                    const s = &complete_mod.inline_state;
                    const candidate_text = s.all.items[s.scored_indices[s.selected]].textSlice();
                    const typed = ed.content()[s.word_start..ed.cursor];
                    if (std.mem.eql(u8, candidate_text, typed)) {
                        complete_mod.dismissInline(stdout);
                    } else {
                        _ = complete_mod.acceptInline(ed, stdout);
                        refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                        continue;
                    }
                }
                ed.mode = .insert;
                {
                    // Move to first prompt line, clear from there,
                    // re-render prompt + content, then newline
                    var clr_buf: [8192]u8 = undefined;
                    var clr_pos: usize = 0;
                    if (prompt_extra_lines > 0) {
                        const up = std.fmt.bufPrint(clr_buf[clr_pos..], "\x1b[{d}A", .{prompt_extra_lines}) catch "";
                        clr_pos += up.len;
                    }
                    clr_pos += cp(clr_buf[clr_pos..], "\r\x1b[J");
                    clr_pos += cp(clr_buf[clr_pos..], prompt_str);
                    const hl_mod = @import("highlight.zig");
                    if (hl) |ctx| {
                        clr_pos += hl_mod.renderHighlighted(clr_buf[clr_pos..], ed.content(), ctx.cache, ctx.env, ctx.lua);
                    } else {
                        clr_pos += cp(clr_buf[clr_pos..], ed.content());
                    }
                    clr_pos += cp(clr_buf[clr_pos..], "\r\n");
                    stdout.writeAll(clr_buf[0..clr_pos]) catch {};
                }
                if (hist) |h| h.resetNavigation();
                return .{ .line = ed.content() };
            },
            .ctrl_c => {
                complete_mod.dismissInline(stdout);
                ed.mode = .insert;
                stdout.writeAll("^C\r\n") catch {};
                ed.clear();
                if (hist) |h| h.resetNavigation();
                return .interrupt;
            },
            .ctrl_d => {
                if (ed.isEmpty()) {
                    stdout.writeAll("\r\n") catch {};
                    return .eof;
                }
            },
            .ctrl_l => {
                stdout.writeAll("\x1b[2J\x1b[H") catch {};
                cursor_row_estimate = 1 + prompt_extra_lines; // reset to top
                refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                continue;
            },
            .ctrl_r => {
                // Launch history search
                const result = history_search.run(history_db_ref, stdout, .insert);
                switch (result) {
                    .selected => |cmd| {
                        ed.setContent(cmd);
                    },
                    .cancelled => {},
                }
                refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                continue;
            },
            .up, .ctrl_p => {
                if (complete_mod.inline_state.active) {
                    if (hl) |ctx| {
                        complete_mod.cycleInlineBack(ed, stdout, prompt_str, ctx);
                        continue;
                    }
                }
                if (hist) |h| {
                    if (h.navigateUp()) |entry| {
                        ed.setContent(entry);
                        refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                    }
                }
                continue;
            },
            .down, .ctrl_n => {
                if (complete_mod.inline_state.active) {
                    if (hl) |ctx| {
                        complete_mod.cycleInline(ed, stdout, prompt_str, ctx);
                        continue;
                    }
                }
                if (hist) |h| {
                    if (h.navigateDown()) |entry| {
                        ed.setContent(entry);
                        refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                    }
                }
                continue;
            },
            else => {},
        }

        // Mode-specific handling
        if (ed.vim_enabled and ed.mode == .visual) {
            handleVisualMode(ed, key);
            refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
            continue;
        }
        if (ed.vim_enabled and ed.mode == .normal) {
            handleNormalMode(ed, key, &pending_op);
            refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
            continue;
        }

        // Insert mode (or vim disabled)
        var content_changed = false;
        switch (key) {
            .ctrl_space => {
                // Ctrl+Space: trigger/show completion overlay
                if (overlay.enabled) {
                    if (hl) |ctx| {
                        const ipc_mod = @import("ipc.zig");
                        if (ipc_mod.attyx_connected) {
                            complete_mod.triggerInline(ed, stdout, prompt_str, ctx.env, ctx.cache, ctx.help_cache, prompt_lua, ctx);
                            if (!complete_mod.inline_state.active) {
                                refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                            }
                        } else if (!complete_mod.inline_state.active) {
                            // No IPC, no active overlay: run picker
                            const result = complete_mod.runPicker(
                                ed, stdout, prompt_str, ctx.env, ctx.cache,
                                ctx.help_cache, prompt_lua, ctx,
                            );
                            if (result == .interrupted) {
                                stdout.writeAll("^C\r\n") catch {};
                                ed.clear();
                                if (hist) |h| h.resetNavigation();
                                return .interrupt;
                            }
                            content_changed = true;
                        }
                    }
                }
                if (!content_changed) continue;
            },
            .tab => {
                // Tab: complete (accept selection if overlay active,
                // otherwise trigger and auto-accept single match)
                if (overlay.enabled) {
                    if (hl) |ctx| {
                        const ipc_mod = @import("ipc.zig");
                        if (ipc_mod.attyx_connected) {
                            if (complete_mod.inline_state.active) {
                                // Accept current selection
                                if (complete_mod.acceptInline(ed, stdout)) {
                                    content_changed = true;
                                }
                            } else {
                                // Trigger and auto-accept if single match
                                complete_mod.triggerInline(ed, stdout, prompt_str, ctx.env, ctx.cache, ctx.help_cache, prompt_lua, ctx);
                                if (complete_mod.inline_state.active and complete_mod.inline_state.scored_count == 1) {
                                    if (complete_mod.acceptInline(ed, stdout)) {
                                        content_changed = true;
                                    }
                                }
                                if (!complete_mod.inline_state.active and !content_changed) {
                                    refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                                }
                            }
                        } else if (complete_mod.inline_state.active) {
                            if (complete_mod.acceptInline(ed, stdout)) {
                                content_changed = true;
                            }
                        } else {
                            const result = complete_mod.runPicker(
                                ed, stdout, prompt_str, ctx.env, ctx.cache,
                                ctx.help_cache, prompt_lua, ctx,
                            );
                            if (result == .interrupted) {
                                stdout.writeAll("^C\r\n") catch {};
                                ed.clear();
                                if (hist) |h| h.resetNavigation();
                                return .interrupt;
                            }
                            content_changed = true;
                        }
                    }
                }
                if (!content_changed) continue;
            },
            .escape => {
                if (complete_mod.inline_state.active) {
                    complete_mod.dismissInline(stdout);
                } else if (ed.vim_enabled) {
                    ed.mode = .normal;
                    ed.clampNormal();
                }
            },
            // Movement
            .left, .ctrl_b => {
                complete_mod.dismissInline(stdout);
                ed.moveLeft();
            },
            .right, .ctrl_f => {
                if (complete_mod.inline_state.active) {
                    _ = complete_mod.acceptInline(ed, stdout);
                    content_changed = true;
                } else if (ed.cursor == ed.len) {
                    if (getGhostSuggestion(ed)) |ghost| {
                        ed.setContent(ghost);
                        refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                        continue;
                    }
                }
                ed.moveRight();
            },
            .home, .ctrl_a => { complete_mod.dismissInline(stdout); ed.moveHome(); },
            .end_key, .ctrl_e => { complete_mod.dismissInline(stdout); ed.moveEnd(); },
            .alt_b => { complete_mod.dismissInline(stdout); ed.moveWordBackward(); },
            .alt_f => { complete_mod.dismissInline(stdout); ed.moveWordForward(); },
            // Deletion
            .backspace => { ed.backspace(); content_changed = true; },
            .delete => { ed.delete(); content_changed = true; },
            .ctrl_k => { ed.killToEnd(); content_changed = true; },
            .ctrl_u => { ed.killToStart(); content_changed = true; },
            .ctrl_w, .alt_backspace => { ed.killWordBackward(); content_changed = true; },
            .alt_d => { ed.killWordForward(); content_changed = true; },
            .ctrl_y => {
                if (complete_mod.inline_state.active) {
                    if (complete_mod.acceptInline(ed, stdout)) {
                        content_changed = true;
                    }
                } else {
                    ed.yank();
                }
            },
            .ctrl_t => ed.transpose(),
            .char => |ch| {
                if (ch >= 32) { ed.insert(ch); content_changed = true; }
            },
            .utf8 => |u| {
                ed.insertUtf8(u.bytes[0..u.len]);
                content_changed = true;
            },
            else => {},
        }
        // Update inline overlay on content changes.
        // As-you-type: only when enabled, not on_demand, and Attyx is connected.
        // On-demand mode: only updates existing overlay (already open via Tab/Ctrl+Space).
        const ipc_mod = @import("ipc.zig");
        const as_you_type = overlay.enabled and !overlay.on_demand and ipc_mod.attyx_connected;
        const update_existing = overlay.enabled and complete_mod.inline_state.active and ipc_mod.attyx_connected;
        if (content_changed and (as_you_type or update_existing) and hl != null) {
            if (hl) |ctx| {
                complete_mod.updateInline(ed, stdout, prompt_str, ctx.env, ctx.cache, ctx.help_cache, prompt_lua, ctx);
            }
            // If overlay dismissed itself (no candidates), we still need a refresh
            if (!complete_mod.inline_state.active) {
                refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
            }
        } else {
            refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
        }
    }
}

// ---------------------------------------------------------------------------
// Vim normal mode handler
// ---------------------------------------------------------------------------

const editor_types = @import("editor.zig");

/// Pending state for vim operator-pending mode.
/// Tracks: operator ('d', 'c', 'y'), then waits for motion/text-object.
/// Text objects use two chars: modifier ('i'/'a') + object ('w', '"', etc.)
var vim_pending_modifier: u8 = 0; // 'i' or 'a' for text objects

fn handleNormalMode(ed: *editor_types.Editor, key: keys.Key, pending_op: *u8) void {
    switch (key) {
        .char => |ch| {
            // --- Pending operator + text-object modifier (e.g. 'di' waiting for 'w') ---
            if (pending_op.* != 0 and vim_pending_modifier != 0) {
                const range = resolveTextObject(ed, vim_pending_modifier, ch);
                const op = pending_op.*;
                pending_op.* = 0;
                vim_pending_modifier = 0;
                if (range) |r| ed.applyOperator(op, r);
                return;
            }

            // --- Pending operator waiting for motion or text-object start ---
            if (pending_op.* != 0) {
                const op = pending_op.*;
                switch (ch) {
                    // Motions
                    'w' => {
                        if (ed.motionEnd('w')) |end| {
                            pending_op.* = 0;
                            ed.applyOperator(op, .{ .start = ed.cursor, .end = end });
                        }
                    },
                    'e' => {
                        if (ed.motionEnd('e')) |end| {
                            pending_op.* = 0;
                            ed.applyOperator(op, .{ .start = ed.cursor, .end = end });
                        }
                    },
                    'b' => {
                        if (ed.motionStart('b')) |start| {
                            pending_op.* = 0;
                            ed.applyOperator(op, .{ .start = start, .end = ed.cursor });
                        }
                    },
                    '$' => {
                        pending_op.* = 0;
                        ed.applyOperator(op, .{ .start = ed.cursor, .end = ed.len });
                    },
                    '0' => {
                        pending_op.* = 0;
                        ed.applyOperator(op, .{ .start = 0, .end = ed.cursor });
                    },
                    // Text object modifiers
                    'i', 'a' => { vim_pending_modifier = ch; },
                    // Same key = line operation (dd, cc, yy)
                    'd', 'c', 'y' => {
                        if (ch == op) {
                            pending_op.* = 0;
                            if (op == 'y') {
                                // yy = yank whole line
                                @memcpy(ed.kill_buf[0..ed.len], ed.buf[0..ed.len]);
                                ed.kill_len = ed.len;
                            } else {
                                ed.applyOperator(op, .{ .start = 0, .end = ed.len });
                            }
                        }
                    },
                    else => { pending_op.* = 0; vim_pending_modifier = 0; },
                }
                return;
            }

            // --- Normal mode base keys ---
            switch (ch) {
                // Movement
                'h' => ed.moveLeft(),
                'l' => {
                    if (ed.cursor + 1 < ed.len) ed.cursor += 1;
                },
                '0' => ed.moveHome(),
                '$' => {
                    ed.moveEnd();
                    ed.clampNormal();
                },
                'w' => ed.moveWordForward(),
                'b' => ed.moveWordBackward(),
                'e' => {
                    // Move to end of current/next word
                    var i = ed.cursor;
                    if (i < ed.len) i += 1;
                    while (i < ed.len and (ed.buf[i] == ' ' or ed.buf[i] == '\t')) : (i += 1) {}
                    while (i < ed.len and ed.buf[i] != ' ' and ed.buf[i] != '\t') : (i += 1) {}
                    if (i > 0) i -= 1;
                    ed.cursor = i;
                },

                // Operators
                'd' => { pending_op.* = 'd'; vim_pending_modifier = 0; },
                'c' => { pending_op.* = 'c'; vim_pending_modifier = 0; },
                'y' => { pending_op.* = 'y'; vim_pending_modifier = 0; },

                // Single-key editing
                'x' => ed.deleteAtCursor(),
                'X' => { if (ed.cursor > 0) { ed.moveLeft(); ed.deleteAtCursor(); } },
                'D' => ed.deleteToEnd(),
                'C' => {
                    ed.deleteToEnd();
                    ed.mode = .insert;
                },
                'S' => {
                    // Clear line and enter insert
                    ed.applyOperator('c', .{ .start = 0, .end = ed.len });
                },
                's' => {
                    // Delete char and enter insert
                    ed.deleteAtCursor();
                    ed.mode = .insert;
                },
                'r' => { pending_op.* = 'r'; }, // replace single char
                'p' => {
                    // Paste after cursor
                    if (ed.kill_len > 0) {
                        if (ed.cursor < ed.len) ed.cursor += 1;
                        ed.mode = .insert;
                        ed.yank();
                        ed.mode = .normal;
                        ed.clampNormal();
                    }
                },
                'P' => {
                    // Paste before cursor
                    if (ed.kill_len > 0) {
                        ed.mode = .insert;
                        ed.yank();
                        ed.mode = .normal;
                        ed.clampNormal();
                    }
                },

                // Visual mode
                'v' => { ed.enterVisual(); },

                // Mode transitions
                'i' => { ed.mode = .insert; },
                'a' => {
                    if (ed.cursor < ed.len) ed.cursor += 1;
                    ed.mode = .insert;
                },
                'A' => {
                    ed.moveEnd();
                    ed.mode = .insert;
                },
                'I' => {
                    ed.moveHome();
                    ed.mode = .insert;
                },

                else => { pending_op.* = 0; vim_pending_modifier = 0; },
            }
        },
        .left => ed.moveLeft(),
        .right => {
            if (ed.cursor + 1 < ed.len) ed.cursor += 1;
        },
        .home => ed.moveHome(),
        .end_key => {
            ed.moveEnd();
            ed.clampNormal();
        },
        .backspace => ed.moveLeft(),
        else => { pending_op.* = 0; vim_pending_modifier = 0; },
    }

    // Handle 'r' (replace) pending — next char replaces current
    if (pending_op.* == 'r') {
        switch (key) {
            .char => |ch| {
                if (ch != 'r') { // not the 'r' itself
                    if (ed.cursor < ed.len) {
                        ed.buf[ed.cursor] = ch;
                    }
                    pending_op.* = 0;
                }
            },
            else => { pending_op.* = 0; },
        }
    }

    // Keep cursor in bounds for normal mode
    if (ed.mode == .normal) ed.clampNormal();
}

/// Resolve a text object from modifier ('i'/'a') + object key.
fn resolveTextObject(ed: *const editor_types.Editor, modifier: u8, object: u8) ?editor_types.Editor.TextRange {
    const inner = modifier == 'i';
    return switch (object) {
        'w' => if (inner) ed.innerWord() else ed.aWord(),
        '"' => if (inner) ed.innerQuoted('"') else ed.aQuoted('"'),
        '\'' => if (inner) ed.innerQuoted('\'') else ed.aQuoted('\''),
        '`' => if (inner) ed.innerQuoted('`') else ed.aQuoted('`'),
        '(', ')' => if (inner) ed.innerPair('(', ')') else ed.aPair('(', ')'),
        '[', ']' => if (inner) ed.innerPair('[', ']') else ed.aPair('[', ']'),
        '{', '}' => if (inner) ed.innerPair('{', '}') else ed.aPair('{', '}'),
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Visual mode handler
// ---------------------------------------------------------------------------

/// Pending text-object modifier in visual mode ('i'/'a').
var visual_pending_modifier: u8 = 0;

fn handleVisualMode(ed: *editor_types.Editor, key: keys.Key) void {
    switch (key) {
        .char => |ch| {
            // Text object modifier pending (e.g. 'a' waiting for 'w')
            if (visual_pending_modifier != 0) {
                const range = resolveTextObject(ed, visual_pending_modifier, ch);
                visual_pending_modifier = 0;
                if (range) |r| ed.visualExpandTo(r);
                return;
            }

            switch (ch) {
                // Movement — extends selection
                'h' => ed.moveLeft(),
                'l' => {
                    if (ed.cursor + 1 < ed.len) ed.cursor += 1;
                },
                'w' => ed.moveWordForward(),
                'b' => ed.moveWordBackward(),
                'e' => {
                    var i = ed.cursor;
                    if (i < ed.len) i += 1;
                    while (i < ed.len and (ed.buf[i] == ' ' or ed.buf[i] == '\t')) : (i += 1) {}
                    while (i < ed.len and ed.buf[i] != ' ' and ed.buf[i] != '\t') : (i += 1) {}
                    if (i > 0) i -= 1;
                    ed.cursor = i;
                },
                '0' => ed.moveHome(),
                '$' => {
                    ed.moveEnd();
                    if (ed.len > 0) ed.cursor = ed.len - 1;
                },

                // Text object modifiers
                'i', 'a' => { visual_pending_modifier = ch; },

                // Operators — act on visual selection
                'd' => {
                    const range = ed.visualRange();
                    ed.applyOperator('d', range);
                    // applyOperator sets mode via 'd' which stays normal
                    ed.mode = .normal;
                },
                'c' => {
                    const range = ed.visualRange();
                    ed.applyOperator('c', range);
                    // applyOperator('c') already sets insert mode
                },
                'y' => {
                    const range = ed.visualRange();
                    ed.applyOperator('y', range);
                    ed.mode = .normal;
                },
                'x' => {
                    const range = ed.visualRange();
                    ed.applyOperator('d', range);
                    ed.mode = .normal;
                },

                // Cancel
                'v' => { ed.mode = .normal; visual_pending_modifier = 0; },

                else => {},
            }
        },
        .escape => {
            ed.mode = .normal;
            visual_pending_modifier = 0;
        },
        .left => ed.moveLeft(),
        .right => {
            if (ed.cursor + 1 < ed.len) ed.cursor += 1;
        },
        .home => ed.moveHome(),
        .end_key => {
            ed.moveEnd();
            if (ed.len > 0) ed.cursor = ed.len - 1;
        },
        else => {},
    }

    if (ed.mode == .visual and ed.len > 0 and ed.cursor >= ed.len) {
        ed.cursor = ed.len - 1;
    }
}

/// Redraw the current line with optional syntax highlighting and ghost text.
pub fn refreshLine(
    stdout: std.fs.File,
    prompt_str: []const u8,
    ed: *const editor_mod.Editor,
    hl: ?*const HighlightCtx,
) void {
    refreshLineWithHistory(stdout, prompt_str, ed, hl, null);
}

/// Stored prompt builder state for live re-rendering on mode changes.
pub var prompt_last_exit: u8 = 0;
pub var prompt_last_duration: i64 = 0;
pub var prompt_job_count: usize = 0;
pub var prompt_lua: lua_api.LuaState = null;
pub var history_db_ref: ?*history_db_mod.HistoryDb = null;

/// Full redraw with ghost text from history fuzzy match.
pub fn refreshLineWithHistory(
    stdout: std.fs.File,
    prompt_str_default: []const u8,
    ed: *const editor_mod.Editor,
    hl: ?*const HighlightCtx,
    _: ?*const history_mod.History,
) void {
    var buf: [16384]u8 = undefined;
    var pos: usize = 0;

    // For multiline prompts: move up to redraw — but NOT on fresh prompt
    // (fresh = first render after command output, don't eat the output)
    if (prompt_fresh) {
        prompt_fresh = false;
    } else if (prompt_extra_lines > 0) {
        const n = std.fmt.bufPrint(buf[pos..], "\x1b[{d}A", .{prompt_extra_lines}) catch "";
        pos += n.len;
    }
    pos += cp(buf[pos..], "\r\x1b[J");

    // Re-render prompt if vim mode (symbol changes with mode)
    const prompt_mod = @import("prompt.zig");
    if (ed.vim_enabled) {
        var pctx = prompt_mod.buildContext(prompt_last_exit, prompt_last_duration, prompt_job_count);
        pctx.vim_normal = (ed.mode == .normal or ed.mode == .visual);
        var pbuf_local: [prompt_mod.MAX_PROMPT]u8 = undefined;
        const pr = prompt_mod.render(&pbuf_local, &pctx, prompt_lua);
        pos += cp(buf[pos..], pr.text);
        prompt_extra_lines = if (pr.line_count > 1) pr.line_count - 1 else 0;
    } else {
        pos += cp(buf[pos..], prompt_str_default);
    }

    // Cursor: hidden in visual mode, block in normal, beam in insert
    if (ed.vim_enabled and ed.mode == .visual) {
        pos += cp(buf[pos..], "\x1b[?25l"); // hide cursor
    } else if (ed.vim_enabled and ed.mode == .normal) {
        pos += cp(buf[pos..], "\x1b[?25h\x1b[2 q"); // show + block
    } else {
        pos += cp(buf[pos..], "\x1b[?25h\x1b[6 q"); // show + beam
    }

    const content = ed.content();
    if (ed.vim_enabled and ed.mode == .visual and content.len > 0) {
        // Render with visual selection highlight (inverse video)
        const vr = ed.visualRange();
        // Before selection
        if (vr.start > 0) {
            if (hl) |ctx| {
                pos += highlight.renderHighlighted(buf[pos..], content[0..vr.start], ctx.cache, ctx.env, ctx.lua);
            } else {
                pos += cp(buf[pos..], content[0..vr.start]);
            }
        }
        // Selected region — reset first, then reverse video (matches cursor color)
        pos += cp(buf[pos..], "\x1b[0;7m");
        pos += cp(buf[pos..], content[vr.start..vr.end]);
        pos += cp(buf[pos..], "\x1b[0m");
        // After selection
        if (vr.end < content.len) {
            pos += cp(buf[pos..], content[vr.end..]);
        }
    } else if (hl) |ctx| {
        pos += highlight.renderHighlighted(buf[pos..], content, ctx.cache, ctx.env, ctx.lua);
    } else {
        pos += cp(buf[pos..], content);
    }

    // At this point cursor is at prompt_len + content visible length
    // Ghost text + cursor positioning — count visible chars, not bytes
    var move_back: usize = ed.visibleLen() - ed.visibleCursorPos();

    if (ed.cursor == ed.len and ed.len > 0) {
        if (findGhostFromDb(content)) |match| {
            const ghost = match[content.len..];
            pos += cp(buf[pos..], "\x1b[38;5;246m");
            pos += cp(buf[pos..], ghost);
            pos += cp(buf[pos..], "\x1b[0m");
            move_back = utf8VisibleLen(ghost);
        }
    }

    if (move_back > 0) {
        const n = std.fmt.bufPrint(buf[pos..], "\x1b[{d}D", .{move_back}) catch "";
        pos += n.len;
    }

    stdout.writeAll(buf[0..pos]) catch {};
}

/// Get the current ghost text suggestion (for Right arrow acceptance).
pub fn getGhostSuggestion(ed: *const editor_mod.Editor) ?[]const u8 {
    if (ed.cursor != ed.len or ed.len == 0) return null;
    return findGhostFromDb(ed.content());
}

/// Ghost text buffer — persists across calls so the returned slice stays valid.
var ghost_buf: [4096]u8 = undefined;

fn findGhostFromDb(prefix: []const u8) ?[]const u8 {
    const db = history_db_ref orelse return null;
    return db.findGhost(prefix, &ghost_buf);
}

/// Render prompt + editor content into an external buffer (no stdout write).
/// Used by the completion overlay to batch prompt + candidates in one flush.
/// Returns number of bytes written.
pub fn renderPromptIntoBuf(
    out: []u8,
    prompt_str_default: []const u8,
    ed: *const editor_mod.Editor,
    hl: ?*const HighlightCtx,
) usize {
    var pos: usize = 0;

    // Multiline: move up to redraw
    if (prompt_fresh) {
        prompt_fresh = false;
    } else if (prompt_extra_lines > 0) {
        const n = std.fmt.bufPrint(out[pos..], "\x1b[{d}A", .{prompt_extra_lines}) catch "";
        pos += n.len;
    }
    pos += cp(out[pos..], "\r\x1b[J");

    // Prompt
    const prompt_mod = @import("prompt.zig");
    if (ed.vim_enabled) {
        var pctx = prompt_mod.buildContext(prompt_last_exit, prompt_last_duration, prompt_job_count);
        pctx.vim_normal = (ed.mode == .normal or ed.mode == .visual);
        var pbuf: [prompt_mod.MAX_PROMPT]u8 = undefined;
        const pr = prompt_mod.render(&pbuf, &pctx, prompt_lua);
        pos += cp(out[pos..], pr.text);
    } else {
        pos += cp(out[pos..], prompt_str_default);
    }

    // Cursor shape
    if (ed.vim_enabled and ed.mode == .normal) {
        pos += cp(out[pos..], "\x1b[2 q");
    } else {
        pos += cp(out[pos..], "\x1b[6 q");
    }

    // Editor content with highlighting
    const content = ed.content();
    if (hl) |ctx| {
        pos += highlight.renderHighlighted(out[pos..], content, ctx.cache, ctx.env, ctx.lua);
    } else {
        pos += cp(out[pos..], content);
    }

    // Cursor positioning (no ghost text — overlay replaces it)
    const move_back: usize = ed.visibleLen() - ed.visibleCursorPos();
    if (move_back > 0) {
        const n = std.fmt.bufPrint(out[pos..], "\x1b[{d}D", .{move_back}) catch "";
        pos += n.len;
    }

    return pos;
}

pub fn showPrompt(stdout: std.fs.File, prompt_str: []const u8) void {
    stdout.writeAll("\r") catch {};
    stdout.writeAll(prompt_str) catch {};
}

/// Count visible characters (codepoints) in a UTF-8 string.
fn utf8VisibleLen(s: []const u8) usize {
    var vis: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] & 0x80 == 0) { i += 1; }
        else if (s[i] & 0xE0 == 0xC0) { i += 2; }
        else if (s[i] & 0xF0 == 0xE0) { i += 3; }
        else if (s[i] & 0xF8 == 0xF0) { i += 4; }
        else { i += 1; }
        vis += 1;
    }
    return vis;
}

fn cp(dest: []u8, src: []const u8) usize {
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}
