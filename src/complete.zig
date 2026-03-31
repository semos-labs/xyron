// complete.zig — Interactive completion picker with fuzzy filtering.
//
// Tab triggers the picker below the prompt. User can type to fuzzy
// filter, navigate with up/down, accept with Enter/Right, cancel
// with Escape/Ctrl+C.

const std = @import("std");
const posix = std.posix;
const editor_mod = @import("editor.zig");
const environ_mod = @import("environ.zig");
const highlight = @import("highlight.zig");
const providers = @import("complete_providers.zig");
const help_mod = @import("complete_help.zig");
const keys = @import("keys.zig");
const fuzzy = @import("fuzzy.zig");
const overlay = @import("overlay.zig");

// ---------------------------------------------------------------------------
// Completion context
// ---------------------------------------------------------------------------

pub const ContextKind = enum { command, argument, flag, env_var, redirect_target, none };

pub const CompletionContext = struct {
    kind: ContextKind,
    prefix: []const u8,
    word_start: usize,
    word_end: usize,
    cmd_name: []const u8,
};

// ---------------------------------------------------------------------------
// Candidate model
// ---------------------------------------------------------------------------

pub const MAX_CANDIDATES: usize = 256;
pub const MAX_TEXT: usize = 256;
pub const MAX_DESC: usize = 80;

pub const CandidateKind = enum { builtin, lua_cmd, alias, external_cmd, file, directory, env_var, flag };

pub const Candidate = struct {
    text: [MAX_TEXT]u8,
    text_len: usize,
    desc: [MAX_DESC]u8 = undefined,
    desc_len: usize = 0,
    kind: CandidateKind,

    pub fn textSlice(self: *const Candidate) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn descSlice(self: *const Candidate) []const u8 {
        return self.desc[0..self.desc_len];
    }
};

pub const CandidateBuffer = struct {
    items: [MAX_CANDIDATES]Candidate = undefined,
    count: usize = 0,

    pub fn add(self: *CandidateBuffer, text: []const u8, kind: CandidateKind) void {
        self.addWithDesc(text, "", kind);
    }

    pub fn addWithDesc(self: *CandidateBuffer, text: []const u8, desc: []const u8, kind: CandidateKind) void {
        if (self.count >= MAX_CANDIDATES or text.len > MAX_TEXT) return;
        for (self.items[0..self.count]) |*existing| {
            if (std.mem.eql(u8, existing.textSlice(), text)) return;
        }
        var c = &self.items[self.count];
        @memcpy(c.text[0..text.len], text);
        c.text_len = text.len;
        const dl = @min(desc.len, MAX_DESC);
        if (dl > 0) @memcpy(c.desc[0..dl], desc[0..dl]);
        c.desc_len = dl;
        c.kind = kind;
        self.count += 1;
    }
};

// ---------------------------------------------------------------------------
// Picker state
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Public API for headless/protocol use (no terminal IO)
// ---------------------------------------------------------------------------

/// Completion result for protocol consumers.
pub const CompletionResult = struct {
    candidates: *const CandidateBuffer,
    context: CompletionContext,
    /// Indices sorted by score (fuzzy + kind priority).
    sorted_indices: [MAX_CANDIDATES]usize = undefined,
    sorted_scores: [MAX_CANDIDATES]i32 = undefined,
    sorted_count: usize = 0,
};

/// Gather completions for a given buffer and cursor position.
/// No terminal IO — pure data. Safe to call from headless mode.
pub fn getCompletions(
    buffer: []const u8,
    cursor: usize,
    env: *const environ_mod.Environ,
    cmd_cache: *highlight.CommandCache,
    help_cache: ?*help_mod.HelpCache,
) CompletionResult {
    const ctx = analyzeContext(buffer, cursor);
    var result = CompletionResult{
        .candidates = undefined,
        .context = ctx,
    };

    // Use a static buffer to avoid allocation
    const S = struct {
        var buf: CandidateBuffer = .{};
    };
    S.buf.count = 0;
    providers.gather(&S.buf, &ctx, env, cmd_cache, help_cache);
    result.candidates = &S.buf;

    // Score and sort
    scoreAndFilter(&S.buf, ctx.prefix, &result.sorted_indices, &result.sorted_scores, &result.sorted_count);

    return result;
}

