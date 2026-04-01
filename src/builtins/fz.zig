// fz.zig — Fuzzy finder with full-screen TUI and inline modes.
//
// Full-screen (default): alternate screen buffer, bottom-up layout,
// status bar, multi-select, match highlighting, file type colors.
//
// Inline (--inline or embedded): renders below current line,
// no alternate screen. For use in pipelines or embedding.
//
// Usage:
//   fz                          # fuzzy find files (full-screen)
//   fz --inline                 # inline mode
//   ls | fz                     # pick from piped list
//   fz --multi                  # multi-select (Tab to toggle)
//   cat list.txt | fz --multi   # multi-select from file

const std = @import("std");
const posix = std.posix;
const c = std.c;
const fuzzy_mod = @import("../fuzzy.zig");
const Result = @import("mod.zig").BuiltinResult;

const MAX_ITEMS: usize = 8192;
const MAX_LINE: usize = 512;
const MAX_FILTER: usize = 256;

const Options = struct {
    multi: bool = false,
    inline_mode: bool = false,
    preview: bool = false,
    preview_cmd: ?[]const u8 = null, // custom preview command ({} = selected item)
};

pub fn run(args: []const []const u8, stdout: std.fs.File) Result {
    const opts = parseOptions(args);

    var items: ItemList = .{};
    collectFiles(".", &items, 0);

    if (items.count == 0) return .{ .exit_code = 1 };

    if (runInteractive(&items, opts, stdout)) {
        return .{};
    }
    return .{ .exit_code = 130 };
}

