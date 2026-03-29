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
const lua_api = @import("lua_api.zig");
const history_search = @import("history_search.zig");
const history_db_mod = @import("history_db.zig");

/// Highlight context passed through from the shell.
pub const HighlightCtx = struct {
    cache: *highlight.CommandCache,
    env: *const environ_mod.Environ,
    help_cache: ?*complete_help.HelpCache = null,
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

/// Read a line with history navigation and syntax highlighting.
pub fn readLine(
    ed: *editor_mod.Editor,
    prompt_str: []const u8,
    hist: ?*history_mod.History,
    hl: ?*const HighlightCtx,
) !ReadResult {
    const stdout = std.fs.File.stdout();

    if (hist) |h| h.beginNavigation(ed.content());

    // Pending operator for vim (e.g., 'd' waiting for motion)
    var pending_op: u8 = 0;

    while (true) {
        const key = try keys.readKey();

        // Keys that work in both modes
        switch (key) {
            .enter => {
                ed.mode = .insert;
                // Clear ghost text and current line, then newline
                stdout.writeAll("\r\x1b[K") catch {};
                // Re-render prompt + content cleanly (no ghost)
                var clr_buf: [8192]u8 = undefined;
                var clr_pos: usize = 0;
                clr_pos += cp(clr_buf[clr_pos..], prompt_str);
                const hl_mod = @import("highlight.zig");
                if (hl) |ctx| {
                    clr_pos += hl_mod.renderHighlighted(clr_buf[clr_pos..], ed.content(), ctx.cache, ctx.env);
                } else {
                    clr_pos += cp(clr_buf[clr_pos..], ed.content());
                }
                clr_pos += cp(clr_buf[clr_pos..], "\r\n");
                stdout.writeAll(clr_buf[0..clr_pos]) catch {};
                if (hist) |h| h.resetNavigation();
                return .{ .line = ed.content() };
            },
            .ctrl_c => {
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
                refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                continue;
            },
            .ctrl_r => {
                // Launch history search
                const result = history_search.run(history_db_ref, stdout);
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
                if (hist) |h| {
                    if (h.navigateUp()) |entry| {
                        ed.setContent(entry);
                        refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                    }
                }
                continue;
            },
            .down, .ctrl_n => {
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
        if (ed.vim_enabled and ed.mode == .normal) {
            handleNormalMode(ed, key, &pending_op);
            refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
            continue;
        }

        // Insert mode (or vim disabled)
        switch (key) {
            .tab => {
                if (hl) |ctx| {
                    _ = complete_mod.runPicker(
                        ed, stdout, prompt_str, ctx.env, ctx.cache,
                        ctx.help_cache, ctx,
                    );
                }
            },
            .escape => {
                if (ed.vim_enabled) {
                    ed.mode = .normal;
                    ed.clampNormal();
                }
            },
            // Movement
            .left, .ctrl_b => ed.moveLeft(),
            .right, .ctrl_f => {
                if (ed.cursor == ed.len) {
                    if (getGhostSuggestion(ed, hist)) |ghost| {
                        ed.setContent(ghost);
                        refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
                        continue;
                    }
                }
                ed.moveRight();
            },
            .home, .ctrl_a => ed.moveHome(),
            .end_key, .ctrl_e => ed.moveEnd(),
            .alt_b => ed.moveWordBackward(),
            .alt_f => ed.moveWordForward(),
            // Deletion
            .backspace => ed.backspace(),
            .delete => ed.delete(),
            .ctrl_k => ed.killToEnd(),
            .ctrl_u => ed.killToStart(),
            .ctrl_w, .alt_backspace => ed.killWordBackward(),
            .alt_d => ed.killWordForward(),
            .ctrl_y => ed.yank(),
            .ctrl_t => ed.transpose(),
            .char => |ch| {
                if (ch >= 32) ed.insert(ch);
            },
            else => {},
        }
        refreshLineWithHistory(stdout, prompt_str, ed, hl, hist);
    }
}

// ---------------------------------------------------------------------------
// Vim normal mode handler
// ---------------------------------------------------------------------------

const editor_types = @import("editor.zig");

fn handleNormalMode(ed: *editor_types.Editor, key: keys.Key, pending_op: *u8) void {
    switch (key) {
        .char => |ch| {
            // Check for pending operator (d + motion)
            if (pending_op.* == 'd') {
                pending_op.* = 0;
                switch (ch) {
                    'w' => ed.deleteWord(),
                    'b' => ed.deleteWordBackward(),
                    'd' => ed.clear(), // dd = clear line
                    else => {},
                }
                return;
            }

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

                // Editing
                'x' => ed.deleteAtCursor(),
                'D' => ed.deleteToEnd(),
                'd' => { pending_op.* = 'd'; },

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

                else => { pending_op.* = 0; },
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
        else => { pending_op.* = 0; },
    }

    // Keep cursor in bounds for normal mode
    if (ed.mode == .normal) ed.clampNormal();
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
    hist: ?*const history_mod.History,
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
        pctx.vim_normal = (ed.mode == .normal);
        var pbuf: [prompt_mod.MAX_PROMPT]u8 = undefined;
        const pr = prompt_mod.render(&pbuf, &pctx, prompt_lua);
        pos += cp(buf[pos..], pr.text);
        prompt_extra_lines = if (pr.line_count > 1) pr.line_count - 1 else 0;
    } else {
        pos += cp(buf[pos..], prompt_str_default);
    }

    // Vim cursor shape: beam for insert, block for normal
    if (ed.vim_enabled) {
        if (ed.mode == .normal) {
            pos += cp(buf[pos..], "\x1b[2 q");
        } else {
            pos += cp(buf[pos..], "\x1b[6 q");
        }
    }

    const content = ed.content();
    if (hl) |ctx| {
        pos += highlight.renderHighlighted(buf[pos..], content, ctx.cache, ctx.env);
    } else {
        pos += cp(buf[pos..], content);
    }

    // At this point cursor is at prompt_len + content.len
    // Ghost text + cursor positioning
    var move_back: usize = ed.len - ed.cursor; // chars after cursor in content

    if (ed.cursor == ed.len and ed.len > 0) {
        if (hist) |h| {
            if (h.findGhost(content)) |match| {
                const ghost = match[content.len..];
                // Write a space to separate cursor from ghost, then ghost text
                pos += cp(buf[pos..], "\x1b[38;5;246m");
                pos += cp(buf[pos..], ghost);
                pos += cp(buf[pos..], "\x1b[0m");
                move_back = ghost.len;
            }
        }
    }

    if (move_back > 0) {
        const n = std.fmt.bufPrint(buf[pos..], "\x1b[{d}D", .{move_back}) catch "";
        pos += n.len;
    }

    stdout.writeAll(buf[0..pos]) catch {};
}

/// Get the current ghost text suggestion (for Right arrow acceptance).
pub fn getGhostSuggestion(ed: *const editor_mod.Editor, hist: ?*const history_mod.History) ?[]const u8 {
    if (ed.cursor != ed.len or ed.len == 0) return null;
    const h = hist orelse return null;
    return h.findGhost(ed.content());
}

pub fn showPrompt(stdout: std.fs.File, prompt_str: []const u8) void {
    stdout.writeAll("\r") catch {};
    stdout.writeAll(prompt_str) catch {};
}

fn cp(dest: []u8, src: []const u8) usize {
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}