const MAX_FILTER: usize = 128;
const MAX_VISIBLE: usize = 12;

pub const PickerResult = enum { accepted, cancelled };

/// Run the interactive completion picker. Blocks until user accepts or cancels.
pub fn runPicker(
    ed: *editor_mod.Editor,
    stdout: std.fs.File,
    prompt_str: []const u8,
    env: *const environ_mod.Environ,
    cmd_cache: *highlight.CommandCache,
    help_cache: ?*help_mod.HelpCache,
    hl_ctx: anytype,
) PickerResult {
    // Analyze context and gather candidates
    const ctx = analyzeContext(ed.content(), ed.cursor);
    var all = CandidateBuffer{};
    providers.gather(&all, &ctx, env, cmd_cache, help_cache);
    if (all.count == 0) return .cancelled;

    // If single candidate, insert immediately
    if (all.count == 1) {
        insertCandidate(ed, ctx.word_start, ctx.word_end, &all.items[0]);
        return .accepted;
    }

    // Picker state
    var filter: [MAX_FILTER]u8 = undefined;
    @memcpy(filter[0..ctx.prefix.len], ctx.prefix);
    var filter_len = ctx.prefix.len;
    var selected: usize = 0;
    var scroll: usize = 0;

    // Score and sort
    var scored_indices: [MAX_CANDIDATES]usize = undefined;
    var scored_values: [MAX_CANDIDATES]i32 = undefined;
    var scored_count: usize = 0;

    scoreAndFilter(&all, filter[0..filter_len], &scored_indices, &scored_values, &scored_count);

    if (scored_count == 0) return .cancelled;

    // Overlay setup: detect actual screen position via DSR
    const layout = computeOverlayLayout();
    const max_visible = layout.max_visible;
    // Store direction + word_start for renderPicker to use
    inline_state.direction = layout.direction;
    inline_state.word_start = ctx.word_start;

    // Render initial picker
    renderPicker(stdout, prompt_str, ed, &all, &scored_indices, scored_count, selected, scroll, max_visible, filter[0..filter_len], hl_ctx);

    // Picker key loop
    while (true) {
        const key = keys.readKey() catch break;

        switch (key) {
            .enter, .right => {
                if (scored_count > 0) {
                    const idx = scored_indices[selected];
                    insertCandidate(ed, ctx.word_start, ed.cursor, &all.items[idx]);
                }
                clearPickerLines(stdout, max_visible, inline_state.direction);
                return .accepted;
            },
            .tab => {
                // Cycle forward (same as down)
                if (scored_count > 0) {
                    selected = if (selected + 1 >= scored_count) 0 else selected + 1;
                    if (selected >= scroll + max_visible) scroll = selected - max_visible + 1;
                    if (selected < scroll) scroll = selected;
                }
            },
            .shift_tab => {
                // Cycle backward (same as up, wrapping)
                if (scored_count > 0) {
                    selected = if (selected == 0) scored_count - 1 else selected - 1;
                    if (selected < scroll) scroll = selected;
                    if (selected >= scroll + max_visible) scroll = selected - max_visible + 1;
                }
            },
            .escape, .ctrl_c => {
                clearPickerLines(stdout, max_visible, inline_state.direction);
                return .cancelled;
            },
            .up => {
                if (selected > 0) selected -= 1;
                if (selected < scroll) scroll = selected;
            },
            .down => {
                if (scored_count > 0 and selected + 1 < scored_count) selected += 1;
                if (selected >= scroll + max_visible) scroll = selected - max_visible + 1;
            },
            .backspace => {
                if (filter_len > 0) {
                    filter_len -= 1;
                    ed.backspace();
                    rescore(&all, filter[0..filter_len], &scored_indices, &scored_values, &scored_count, &selected, &scroll);
                }
            },
            .char => |ch| {
                if (ch >= 32 and filter_len < MAX_FILTER) {
                    filter[filter_len] = ch;
                    filter_len += 1;
                    ed.insert(ch);
                    rescore(&all, filter[0..filter_len], &scored_indices, &scored_values, &scored_count, &selected, &scroll);
                }
            },
            else => {},
        }

        renderPicker(stdout, prompt_str, ed, &all, &scored_indices, scored_count, selected, scroll, max_visible, filter[0..filter_len], hl_ctx);
    }

    clearPickerLines(stdout, max_visible, inline_state.direction);
    return .cancelled;
}