pub fn runFromPipe(args: []const []const u8) void {
    const opts = parseOptions(args);
    const stdout = std.fs.File{ .handle = posix.STDOUT_FILENO };
    const stdin = std.fs.File{ .handle = posix.STDIN_FILENO };

    var items: ItemList = .{};

    // Read piped input
    var read_buf: [524288]u8 = undefined;
    var total: usize = 0;
    while (total < read_buf.len) {
        const n = stdin.read(read_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    var iter = std.mem.splitScalar(u8, read_buf[0..total], '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;
        items.add(trimmed);
    }

    if (items.count == 0) std.process.exit(1);

    if (runInteractive(&items, opts, stdout)) {
        std.process.exit(0);
    }
    std.process.exit(130);
}

// ---------------------------------------------------------------------------
// Item storage
// ---------------------------------------------------------------------------

const ItemList = struct {
    bufs: [MAX_ITEMS][MAX_LINE]u8 = undefined,
    lens: [MAX_ITEMS]usize = undefined,
    count: usize = 0,

    fn add(self: *ItemList, text: []const u8) void {
        if (self.count >= MAX_ITEMS) return;
        const l = @min(text.len, MAX_LINE);
        @memcpy(self.bufs[self.count][0..l], text[0..l]);
        self.lens[self.count] = l;
        self.count += 1;
    }

    fn get(self: *const ItemList, idx: usize) []const u8 {
        return self.bufs[idx][0..self.lens[idx]];
    }
};

// ---------------------------------------------------------------------------
// Interactive picker (both modes)
// ---------------------------------------------------------------------------

fn runInteractive(items: *const ItemList, opts: Options, stdout: std.fs.File) bool {
    // Open /dev/tty for interactive I/O (stdout might be piped)
    const tty_fd = posix.openZ("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return false;
    defer posix.close(tty_fd);
    const tty = std.fs.File{ .handle = tty_fd };

    // Raw mode on tty
    var orig: std.c.termios = undefined;
    _ = std.c.tcgetattr(tty_fd, &orig);
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    _ = std.c.tcsetattr(tty_fd, .NOW, &raw);
    defer _ = std.c.tcsetattr(tty_fd, .NOW, &orig);

    const ts = getTermSize(tty_fd);
    const use_tui = !opts.inline_mode;

    // Alternate screen for TUI mode
    var alt_screen_active = false;
    if (use_tui) { tty.writeAll("\x1b[?1049h\x1b[?25h") catch {}; alt_screen_active = true; }
    defer if (alt_screen_active) tty.writeAll("\x1b[?1049l") catch {};

    var state = PickerState{
        .items = items,
        .term_rows = ts.rows,
        .term_cols = ts.cols,
        .multi = opts.multi,
        .preview = opts.preview and use_tui, // preview only in TUI mode
        .preview_cmd = opts.preview_cmd,
        .tui = use_tui,
    };

    state.score();
    state.render(tty);

    while (true) {
        var key_buf: [1]u8 = undefined;
        const rc = c.read(tty_fd, &key_buf, 1);
        if (rc <= 0) break;

        switch (key_buf[0]) {
            10, 13 => { // Enter
                // Exit alternate screen BEFORE writing result,
                // otherwise the output gets erased by screen restore.
                if (alt_screen_active) {
                    tty.writeAll("\x1b[?1049l") catch {};
                    alt_screen_active = false;
                }
                if (!use_tui) state.clearInline(tty);
                // Output selected items
                if (opts.multi and state.selected_count > 0) {
                    for (0..items.count) |i| {
                        if (state.selected_map[i]) {
                            stdout.writeAll(items.get(i)) catch {};
                            stdout.writeAll("\n") catch {};
                        }
                    }
                } else if (state.scored_count > 0) {
                    const idx = state.scored_idx[state.cursor];
                    stdout.writeAll(items.get(idx)) catch {};
                    stdout.writeAll("\n") catch {};
                } else {
                    return false;
                }
                return true;
            },
            27 => { // Escape sequence
                var seq: [2]u8 = undefined;
                const rc2 = c.read(tty_fd, &seq, 2);
                if (rc2 == 2 and seq[0] == '[') {
                    switch (seq[1]) {
                        'A' => state.moveUp(), // Up
                        'B' => state.moveDown(), // Down
                        'Z' => state.toggleSelect(), // Shift-Tab
                        else => {},
                    }
                } else if (rc2 <= 0) {
                    // Plain Escape
                    if (!use_tui) state.clearInline(tty);
                    return false;
                }
            },
            3 => { // Ctrl+C
                if (!use_tui) state.clearInline(tty);
                return false;
            },
            9 => state.toggleSelect(), // Tab — toggle multi-select
            21 => { // Ctrl+U — clear filter
                state.filter_len = 0;
                state.cursor = 0;
                state.scroll = 0;
                state.score();
            },
            23 => { // Ctrl+W — delete word backward
                if (state.filter_len > 0) {
                    var end = state.filter_len;
                    while (end > 0 and state.filter[end - 1] == ' ') : (end -= 1) {}
                    while (end > 0 and state.filter[end - 1] != ' ' and state.filter[end - 1] != '/') : (end -= 1) {}
                    state.filter_len = end;
                    state.cursor = 0;
                    state.scroll = 0;
                    state.score();
                }
            },
            127, 8 => { // Backspace
                if (state.filter_len > 0) {
                    state.filter_len -= 1;
                    state.cursor = 0;
                    state.scroll = 0;
                    state.score();
                }
            },
            else => |byte| {
                if (byte >= 32 and byte < 127 and state.filter_len < MAX_FILTER) {
                    state.filter[state.filter_len] = byte;
                    state.filter_len += 1;
                    state.cursor = 0;
                    state.scroll = 0;
                    state.score();
                }
            },
        }

        state.render(tty);
    }

    if (!use_tui) state.clearInline(tty);
    return false;
}

// ---------------------------------------------------------------------------
// Picker state
// ---------------------------------------------------------------------------

const PickerState = struct {
    items: *const ItemList,
    filter: [MAX_FILTER]u8 = undefined,
    filter_len: usize = 0,
    scored_idx: [MAX_ITEMS]usize = undefined,
    scored_vals: [MAX_ITEMS]i32 = undefined,
    scored_positions: [MAX_ITEMS][fuzzy_mod.max_positions]u8 = undefined,
    scored_match_counts: [MAX_ITEMS]u8 = undefined,
    scored_count: usize = 0,
    cursor: usize = 0,
    scroll: usize = 0,
    selected_map: [MAX_ITEMS]bool = [_]bool{false} ** MAX_ITEMS,
    selected_count: usize = 0,
    multi: bool = false,
    preview: bool = false,
    preview_cmd: ?[]const u8 = null,
    tui: bool = true,
    term_rows: usize = 24,
    term_cols: usize = 80,
    rendered_lines: usize = 0,

    fn visibleRows(self: *const PickerState) usize {
        if (self.tui) return if (self.term_rows > 3) self.term_rows - 2 else 1; // status + prompt
        return @min(20, if (self.term_rows > 5) self.term_rows - 4 else 5);
    }

    fn score(self: *PickerState) void {
        self.scored_count = 0;
        const f = self.filter[0..self.filter_len];
        for (0..self.items.count) |i| {
            const text = self.items.get(i);
            if (f.len == 0) {
                self.scored_idx[self.scored_count] = i;
                self.scored_vals[self.scored_count] = 0;
                self.scored_match_counts[self.scored_count] = 0;
                self.scored_count += 1;
            } else {
                const s = fuzzy_mod.score(text, f);
                if (s.matched) {
                    var pos = self.scored_count;
                    while (pos > 0 and self.scored_vals[pos - 1] < s.value) {
                        self.scored_idx[pos] = self.scored_idx[pos - 1];
                        self.scored_vals[pos] = self.scored_vals[pos - 1];
                        self.scored_positions[pos] = self.scored_positions[pos - 1];
                        self.scored_match_counts[pos] = self.scored_match_counts[pos - 1];
                        pos -= 1;
                    }
                    self.scored_idx[pos] = i;
                    self.scored_vals[pos] = s.value;
                    self.scored_positions[pos] = s.positions;
                    self.scored_match_counts[pos] = s.match_count;
                    self.scored_count += 1;
                    if (self.scored_count >= MAX_ITEMS) break;
                }
            }
        }
    }

    fn moveUp(self: *PickerState) void {
        if (self.tui) {
            // TUI: up moves toward top of list (lower index visually at bottom)
            if (self.cursor + 1 < self.scored_count) self.cursor += 1;
            const vis = self.visibleRows();
            if (self.cursor >= self.scroll + vis) self.scroll = self.cursor - vis + 1;
        } else {
            if (self.cursor > 0) self.cursor -= 1;
            if (self.cursor < self.scroll) self.scroll = self.cursor;
        }
    }

    fn moveDown(self: *PickerState) void {
        if (self.tui) {
            if (self.cursor > 0) self.cursor -= 1;
            if (self.cursor < self.scroll) self.scroll = self.cursor;
        } else {
            if (self.scored_count > 0 and self.cursor + 1 < self.scored_count) self.cursor += 1;
            const vis = self.visibleRows();
            if (self.cursor >= self.scroll + vis) self.scroll = self.cursor - vis + 1;
        }
    }

    fn toggleSelect(self: *PickerState) void {
        if (!self.multi or self.scored_count == 0) return;
        const idx = self.scored_idx[self.cursor];
        if (self.selected_map[idx]) {
            self.selected_map[idx] = false;
            self.selected_count -= 1;
        } else {
            self.selected_map[idx] = true;
            self.selected_count += 1;
        }
        self.moveDown();
    }

    fn render(self: *PickerState, tty: std.fs.File) void {
        if (self.tui) self.renderTui(tty) else self.renderInline(tty);
    }

    // ----- TUI (full-screen) rendering -----

    fn renderTui(self: *PickerState, tty: std.fs.File) void {
        var buf: [32768]u8 = undefined;
        var pos: usize = 0;

        pos += cp(buf[pos..], "\x1b[H\x1b[?25l");

        const vis = self.visibleRows();
        const visible_end = @min(self.scroll + vis, self.scored_count);
        const list_width = if (self.preview) self.term_cols / 2 else self.term_cols;

        // Load preview content if enabled
        var preview_lines: [64][]const u8 = undefined;
        var preview_count: usize = 0;
        var preview_buf: [4096]u8 = undefined;
        if (self.preview and self.scored_count > 0) {
            const cur_idx = self.scored_idx[self.cursor];
            preview_count = loadPreview(self.items.get(cur_idx), self.preview_cmd, &preview_buf, &preview_lines);
        }

        const rendered = visible_end - self.scroll;
        const empty = if (self.term_rows > rendered + 2) self.term_rows - rendered - 2 else 0;

        // Empty rows
        for (0..empty) |row_i| {
            pos += cp(buf[pos..], "\x1b[2K");
            if (self.preview) {
                // Draw preview separator + content
                self.renderPreviewRow(&buf, &pos, list_width, row_i, &preview_lines, preview_count, empty);
            }
            pos += cp(buf[pos..], "\r\n");
        }

        // Items (bottom-up)
        var ri: usize = visible_end;
        var row_from_top: usize = empty;
        while (ri > self.scroll) {
            ri -= 1;
            pos += cp(buf[pos..], "\x1b[2K");
            const item_idx = self.scored_idx[ri];
            const text = self.items.get(item_idx);
            const is_cursor = (ri == self.cursor);
            const is_selected = self.selected_map[item_idx];

            if (is_cursor) {
                pos += cp(buf[pos..], "\x1b[1;36m>\x1b[0m ");
            } else if (is_selected) {
                pos += cp(buf[pos..], "\x1b[32m*\x1b[0m ");
            } else {
                pos += cp(buf[pos..], "  ");
            }

            const base = if (is_cursor) "\x1b[1;37m" else fileColor(text);
            const hl = if (is_cursor) "\x1b[1;33m" else "\x1b[1;31m";
            pos += cp(buf[pos..], base);
            renderHighlightedText(
                &buf, &pos, text,
                list_width -| 4,
                &self.scored_positions[ri],
                self.scored_match_counts[ri],
                base, hl,
            );
            pos += cp(buf[pos..], "\x1b[0m");

            if (self.preview) {
                self.renderPreviewRow(&buf, &pos, list_width, row_from_top, &preview_lines, preview_count, empty);
            }
            pos += cp(buf[pos..], "\r\n");
            row_from_top += 1;

            if (pos > buf.len - 1024) {
                tty.writeAll(buf[0..pos]) catch {};
                pos = 0;
            }
        }

        // Status bar
        pos += cp(buf[pos..], "\x1b[2K\x1b[2m");
        const status = std.fmt.bufPrint(buf[pos..], "  {d}/{d}", .{ self.scored_count, self.items.count }) catch "";
        pos += status.len;
        if (self.multi) {
            const sel = std.fmt.bufPrint(buf[pos..], " ({d})", .{self.selected_count}) catch "";
            pos += sel.len;
        }
        pos += cp(buf[pos..], " ");
        const sel_extra: usize = if (self.multi) 6 else 0;
        const status_vis = status.len + sel_extra + 2;
        var fi: usize = status_vis;
        while (fi < self.term_cols) : (fi += 1) {
            pos += cp(buf[pos..], "\xe2\x94\x80");
        }
        pos += cp(buf[pos..], "\x1b[0m\r\n");

        // Prompt
        pos += cp(buf[pos..], "\x1b[2K\x1b[1;36m> \x1b[0m");
        pos += cp(buf[pos..], self.filter[0..self.filter_len]);
        pos += cp(buf[pos..], "\x1b[?25h");

        tty.writeAll(buf[0..pos]) catch {};
    }

    // ----- Inline rendering -----

    fn renderInline(self: *PickerState, tty: std.fs.File) void {
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;

        pos += cp(buf[pos..], "\x1b[?25l\x1b[s");

        // Prompt
        pos += cp(buf[pos..], "\r\x1b[K\x1b[1;36m> \x1b[0m");
        pos += cp(buf[pos..], self.filter[0..self.filter_len]);
        pos += cp(buf[pos..], "\x1b[2m");
        const cnt = std.fmt.bufPrint(buf[pos..], "  {d}/{d}", .{ self.scored_count, self.items.count }) catch "";
        pos += cnt.len;
        pos += cp(buf[pos..], "\x1b[0m");

        const vis = self.visibleRows();
        const visible_end = @min(self.scroll + vis, self.scored_count);

        for (self.scroll..visible_end) |i| {
            pos += cp(buf[pos..], "\r\n\x1b[K");
            const idx = self.scored_idx[i];
            const text = self.items.get(idx);
            const is_cursor = (i == self.cursor);
            const is_selected = self.selected_map[idx];

            if (is_cursor) {
                pos += cp(buf[pos..], "\x1b[48;5;238m\x1b[1;37m ");
            } else if (is_selected) {
                pos += cp(buf[pos..], "\x1b[32m* ");
            } else {
                pos += cp(buf[pos..], "  ");
            }

            const base = if (is_cursor) "\x1b[48;5;238m\x1b[1;37m" else "\x1b[37m";
            const hl = if (is_cursor) "\x1b[48;5;238m\x1b[1;33m" else "\x1b[1;31m";
            renderHighlightedText(
                &buf, &pos, text,
                buf.len - pos - 20,
                &self.scored_positions[i],
                self.scored_match_counts[i],
                base, hl,
            );

            if (is_cursor) pos += cp(buf[pos..], " \x1b[0m");
        }

        // Clear leftover
        var vi = visible_end - self.scroll;
        while (vi < self.rendered_lines) : (vi += 1) {
            pos += cp(buf[pos..], "\r\n\x1b[K");
        }
        self.rendered_lines = visible_end - self.scroll;

        pos += cp(buf[pos..], "\x1b[u\x1b[?25h");
        const cursor_col = 2 + self.filter_len;
        const cseq = std.fmt.bufPrint(buf[pos..], "\r\x1b[{d}C", .{cursor_col}) catch "";
        pos += cseq.len;

        tty.writeAll(buf[0..pos]) catch {};
    }

    /// Render the preview column for a given screen row.
    fn renderPreviewRow(
        self: *const PickerState,
        buf: *[32768]u8,
        pos: *usize,
        list_width: usize,
        row: usize,
        preview_lines: *const [64][]const u8,
        preview_count: usize,
        _empty: usize,
    ) void {
        _ = _empty;
        // Move to preview column
        const col_seq = std.fmt.bufPrint(buf[pos.*..], "\x1b[{d}G", .{list_width + 1}) catch "";
        pos.* += col_seq.len;
        // Separator
        pos.* += cp(buf[pos.*..], "\x1b[2m\xe2\x94\x82\x1b[0m ");
        // Preview content
        const preview_width = if (self.term_cols > list_width + 3) self.term_cols - list_width - 3 else 1;
        if (row < preview_count) {
            const line = preview_lines[row];
            const tl = @min(line.len, preview_width);
            pos.* += cp(buf[pos.*..], "\x1b[2m");
            @memcpy(buf[pos.*..][0..tl], line[0..tl]);
            pos.* += tl;
            pos.* += cp(buf[pos.*..], "\x1b[0m");
        }
    }

    fn clearInline(self: *PickerState, tty: std.fs.File) void {
        var buf: [512]u8 = undefined;
        var pos: usize = 0;
        pos += cp(buf[pos..], "\r\x1b[K");
        for (0..self.rendered_lines) |_| {
            pos += cp(buf[pos..], "\r\n\x1b[K");
        }
        if (self.rendered_lines > 0) {
            const seq = std.fmt.bufPrint(buf[pos..], "\x1b[{d}A\r", .{self.rendered_lines}) catch "";
            pos += seq.len;
        }
        tty.writeAll(buf[0..pos]) catch {};
    }
};

// ---------------------------------------------------------------------------
// File collection
// ---------------------------------------------------------------------------

fn collectFiles(dir_path: []const u8, items: *ItemList, depth: usize) void {
    if (depth > 8 or items.count >= MAX_ITEMS) return;

    var dir = if (dir_path[0] == '/')
        std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return
    else
        std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (items.count >= MAX_ITEMS) return;
        // Skip hidden files and common noise
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
        if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;
        if (std.mem.eql(u8, entry.name, "target")) continue;

        var path_buf: [MAX_LINE]u8 = undefined;
        var pl: usize = 0;
        if (!std.mem.eql(u8, dir_path, ".")) {
            const dl = @min(dir_path.len, MAX_LINE);
            @memcpy(path_buf[0..dl], dir_path[0..dl]);
            pl = dl;
            if (pl < MAX_LINE) { path_buf[pl] = '/'; pl += 1; }
        }
        const nl = @min(entry.name.len, MAX_LINE - pl);
        @memcpy(path_buf[pl..][0..nl], entry.name[0..nl]);
        pl += nl;

        items.add(path_buf[0..pl]);

        if (entry.kind == .directory) {
            collectFiles(path_buf[0..pl], items, depth + 1);
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Render text with fuzzy match positions highlighted.
fn renderHighlightedText(
    buf: []u8,
    pos: *usize,
    text: []const u8,
    max_len: usize,
    positions: []const u8,
    match_count: u8,
    base_color: []const u8,
    highlight_color: []const u8,
) void {
    const len = @min(text.len, max_len);
    var in_highlight = false;

    for (0..len) |ci| {
        // Check if this character position is a match
        var is_match = false;
        for (0..match_count) |mi| {
            if (positions[mi] == ci) { is_match = true; break; }
        }

        if (is_match and !in_highlight) {
            pos.* += cp(buf[pos.*..], highlight_color);
            in_highlight = true;
        } else if (!is_match and in_highlight) {
            pos.* += cp(buf[pos.*..], "\x1b[0m");
            pos.* += cp(buf[pos.*..], base_color);
            in_highlight = false;
        }

        if (pos.* < buf.len) { buf[pos.*] = text[ci]; pos.* += 1; }
    }

    if (in_highlight) pos.* += cp(buf[pos.*..], "\x1b[0m");
}

/// Load preview content for an item. Returns line count.
fn loadPreview(
    item: []const u8,
    custom_cmd: ?[]const u8,
    preview_buf: *[4096]u8,
    lines: *[64][]const u8,
) usize {
    if (custom_cmd) |cmd_template| {
        // Custom preview: replace {} with item path
        var cmd_buf: [1024]u8 = undefined;
        var cl: usize = 0;
        for (cmd_template) |ch| {
            if (ch == '{' and cl + 1 < cmd_template.len) {
                // Check for {}
                const rest = cmd_template[cl..];
                _ = rest;
            }
            if (cl < cmd_buf.len) { cmd_buf[cl] = ch; cl += 1; }
        }
        // Simple replacement
        cl = 0;
        var i: usize = 0;
        while (i < cmd_template.len) {
            if (i + 1 < cmd_template.len and cmd_template[i] == '{' and cmd_template[i + 1] == '}') {
                const n = @min(item.len, cmd_buf.len - cl);
                @memcpy(cmd_buf[cl..][0..n], item[0..n]);
                cl += n;
                i += 2;
            } else {
                if (cl < cmd_buf.len) { cmd_buf[cl] = cmd_template[i]; cl += 1; }
                i += 1;
            }
        }
        return runPreviewCmd(cmd_buf[0..cl], preview_buf, lines);
    }

    // Default: try to read file content
    const file = std.fs.cwd().openFile(item, .{}) catch return 0;
    defer file.close();

    const n = file.read(preview_buf) catch return 0;
    if (n == 0) return 0;

    // Check if binary (has null bytes in first 512 bytes)
    const check = @min(n, 512);
    for (preview_buf[0..check]) |ch| {
        if (ch == 0) {
            lines[0] = "[binary file]";
            return 1;
        }
    }

    // Split into lines
    var count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, preview_buf[0..n], '\n');
    while (line_iter.next()) |line| {
        if (count >= 64) break;
        lines[count] = line;
        count += 1;
    }
    return count;
}

fn runPreviewCmd(cmd: []const u8, preview_buf: *[4096]u8, lines: *[64][]const u8) usize {
    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", cmd },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;

    var total: usize = 0;
    if (child.stdout) |f| {
        while (total < preview_buf.len) {
            const n = f.read(preview_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    _ = child.wait() catch {};

    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, preview_buf[0..total], '\n');
    while (iter.next()) |line| {
        if (count >= 64) break;
        lines[count] = line;
        count += 1;
    }
    return count;
}

fn fileColor(path: []const u8) []const u8 {
    if (path.len > 0 and path[path.len - 1] == '/') return "\x1b[1;34m"; // directory
    if (std.mem.endsWith(u8, path, ".zig")) return "\x1b[33m"; // zig
    if (std.mem.endsWith(u8, path, ".lua")) return "\x1b[35m"; // lua
    if (std.mem.endsWith(u8, path, ".md")) return "\x1b[36m"; // markdown
    if (std.mem.endsWith(u8, path, ".json")) return "\x1b[32m"; // json
    if (std.mem.endsWith(u8, path, ".toml") or std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) return "\x1b[32m";
    if (std.mem.endsWith(u8, path, ".sh") or std.mem.endsWith(u8, path, ".bash")) return "\x1b[33m";
    if (std.mem.endsWith(u8, path, ".py")) return "\x1b[33m";
    if (std.mem.endsWith(u8, path, ".rs")) return "\x1b[31m"; // rust
    if (std.mem.endsWith(u8, path, ".go")) return "\x1b[36m"; // go
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx")) return "\x1b[34m"; // typescript
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".jsx")) return "\x1b[33m"; // javascript
    if (std.mem.endsWith(u8, path, ".css") or std.mem.endsWith(u8, path, ".scss")) return "\x1b[35m";
    if (std.mem.endsWith(u8, path, ".html")) return "\x1b[31m";
    return "\x1b[37m";
}

fn parseOptions(args: []const []const u8) Options {
    var opts = Options{};
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--multi") or std.mem.eql(u8, arg, "-m")) {
            opts.multi = true;
        } else if (std.mem.eql(u8, arg, "--inline") or std.mem.eql(u8, arg, "-i")) {
            opts.inline_mode = true;
        } else if (std.mem.eql(u8, arg, "--preview") or std.mem.eql(u8, arg, "-p")) {
            opts.preview = true;
        } else if (std.mem.eql(u8, arg, "--preview-cmd") and i + 1 < args.len) {
            opts.preview = true;
            i += 1;
            opts.preview_cmd = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
        }
        i += 1;
    }
    return opts;
}

fn printHelp() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll(
        \\fz — fuzzy finder
        \\
        \\Usage:
        \\  fz [options]              Find files in current directory
        \\  ... | fz [options]        Pick from piped input
        \\
        \\Options:
        \\  -m, --multi               Enable multi-select (Tab to toggle, Enter to confirm)
        \\  -p, --preview             Show file preview (right pane)
        \\  --preview-cmd "cmd {}"    Custom preview command ({} is replaced with selected item)
        \\  -i, --inline              Inline mode (no alternate screen, for embedding)
        \\  -h, --help                Show this help
        \\
        \\Keys:
        \\  Up/Down                   Navigate
        \\  Tab                       Toggle selection (multi-select mode)
        \\  Enter                     Confirm selection
        \\  Escape / Ctrl+C           Cancel
        \\  Type to filter            Fuzzy search
        \\
        \\Examples:
        \\  fz                        Fuzzy find files
        \\  fz -p                     Find files with preview
        \\  fz --multi                Multi-select files
        \\  ls | fz                   Pick from ls output
        \\  cat urls.txt | fz         Pick a URL
        \\  fz --preview-cmd "head -20 {}"   Custom preview
        \\
    ) catch {};
}

fn getTermSize(fd: posix.fd_t) struct { rows: usize, cols: usize } {
    const c_ext = struct {
        const winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        extern "c" fn ioctl(fdd: c_int, request: c_ulong, ...) c_int;
    };
    var ws: c_ext.winsize = undefined;
    if (c_ext.ioctl(fd, 0x40087468, &ws) == 0) {
        return .{
            .rows = if (ws.ws_row > 0) ws.ws_row else 24,
            .cols = if (ws.ws_col > 0) ws.ws_col else 80,
        };
    }
    return .{ .rows = 24, .cols = 80 };
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}
