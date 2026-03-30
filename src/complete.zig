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

    const term_h = getTermHeight();
    const max_visible = @min(MAX_VISIBLE, if (term_h > 4) term_h - 3 else 3);

    // Render initial picker
    renderPicker(stdout, prompt_str, ed, &all, &scored_indices, scored_count, selected, scroll, max_visible, filter[0..filter_len], hl_ctx);

    // Picker key loop
    while (true) {
        const key = keys.readKey() catch break;

        switch (key) {
            .enter, .right => {
                // Accept selected candidate
                if (scored_count > 0) {
                    const idx = scored_indices[selected];
                    insertCandidate(ed, ctx.word_start, ed.cursor, &all.items[idx]);
                }
                clearPickerArea(stdout, max_visible);
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
                clearPickerArea(stdout, max_visible);
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

    clearPickerArea(stdout, max_visible);
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

    // Redraw prompt line
    pos += cp(buf[pos..], "\r\x1b[K");
    pos += cp(buf[pos..], prompt_str);

    // Editor content with highlighting
    const hl_mod = @import("highlight.zig");
    if (@TypeOf(hl_ctx) != @TypeOf(null)) {
        pos += hl_mod.renderHighlighted(buf[pos..], ed.content(), hl_ctx.cache, hl_ctx.env);
    } else {
        pos += cp(buf[pos..], ed.content());
    }

    // Save cursor position
    pos += cp(buf[pos..], "\x1b[s");

    // Draw candidates below — table layout with aligned columns
    const visible_end = @min(scroll + max_visible, count);

    // Compute column widths for table layout
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

    for (scroll..visible_end) |i| {
        pos += cp(buf[pos..], "\r\n\x1b[K");
        const idx = indices[i];
        const cand = &all.items[idx];
        const text = cand.textSlice();
        const desc = cand.descSlice();
        const is_sel = (i == selected);

        // Row background for selection — full width
        if (is_sel) pos += cp(buf[pos..], "\x1b[48;5;236m"); // dark gray bg

        // Candidate text with kind-specific color
        const style = kindColor(cand.kind, is_sel);
        pos += cp(buf[pos..], style);
        pos += cp(buf[pos..], text);
        pos += cp(buf[pos..], "\x1b[0m");
        if (is_sel) pos += cp(buf[pos..], "\x1b[48;5;236m"); // restore bg

        // Pad + description
        if (desc.len > 0) {
            const pad = if (col_w > text.len) col_w - text.len else 1;
            for (0..pad) |_| {
                if (pos < buf.len) { buf[pos] = ' '; pos += 1; }
            }
            if (is_sel) pos += cp(buf[pos..], "\x1b[38;5;245m") else pos += cp(buf[pos..], "\x1b[38;5;242m"); // dim gray text
            pos += cp(buf[pos..], desc);
            pos += cp(buf[pos..], "\x1b[0m");
            if (is_sel) pos += cp(buf[pos..], "\x1b[48;5;236m");
        }

        // Pad rest of row to max width for uniform selection highlight
        const visible_len = text.len + (if (desc.len > 0) col_w - text.len + desc.len else 0);
        if (is_sel and max_row_w > visible_len) {
            const trail = max_row_w - visible_len;
            for (0..trail) |_| {
                if (pos < buf.len) { buf[pos] = ' '; pos += 1; }
            }
        }

        pos += cp(buf[pos..], "\x1b[0m");
    }

    // Clear any leftover lines from previous render
    for (0..max_visible -| (visible_end - scroll)) |_| {
        pos += cp(buf[pos..], "\r\n\x1b[K");
    }

    // Restore cursor position
    pos += cp(buf[pos..], "\x1b[u");

    // Position cursor within the line
    const after = ed.len - ed.cursor;
    if (after > 0) {
        const n = std.fmt.bufPrint(buf[pos..], "\x1b[{d}D", .{after}) catch "";
        pos += n.len;
    }

    stdout.writeAll(buf[0..pos]) catch {};
}

fn clearPickerArea(stdout: std.fs.File, max_visible: usize) void {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    // Move down and clear each line
    for (0..max_visible) |_| {
        pos += cp(buf[pos..], "\r\n\x1b[K");
    }
    // Move back up
    const n = std.fmt.bufPrint(buf[pos..], "\x1b[{d}A", .{max_visible}) catch "";
    pos += n.len;
    stdout.writeAll(buf[0..pos]) catch {};
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
        // Bright text on dark bg for selected row
        return switch (kind) {
            .builtin => "\x1b[48;5;236m\x1b[1;36m",
            .lua_cmd => "\x1b[48;5;236m\x1b[1;35m",
            .alias => "\x1b[48;5;236m\x1b[1;33m", // bold yellow
            .external_cmd => "\x1b[48;5;236m\x1b[1;37m",
            .directory => "\x1b[48;5;236m\x1b[1;34m", // bold blue
            .file => "\x1b[48;5;236m\x1b[37m", // white
            .env_var => "\x1b[48;5;236m\x1b[1;33m", // bold yellow
            .flag => "\x1b[48;5;236m\x1b[1;36m", // bold cyan
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

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
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