fn rescore(
    all: *const CandidateBuffer,
    filter: []const u8,
    indices: *[MAX_CANDIDATES]usize,
    values: *[MAX_CANDIDATES]i32,
    count: *usize,
    selected: *usize,
    scroll: *usize,
) void {
    scoreAndFilter(all, filter, indices, values, count);
    if (selected.* >= count.*) selected.* = if (count.* > 0) count.* - 1 else 0;
    if (scroll.* > selected.*) scroll.* = selected.*;
}

// ---------------------------------------------------------------------------
// Context analysis
// ---------------------------------------------------------------------------

pub fn analyzeContext(content: []const u8, cursor: usize) CompletionContext {
    const text = content[0..@min(cursor, content.len)];
    if (text.len == 0) return .{ .kind = .command, .prefix = "", .word_start = 0, .word_end = 0, .cmd_name = "" };

    var word_start = text.len;
    while (word_start > 0 and text[word_start - 1] != ' ' and text[word_start - 1] != '\t') : (word_start -= 1) {}
    const prefix = text[word_start..];

    var cmd_name: []const u8 = "";
    var is_cmd_pos = true;
    var after_redirect = false;
    var i: usize = 0;

    while (i < word_start) {
        while (i < word_start and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
        if (i >= word_start) break;

        if (text[i] == '|') { is_cmd_pos = true; after_redirect = false; cmd_name = ""; i += 1; continue; }
        if (text[i] == '>' or text[i] == '<') { after_redirect = true; i += 1; continue; }
        if (text[i] == '2' and i + 1 < word_start and text[i + 1] == '>') { after_redirect = true; i += 2; continue; }

        const ws = i;
        while (i < word_start and text[i] != ' ' and text[i] != '\t' and text[i] != '|' and text[i] != '>' and text[i] != '<') : (i += 1) {}
        const word = text[ws..i];

        if (after_redirect) { after_redirect = false; continue; }
        if (is_cmd_pos) {
            if (isAssignment(word)) continue;
            cmd_name = word;
            is_cmd_pos = false;
        }
    }

    const kind: ContextKind = if (after_redirect) .redirect_target else if (prefix.len > 0 and prefix[0] == '$') .env_var else if (is_cmd_pos) .command else if (prefix.len > 0 and prefix[0] == '-') .flag else .argument;

    return .{ .kind = kind, .prefix = prefix, .word_start = word_start, .word_end = cursor, .cmd_name = cmd_name };
}

fn isAssignment(word: []const u8) bool {
    const eq = std.mem.indexOf(u8, word, "=") orelse return false;
    return eq > 0;
}

// ---------------------------------------------------------------------------
// Scoring and filtering
// ---------------------------------------------------------------------------

/// Priority bonus by candidate kind — commands rank above flags/files.
fn kindPriority(kind: CandidateKind) i32 {
    return switch (kind) {
        .builtin => 200,
        .lua_cmd => 180,
        .alias => 170,
        .external_cmd => 150,
        .flag => 80,
        .env_var => 40,
        .directory => 20,
        .file => 0,
    };
}

fn scoreAndFilter(
    all: *const CandidateBuffer,
    filter: []const u8,
    indices: *[MAX_CANDIDATES]usize,
    values: *[MAX_CANDIDATES]i32,
    count: *usize,
) void {
    count.* = 0;
    for (0..all.count) |i| {
        const text = all.items[i].textSlice();
        const priority = kindPriority(all.items[i].kind);

        if (filter.len == 0) {
            // No filter — sort by kind priority only
            const total = priority;
            var pos = count.*;
            while (pos > 0 and values[pos - 1] < total) {
                indices[pos] = indices[pos - 1];
                values[pos] = values[pos - 1];
                pos -= 1;
            }
            indices[pos] = i;
            values[pos] = total;
            count.* += 1;
        } else {
            const s = fuzzy.score(text, filter);
            if (s.matched) {
                const total = s.value + priority;
                var pos = count.*;
                while (pos > 0 and values[pos - 1] < total) {
                    indices[pos] = indices[pos - 1];
                    values[pos] = values[pos - 1];
                    pos -= 1;
                }
                indices[pos] = i;
                values[pos] = total;
                count.* += 1;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Layout: detect cursor row and choose direction
// ---------------------------------------------------------------------------

const OverlayLayout = struct {
    direction: overlay.Direction,
    max_visible: usize,
    cursor_row: usize, // actual screen row (1-based), 0 = unknown
    term_rows: usize,
};

/// Cached cursor row, set once at prompt display time (before key loop).
/// Avoids DSR during typing which would block input.
pub var cached_cursor_row: usize = 0;

/// Update cached cursor row from the shell's estimate.
pub fn cachePromptRow() void {
    const input_mod = @import("input.zig");
    cached_cursor_row = input_mod.cursor_row_estimate;
}

/// Compute overlay layout using the cached cursor row.
fn computeOverlayLayout() OverlayLayout {
    const term_size = overlay.getTermSize();
    const input_mod = @import("input.zig");
    const prompt_lines = 1 + input_mod.prompt_extra_lines;
    const row = cached_cursor_row;

    if (row > 0) {
        const space_below = if (term_size.rows > row) term_size.rows - row else 0;
        const space_above = if (row > prompt_lines) row - prompt_lines else 0;
        const direction: overlay.Direction = if (space_below >= @min(MAX_VISIBLE, 3)) .below else .above;
        const avail = if (direction == .below) space_below else space_above;
        return .{
            .direction = direction,
            .max_visible = @min(MAX_VISIBLE, if (avail > 0) avail else 1),
            .cursor_row = row,
            .term_rows = term_size.rows,
        };
    }

    // DSR failed — use the shell's cursor row estimate
    const est = input_mod.cursor_row_estimate;
    if (est > 0) {
        const space_below = if (term_size.rows > est) term_size.rows - est else 0;
        const space_above = if (est > prompt_lines) est - prompt_lines else 0;
        const dir: overlay.Direction = if (space_below >= @min(MAX_VISIBLE, 3)) .below else .above;
        const avail = if (dir == .below) space_below else space_above;
        return .{
            .direction = dir,
            .max_visible = @min(MAX_VISIBLE, if (avail > 0) avail else 1),
            .cursor_row = est,
            .term_rows = term_size.rows,
        };
    }

    // No info at all — default to below
    const space = if (term_size.rows > prompt_lines + 1) term_size.rows - prompt_lines - 1 else 3;
    return .{
        .direction = .below,
        .max_visible = @min(MAX_VISIBLE, space),
        .cursor_row = 0,
        .term_rows = term_size.rows,
    };
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn renderPicker(
    stdout: std.fs.File,
    prompt_str: []const u8,
    ed: *const editor_mod.Editor,
    all: *const CandidateBuffer,
    indices: *const [MAX_CANDIDATES]usize,
    count: usize,
    selected: usize,
    scroll: usize,
    max_visible: usize,
    filter: []const u8,
    hl_ctx: anytype,
) void {
    _ = filter;
    var buf: [16384]u8 = undefined;
    var pos: usize = 0;

    const visible_end = @min(scroll + max_visible, count);
    const direction = inline_state.direction;
    const input_mod = @import("input.zig");

    const rendered_lines = visible_end - scroll;
    const prev = inline_state.prev_rendered;

    // For "below": pre-scroll based on actual candidate count
    if (direction == .below) {
        const scroll_n = @max(rendered_lines, prev);
        for (0..scroll_n) |_| pos += cp(buf[pos..], "\n");
        const seq = std.fmt.bufPrint(buf[pos..], "\x1b[{d}A", .{scroll_n}) catch "";
        pos += seq.len;
    }

    // Render prompt + editor content
    pos += input_mod.renderPromptIntoBuf(buf[pos..], prompt_str, ed, hl_ctx);

    // Save cursor position (after pre-scroll, so restore is correct)
    pos += cp(buf[pos..], "\x1b[s");

    // Compute column widths
    var max_text_w: usize = 0;
    var max_row_w: usize = 0;
    for (scroll..visible_end) |i| {
        const idx = indices[i];
        const cand = &all.items[idx];
        max_text_w = @max(max_text_w, cand.text_len);
        var row_w = cand.text_len + 2 + cand.desc_len;
        if (cand.desc_len == 0) row_w = cand.text_len;
        max_row_w = @max(max_row_w, row_w);
    }
    const col_w = max_text_w + 2;
    const MIN_WIDTH: usize = 30;
    const row_width = @max(max_row_w + 2, MIN_WIDTH);

    // Horizontal offset
    const prompt_col = promptVisibleWidth(prompt_str);
    const word_start = inline_state.word_start;
    const col_offset = prompt_col + word_start;
    const term_cols = overlay.getTermSize().cols;
    const clamped_col = if (col_offset + row_width > term_cols and term_cols > row_width)
        term_cols - row_width
    else
        col_offset;

    // For "above": if overlay shrank, clear freed lines then restore content
    if (direction == .above and prev > rendered_lines) {
        const freed = prev - rendered_lines;

        // Flush prompt, then clear + restore in separate save/restore pairs
        stdout.writeAll(buf[0..pos]) catch {};
        pos = 0;

        // Phase 1: clear the freed lines
        {
            var cbuf: [256]u8 = undefined;
            var cpos: usize = 0;
            cpos += cp(cbuf[cpos..], "\x1b[s");
            const seq = std.fmt.bufPrint(cbuf[cpos..], "\x1b[{d}A", .{prev}) catch "";
            cpos += seq.len;
            for (0..freed) |i| {
                if (i > 0) cpos += cp(cbuf[cpos..], "\x1b[B");
                cpos += cp(cbuf[cpos..], "\r\x1b[K");
            }
            cpos += cp(cbuf[cpos..], "\x1b[u");
            stdout.writeAll(cbuf[0..cpos]) catch {};
        }

        // Phase 2: restore block content at cleared positions
        {
            const block_ui = @import("block_ui.zig");
            if (block_ui.enabled and block_ui.saved_block_lines > 0) {
                var rbuf: [64]u8 = undefined;
                stdout.writeAll("\x1b[s") catch {};
                const seq = std.fmt.bufPrint(&rbuf, "\x1b[{d}A\r", .{prev}) catch "";
                stdout.writeAll(seq) catch {};
                const start = if (block_ui.saved_block_lines > prev) block_ui.saved_block_lines - prev else 0;
                block_ui.restoreBlockRange(stdout, start, freed);
                stdout.writeAll("\x1b[u") catch {};
            }
        }

        // Re-save cursor for candidate rendering below
        pos += cp(buf[pos..], "\x1b[s");
    }

    // Move to overlay start position — based on actual rendered count
    if (direction == .above) {
        const move_up = rendered_lines;
        const seq = std.fmt.bufPrint(buf[pos..], "\x1b[{d}A", .{move_up}) catch "";
        pos += seq.len;
    }

    const bg_normal = "\x1b[48;5;235m";
    const bg_selected = "\x1b[48;5;238m";

    // Render candidate rows — overwrite screen content in place
    for (scroll..visible_end, 0..) |i, line_i| {
        if (direction == .below) {
            // Below: \r\n moves to next line (pre-scroll ensures room exists)
            pos += cp(buf[pos..], "\r\n");
        } else {
            // Above: render top-to-bottom from moved-up position
            if (line_i > 0) pos += cp(buf[pos..], "\x1b[B");
            pos += cp(buf[pos..], "\r");
        }

        // Move to column, write candidate
        if (clamped_col > 0) {
            const seq = std.fmt.bufPrint(buf[pos..], "\x1b[{d}C", .{clamped_col}) catch "";
            pos += seq.len;
        }

        const idx = indices[i];
        const cand = &all.items[idx];
        const text = cand.textSlice();
        const desc = cand.descSlice();
        const is_sel = (i == selected);
        const row_bg = if (is_sel) bg_selected else bg_normal;

        pos += cp(buf[pos..], row_bg);
        if (pos < buf.len) { buf[pos] = ' '; pos += 1; }

        const style = kindColor(cand.kind, is_sel);
        pos += cp(buf[pos..], style);
        pos += cp(buf[pos..], text);
        pos += cp(buf[pos..], "\x1b[0m");
        pos += cp(buf[pos..], row_bg);

        if (desc.len > 0) {
            const pad = if (col_w > text.len) col_w - text.len else 1;
            for (0..pad) |_| {
                if (pos < buf.len) { buf[pos] = ' '; pos += 1; }
            }
            if (is_sel) pos += cp(buf[pos..], "\x1b[38;5;252m") else pos += cp(buf[pos..], "\x1b[38;5;245m");
            pos += cp(buf[pos..], desc);
            pos += cp(buf[pos..], "\x1b[0m");
            pos += cp(buf[pos..], row_bg);
        }

        const content_w = 1 + text.len + (if (desc.len > 0) col_w - text.len + desc.len else 0);
        if (row_width > content_w) {
            const trail = row_width - content_w;
            for (0..trail) |_| {
                if (pos < buf.len) { buf[pos] = ' '; pos += 1; }
            }
        }

        pos += cp(buf[pos..], "\x1b[0m");
    }

    // For "below": clear leftover lines if list shrank
    if (direction == .below and prev > rendered_lines) {
        const extra = prev - rendered_lines;
        for (0..extra) |_| {
            pos += cp(buf[pos..], "\r\n\x1b[K");
        }
    }
    inline_state.prev_rendered = rendered_lines;

    // Restore cursor to prompt
    pos += cp(buf[pos..], "\x1b[u");

    // Position cursor within the editor line
    const after = ed.len - ed.cursor;
    if (after > 0) {
        const n = std.fmt.bufPrint(buf[pos..], "\x1b[{d}D", .{after}) catch "";
        pos += n.len;
    }

    stdout.writeAll(buf[0..pos]) catch {};
}

/// Dismiss the overlay and restore content underneath.
fn clearPickerLines(stdout: std.fs.File, lines: usize, direction: overlay.Direction) void {
    if (lines == 0) return;

    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    pos += cp(buf[pos..], "\x1b[s");

    if (direction == .above) {
        // Move up to overlay start
        const seq = std.fmt.bufPrint(buf[pos..], "\x1b[{d}A", .{lines}) catch "";
        pos += seq.len;
        // Clear each overlay line
        for (0..lines) |i| {
            if (i > 0) pos += cp(buf[pos..], "\x1b[B");
            pos += cp(buf[pos..], "\r\x1b[K");
        }
    } else {
        // Below: clear lines below prompt
        for (0..lines) |_| {
            pos += cp(buf[pos..], "\r\n\x1b[K");
        }
    }

    pos += cp(buf[pos..], "\x1b[u");
    stdout.writeAll(buf[0..pos]) catch {};

    // Restore block content for "above" (after cursor is back on prompt)
    if (direction == .above) {
        const block_ui = @import("block_ui.zig");
        if (block_ui.enabled and block_ui.saved_block_lines > 0) {
            var rbuf: [64]u8 = undefined;

            // Save cursor, move up, restore block lines, restore cursor
            stdout.writeAll("\x1b[s") catch {};
            const seq2 = std.fmt.bufPrint(&rbuf, "\x1b[{d}A\r", .{lines}) catch "";
            stdout.writeAll(seq2) catch {};

            const start = if (block_ui.saved_block_lines > lines) block_ui.saved_block_lines - lines else 0;
            block_ui.restoreBlockRange(stdout, start, lines);

            stdout.writeAll("\x1b[u") catch {};
        }
    }
}

fn insertCandidate(ed: *editor_mod.Editor, word_start: usize, word_end: usize, c: *const Candidate) void {
    const text = c.textSlice();
    var buf: [MAX_TEXT + 1]u8 = undefined;
    @memcpy(buf[0..text.len], text);
    var len = text.len;
    if (c.kind != .directory and len < buf.len) {
        buf[len] = ' ';
        len += 1;
    }
    ed.replaceRange(word_start, word_end, buf[0..len]);
}

fn kindColor(kind: CandidateKind, selected: bool) []const u8 {
    if (selected) {
        // Bright/bold text for selected row (bg set separately)
        return switch (kind) {
            .builtin => "\x1b[1;36m",
            .lua_cmd => "\x1b[1;35m",
            .alias => "\x1b[1;33m",
            .external_cmd => "\x1b[1;37m",
            .directory => "\x1b[1;34m",
            .file => "\x1b[1;37m",
            .env_var => "\x1b[1;33m",
            .flag => "\x1b[1;36m",
        };
    }
    return switch (kind) {
        .builtin => "\x1b[36m",
        .lua_cmd => "\x1b[35m",
        .alias => "\x1b[33m", // yellow
        .external_cmd => "\x1b[32m",
        .directory => "\x1b[34m", // blue
        .file => "\x1b[37m", // default
        .env_var => "\x1b[33m", // yellow
        .flag => "\x1b[36m", // cyan
    };
}

fn getTermHeight() usize {
    const c_ext = struct {
        const winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    };
    var ws: c_ext.winsize = undefined;
    if (c_ext.ioctl(posix.STDOUT_FILENO, 0x40087468, &ws) == 0 and ws.ws_row > 0) {
        return ws.ws_row;
    }
    return 24;
}

/// Compute visible width of prompt string's last line, skipping ANSI escapes.
fn promptVisibleWidth(prompt: []const u8) usize {
    // Find the last newline — only count from there
    const last_nl = if (std.mem.lastIndexOfScalar(u8, prompt, '\n')) |nl| nl + 1 else 0;
    const line = prompt[last_nl..];
    var vis: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\x1b') {
            if (i + 1 < line.len and line[i + 1] == '[') {
                i += 2;
                while (i < line.len and line[i] >= 0x20 and line[i] <= 0x3F) : (i += 1) {}
                if (i < line.len) i += 1;
            } else {
                i += 2;
            }
        } else if (line[i] & 0xC0 == 0x80) {
            i += 1; // UTF-8 continuation
        } else {
            vis += 1;
            i += 1;
        }
    }
    return vis;
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Inline (as-you-type) overlay
// ---------------------------------------------------------------------------

/// Persistent state for the inline completion overlay.
pub const InlineState = struct {
    active: bool = false,
    all: CandidateBuffer = .{},
    scored_indices: [MAX_CANDIDATES]usize = undefined,
    scored_values: [MAX_CANDIDATES]i32 = undefined,
    scored_count: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,
    max_visible: usize = 0,
    direction: overlay.Direction = .below,
    word_start: usize = 0,
    word_end: usize = 0,
    /// Lines rendered in the previous frame — used to clear leftover rows.
    prev_rendered: usize = 0,
};

/// Module-level inline state.
pub var inline_state: InlineState = .{};

/// Update the inline overlay after a keystroke. Gathers candidates,
/// scores them, and renders the overlay. Call from the input loop
/// after any content-changing key.
pub fn updateInline(
    ed: *const editor_mod.Editor,
    stdout: std.fs.File,
    prompt_str: []const u8,
    env: *const environ_mod.Environ,
    cmd_cache: *highlight.CommandCache,
    help_cache: ?*help_mod.HelpCache,
    hl_ctx: anytype,
) void {
    var s = &inline_state;

    // Dismiss if empty or cursor not at end
    if (ed.len == 0 or ed.cursor != ed.len) {
        if (s.active) dismissInline(stdout);
        return;
    }

    const ctx = analyzeContext(ed.content(), ed.cursor);

    // Don't show for redirect targets or env vars (too noisy)
    if (ctx.kind == .redirect_target or ctx.kind == .none) {
        if (s.active) dismissInline(stdout);
        return;
    }

    // Need at least 1 char of prefix for non-command positions
    if (ctx.kind != .command and ctx.prefix.len == 0) {
        if (s.active) dismissInline(stdout);
        return;
    }

    // Gather and score
    s.all.count = 0;
    providers.gather(&s.all, &ctx, env, cmd_cache, help_cache);
    if (s.all.count == 0) {
        if (s.active) dismissInline(stdout);
        return;
    }

    scoreAndFilter(&s.all, ctx.prefix, &s.scored_indices, &s.scored_values, &s.scored_count);
    if (s.scored_count == 0) {
        if (s.active) dismissInline(stdout);
        return;
    }

    // Don't show if the only candidate exactly matches what's typed
    if (s.scored_count == 1) {
        const only = s.all.items[s.scored_indices[0]].textSlice();
        if (std.mem.eql(u8, only, ctx.prefix)) {
            if (s.active) dismissInline(stdout);
            return;
        }
    }

    s.word_start = ctx.word_start;
    s.word_end = ctx.word_end;

    // Reset selection on content change
    s.selected = 0;
    s.scroll = 0;

    // Compute layout using actual screen position
    const layout = computeOverlayLayout();
    s.max_visible = layout.max_visible;
    s.direction = layout.direction;
    s.active = true;

    renderPicker(stdout, prompt_str, ed, &s.all, &s.scored_indices, s.scored_count, s.selected, s.scroll, s.max_visible, "", hl_ctx);
}

/// Cycle selection forward (Tab).
pub fn cycleInline(
    ed: *const editor_mod.Editor,
    stdout: std.fs.File,
    prompt_str: []const u8,
    hl_ctx: anytype,
) void {
    var s = &inline_state;
    if (!s.active or s.scored_count == 0) return;
    s.selected = if (s.selected + 1 >= s.scored_count) 0 else s.selected + 1;
    if (s.selected >= s.scroll + s.max_visible) s.scroll = s.selected - s.max_visible + 1;
    if (s.selected < s.scroll) s.scroll = s.selected;
    renderPicker(stdout, prompt_str, ed, &s.all, &s.scored_indices, s.scored_count, s.selected, s.scroll, s.max_visible, "", hl_ctx);
}

/// Cycle selection backward (Shift-Tab).
pub fn cycleInlineBack(
    ed: *const editor_mod.Editor,
    stdout: std.fs.File,
    prompt_str: []const u8,
    hl_ctx: anytype,
) void {
    var s = &inline_state;
    if (!s.active or s.scored_count == 0) return;
    s.selected = if (s.selected == 0) s.scored_count - 1 else s.selected - 1;
    if (s.selected < s.scroll) s.scroll = s.selected;
    if (s.selected >= s.scroll + s.max_visible) s.scroll = s.selected - s.max_visible + 1;
    renderPicker(stdout, prompt_str, ed, &s.all, &s.scored_indices, s.scored_count, s.selected, s.scroll, s.max_visible, "", hl_ctx);
}

/// Accept the currently selected candidate. Returns true if something was accepted.
pub fn acceptInline(ed: *editor_mod.Editor, stdout: std.fs.File) bool {
    var s = &inline_state;
    if (!s.active or s.scored_count == 0) return false;
    const idx = s.scored_indices[s.selected];
    insertCandidate(ed, s.word_start, ed.cursor, &s.all.items[idx]);
    dismissInline(stdout);
    return true;
}

/// Dismiss the inline overlay without accepting.
pub fn dismissInline(stdout: std.fs.File) void {
    var s = &inline_state;
    if (!s.active) return;
    // Clear the actual rendered lines (not max_visible)
    const lines_to_clear = if (s.prev_rendered > 0) s.prev_rendered else s.max_visible;
    if (lines_to_clear > 0) {
        clearPickerLines(stdout, lines_to_clear, s.direction);
    }
    s.active = false;
    s.scored_count = 0;
    s.prev_rendered = 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "analyzeContext: command position" {
    const ctx = analyzeContext("", 0);
    try std.testing.expectEqual(ContextKind.command, ctx.kind);
}

test "analyzeContext: argument position" {
    const ctx = analyzeContext("ls -la ", 7);
    try std.testing.expectEqual(ContextKind.argument, ctx.kind);
}

test "analyzeContext: flag position" {
    const ctx = analyzeContext("ls -", 4);
    try std.testing.expectEqual(ContextKind.flag, ctx.kind);
}

test "analyzeContext: redirect target" {
    const ctx = analyzeContext("echo hello > ", 13);
    try std.testing.expectEqual(ContextKind.redirect_target, ctx.kind);
}

test "scoreAndFilter ranks by score" {
    var buf = CandidateBuffer{};
    buf.add("project", .external_cmd);
    buf.add("parador", .external_cmd);
    buf.add("print", .external_cmd);

    var indices: [MAX_CANDIDATES]usize = undefined;
    var values: [MAX_CANDIDATES]i32 = undefined;
    var count: usize = 0;

    scoreAndFilter(&buf, "pro", &indices, &values, &count);
    try std.testing.expect(count >= 1);
    // "project" should rank first (prefix match)
    try std.testing.expectEqualStrings("project", buf.items[indices[0]].textSlice());
}
