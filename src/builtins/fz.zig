// fz.zig — Fuzzy finder with full-screen TUI and inline modes.
//
// Full-screen (default): alternate screen, bottom-up layout,
// status bar, multi-select, match highlighting, file type colors.
// Uses Screen for flicker-free double-buffered rendering.
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
const style = @import("../style.zig");
const tui = @import("../tui.zig");
const keys = @import("../keys.zig");
const Result = @import("mod.zig").BuiltinResult;
const fzh = @import("fz_helpers.zig");

const Screen = tui.Screen;
const Key = keys.Key;

const MAX_ITEMS = fzh.MAX_ITEMS;
const MAX_LINE = fzh.MAX_LINE;
const ItemList = fzh.ItemList;
const collectFiles = fzh.collectFiles;
const loadPreview = fzh.loadPreview;
const renderHighlightedText = fzh.renderHighlightedText;
const fileColorEnum = fzh.fileColorEnum;
const exactContains = fzh.exactContains;
const getTermSize = fzh.getTermSize;
const cp = fzh.cp;
const Options = fzh.Options;
const parseOptions = fzh.parseOptions;

pub fn run(args: []const []const u8, stdout: std.fs.File) Result {
    const opts = parseOptions(args);
    var items: ItemList = .{};
    collectFiles(".", &items, 0);
    if (items.count == 0) return .{ .exit_code = 1 };
    if (runInteractive(&items, opts, stdout)) return .{};
    return .{ .exit_code = 1 }; // 1 = cancelled/no selection (fzf convention)
}

pub fn runFromPipe(args: []const []const u8) void {
    const opts = parseOptions(args);
    const stdout = std.fs.File{ .handle = posix.STDOUT_FILENO };
    const stdin = std.fs.File{ .handle = posix.STDIN_FILENO };

    var items: ItemList = .{};
    var header_buf: [MAX_ITEMS][MAX_LINE]u8 = undefined;
    var header_lens: [MAX_ITEMS]usize = undefined;
    var header_count: usize = 0;
    var read_buf: [524288]u8 = undefined;
    var total: usize = 0;
    while (total < read_buf.len) {
        const n = stdin.read(read_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    var line_num: usize = 0;
    var iter = std.mem.splitScalar(u8, read_buf[0..total], '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;
        // --header-lines: first N lines become header, not items
        if (line_num < opts.header_lines and header_count < MAX_ITEMS) {
            const hl = @min(trimmed.len, MAX_LINE);
            @memcpy(header_buf[header_count][0..hl], trimmed[0..hl]);
            header_lens[header_count] = hl;
            header_count += 1;
            line_num += 1;
            continue;
        }
        items.add(trimmed);
        line_num += 1;
    }
    if (items.count == 0) std.process.exit(1);
    // Build combined header from --header and --header-lines
    var combined_header_buf: [2048]u8 = undefined;
    var combined_opts = opts;
    if (header_count > 0) {
        var hp: usize = 0;
        // Append --header first if present
        if (opts.header) |h| {
            const hl = @min(h.len, combined_header_buf.len);
            @memcpy(combined_header_buf[hp..][0..hl], h[0..hl]);
            hp += hl;
            if (hp < combined_header_buf.len) { combined_header_buf[hp] = '\n'; hp += 1; }
        }
        for (0..header_count) |hi| {
            const hl = @min(header_lens[hi], combined_header_buf.len - hp);
            @memcpy(combined_header_buf[hp..][0..hl], header_buf[hi][0..hl]);
            hp += hl;
            if (hi + 1 < header_count and hp < combined_header_buf.len) {
                combined_header_buf[hp] = '\n';
                hp += 1;
            }
        }
        combined_opts.header = combined_header_buf[0..hp];
    }
    if (runInteractive(&items, combined_opts, stdout)) std.process.exit(0);
    std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Interactive picker
// ---------------------------------------------------------------------------

fn runInteractive(items: *const ItemList, opts: Options, stdout: std.fs.File) bool {
    const tty_fd = posix.openZ("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return false;
    defer posix.close(tty_fd);
    const tty = std.fs.File{ .handle = tty_fd };

    var orig: c.termios = undefined;
    _ = c.tcgetattr(tty_fd, &orig);
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    _ = c.tcsetattr(tty_fd, .NOW, &raw);
    defer _ = c.tcsetattr(tty_fd, .NOW, &orig);

    const ts = getTermSize(tty_fd);
    const use_tui = !opts.inline_mode;

    var alt_screen_active = false;
    if (use_tui) {
        var ebuf: [64]u8 = undefined;
        var ep: usize = 0;
        ep += style.altScreenOn(ebuf[ep..]);
        ep += style.showCursor(ebuf[ep..]);
        tty.writeAll(ebuf[0..ep]) catch {};
        alt_screen_active = true;
    }
    defer if (alt_screen_active) tty.writeAll("\x1b[?1049l") catch {};

    const eff_rows = if (opts.height) |h| @min(h, ts.rows) else ts.rows;

    var state = PickerState{
        .items = items,
        .term_rows = eff_rows,
        .term_cols = ts.cols,
        .multi = opts.multi,
        .preview = opts.preview and use_tui,
        .preview_cmd = opts.preview_cmd,
        .tui = use_tui,
        .exact = opts.exact,
        .reverse = opts.reverse,
        .header = opts.header,
        .print0 = opts.print0,
    };
    state.input.prompt = opts.prompt;
    state.input.prompt_color = .cyan;
    state.input.focused = true;
    // Pre-populate query if --query was given
    if (opts.query) |q| {
        for (q) |ch| _ = state.input.handleKey(.{ .char = ch });
    }
    state.score();

    // Screen for TUI mode
    var screen: Screen = undefined;
    if (use_tui) {
        screen = Screen.init(
            @intCast(@min(ts.cols, Screen.max_cols)),
            @intCast(@min(ts.rows, Screen.max_rows)),
        );
        state.drawTui(&screen);
        screen.flush(tty);
    } else {
        state.renderInline(tty);
    }

    while (true) {
        const key = keys.readKeyFromFd(tty_fd) orelse break;

        if (key == .resize) {
            const new_ts = getTermSize(tty_fd);
            state.term_rows = new_ts.rows;
            state.term_cols = new_ts.cols;
            if (use_tui) {
                screen.resize(
                    @intCast(@min(new_ts.cols, Screen.max_cols)),
                    @intCast(@min(new_ts.rows, Screen.max_rows)),
                );
                state.drawTui(&screen);
                screen.flush(tty);
            } else {
                state.renderInline(tty);
            }
            continue;
        }

        switch (key) {
            .enter => {
                if (alt_screen_active) { tty.writeAll("\x1b[?1049l") catch {}; alt_screen_active = false; }
                if (!use_tui) state.clearInline(tty);
                const sep: []const u8 = if (state.print0) "\x00" else "\n";
                if (opts.multi and state.selected_count > 0) {
                    for (0..items.count) |i| {
                        if (state.selected_map[i]) {
                            stdout.writeAll(items.get(i)) catch {};
                            stdout.writeAll(sep) catch {};
                        }
                    }
                } else if (state.filter.count > 0) {
                    const idx = state.filter.buf[state.cursor].index;
                    stdout.writeAll(items.get(idx)) catch {};
                    stdout.writeAll(sep) catch {};
                } else {
                    return false;
                }
                return true;
            },
            .escape, .ctrl_c => {
                if (!use_tui) state.clearInline(tty);
                return false;
            },
            .up => state.moveUp(),
            .down => state.moveDown(),
            .tab => state.toggleSelect(),
            .shift_tab => state.toggleSelect(),
            else => {
                const action = state.input.handleKey(key);
                if (action == .changed) {
                    state.cursor = 0;
                    state.scroll = 0;
                    state.score();
                }
            },
        }

        if (use_tui) {
            screen.beginFrame();
            state.drawTui(&screen);
            screen.flush(tty);
        } else {
            state.renderInline(tty);
        }
    }

    if (!use_tui) state.clearInline(tty);
    return false;
}

// ---------------------------------------------------------------------------
// Picker state
// ---------------------------------------------------------------------------

const PickerState = struct {
    items: *const ItemList,
    input: tui.Input = .{},
    filter: tui.FuzzyFilter(MAX_ITEMS) = tui.FuzzyFilter(MAX_ITEMS).init(),
    cursor: usize = 0,
    scroll: usize = 0,
    selected_map: [MAX_ITEMS]bool = [_]bool{false} ** MAX_ITEMS,
    selected_count: usize = 0,
    multi: bool = false,
    preview: bool = false,
    preview_cmd: ?[]const u8 = null,
    tui: bool = true,
    exact: bool = false,
    reverse: bool = false,
    header: ?[]const u8 = null,
    print0: bool = false,
    term_rows: usize = 24,
    term_cols: usize = 80,
    rendered_lines: usize = 0,

    fn visibleRows(self: *const PickerState) usize {
        const header_rows = if (self.header) |h| std.mem.count(u8, h, "\n") + 1 else 0;
        if (self.tui) {
            const overhead = 2 + header_rows; // status + prompt + header
            return if (self.term_rows > overhead) self.term_rows - overhead else 1;
        }
        return @min(20, if (self.term_rows > 5) self.term_rows - 4 else 5);
    }

    fn score(self: *PickerState) void {
        const query = self.input.value();
        self.filter.reset();
        if (self.exact and query.len > 0) {
            // Exact substring match — no fuzzy scoring
            for (0..self.items.count) |i| {
                const text = self.items.get(i);
                if (exactContains(text, query)) {
                    self.filter.pushExact(@intCast(i));
                }
            }
        } else {
            for (0..self.items.count) |i| {
                self.filter.push(query, self.items.get(i), @intCast(i));
            }
        }
    }

    fn moveUp(self: *PickerState) void {
        if (self.tui) {
            if (self.cursor + 1 < self.filter.count) self.cursor += 1;
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
            if (self.filter.count > 0 and self.cursor + 1 < self.filter.count) self.cursor += 1;
            const vis = self.visibleRows();
            if (self.cursor >= self.scroll + vis) self.scroll = self.cursor - vis + 1;
        }
    }

    fn toggleSelect(self: *PickerState) void {
        if (!self.multi or self.filter.count == 0) return;
        const idx = self.filter.buf[self.cursor].index;
        if (self.selected_map[idx]) {
            self.selected_map[idx] = false;
            self.selected_count -= 1;
        } else {
            self.selected_map[idx] = true;
            self.selected_count += 1;
        }
        self.moveDown();
    }

    // ----- TUI (full-screen) rendering via Screen -----

    fn drawTui(self: *const PickerState, scr: *Screen) void {
        const rows = scr.height;
        const cols = scr.width;
        const vis = self.visibleRows();
        const visible_end = @min(self.scroll + vis, self.filter.count);
        const list_width: u16 = if (self.preview) cols / 2 else cols;

        // Load preview
        var preview_lines: [64][]const u8 = undefined;
        var preview_count: usize = 0;
        var preview_buf: [4096]u8 = undefined;
        if (self.preview and self.filter.count > 0) {
            const cur_idx = self.filter.buf[self.cursor].index;
            preview_count = loadPreview(self.items.get(cur_idx), self.preview_cmd, &preview_buf, &preview_lines);
        }

        if (self.reverse) {
            // Reverse layout: prompt at top, items top-down
            var screen_row: u16 = 1;

            // Prompt (top row)
            self.input.draw(scr, tui.Rect{ .x = 1, .y = screen_row, .w = cols, .h = 1 });
            screen_row += 1;

            // Header
            if (self.header) |hdr| {
                var hdr_iter = std.mem.splitScalar(u8, hdr, '\n');
                while (hdr_iter.next()) |hdr_line| {
                    const hw: u16 = @intCast(@min(hdr_line.len, cols));
                    _ = scr.write(screen_row, 1, hdr_line[0..hw], .{ .dim = true });
                    scr.pad(screen_row, hw + 1, cols -| hw, .{});
                    screen_row += 1;
                }
            }

            // Status bar
            self.drawStatus(scr, screen_row, cols);
            screen_row += 1;

            // Items (top-down)
            for (self.scroll..visible_end) |ri| {
                self.drawItemRow(scr, screen_row, list_width, ri, &preview_lines, preview_count);
                screen_row += 1;
            }


            // Pad remaining rows
            while (screen_row <= rows) {
                scr.pad(screen_row, 1, cols, .{});
                screen_row += 1;
            }
        } else {
            // Default layout: items bottom-up, prompt at bottom
            const rendered = visible_end - self.scroll;
            const header_rows: u16 = if (self.header) |h| @intCast(std.mem.count(u8, h, "\n") + 1) else 0;
            const overhead: u16 = 2 + header_rows;
            const empty: u16 = if (rows > @as(u16, @intCast(rendered)) + overhead) rows - @as(u16, @intCast(rendered)) - overhead else 0;

            var screen_row: u16 = 1;

            // Empty rows at top
            for (0..empty) |row_i| {
                scr.pad(screen_row, 1, list_width, .{});
                if (self.preview) {
                    self.drawPreviewCell(scr, screen_row, list_width, @intCast(row_i), &preview_lines, preview_count);
                }
                screen_row += 1;
            }

            // Items (bottom-up: highest index at top)
            {
                var ri: usize = visible_end;
                while (ri > self.scroll) {
                    ri -= 1;
                    self.drawItemRow(scr, screen_row, list_width, ri, &preview_lines, preview_count);
                    screen_row += 1;
                }
            }

            // Header (above status bar)
            if (self.header) |hdr| {
                var hdr_iter = std.mem.splitScalar(u8, hdr, '\n');
                while (hdr_iter.next()) |hdr_line| {
                    const hw: u16 = @intCast(@min(hdr_line.len, cols));
                    _ = scr.write(screen_row, 1, hdr_line[0..hw], .{ .dim = true });
                    scr.pad(screen_row, hw + 1, cols -| hw, .{});
                    screen_row += 1;
                }
            }

            // Status bar
            self.drawStatus(scr, screen_row, cols);
            screen_row += 1;

            // Prompt (bottom row)
            self.input.draw(scr, tui.Rect{ .x = 1, .y = screen_row, .w = cols, .h = 1 });
        }
    }

    fn drawItemRow(self: *const PickerState, scr: *Screen, screen_row: u16, list_width: u16, ri: usize, preview_lines: *const [64][]const u8, preview_count: usize) void {
        const item_idx = self.filter.buf[ri].index;
        const text = self.items.get(item_idx);
        const is_cursor = (ri == self.cursor);
        const is_selected = self.selected_map[item_idx];

        var col: u16 = 1;
        if (is_cursor) {
            col += scr.write(screen_row, col, ">", .{ .fg = .cyan, .bold = true });
            scr.pad(screen_row, col, 1, .{});
            col += 1;
        } else if (is_selected) {
            col += scr.write(screen_row, col, "*", .{ .fg = .green });
            scr.pad(screen_row, col, 1, .{});
            col += 1;
        } else {
            scr.pad(screen_row, col, 2, .{});
            col += 2;
        }

        const max_text: u16 = list_width -| 4;
        col += self.drawHighlightedItem(scr, screen_row, col, text, max_text, ri, is_cursor);
        scr.pad(screen_row, col, list_width -| (col - 1), .{});

        if (self.preview) {
            self.drawPreviewCell(scr, screen_row, list_width, @intCast(screen_row - 1), preview_lines, preview_count);
        }
    }

    fn drawHighlightedItem(self: *const PickerState, scr: *Screen, row: u16, start_col: u16, text: []const u8, max_w: u16, scored_i: usize, is_cursor: bool) u16 {
        const len = @min(text.len, max_w);
        const result = &self.filter.buf[scored_i];
        const positions = &result.positions;
        const match_count = result.match_count;

        const base_color: ?style.Color = if (is_cursor) .bright_white else fileColorEnum(text);
        const hl_color: style.Color = if (is_cursor) .yellow else .red;
        const base_bold = is_cursor;

        var col = start_col;
        for (0..len) |ci| {
            var is_match = false;
            for (0..match_count) |mi| {
                if (positions[mi] == ci) { is_match = true; break; }
            }
            const s: Screen.Style = if (is_match)
                .{ .fg = hl_color, .bold = true }
            else
                .{ .fg = base_color, .bold = base_bold };
            scr.putChar(row, col, text[ci], s);
            col += 1;
        }
        return col - start_col;
    }

    fn drawPreviewCell(self: *const PickerState, scr: *Screen, row: u16, list_width: u16, content_row: u16, preview_lines: *const [64][]const u8, preview_count: usize) void {
        _ = self;
        const sep_col = list_width + 1;
        _ = scr.write(row, sep_col, style.box.vertical, .{ .dim = true });
        scr.pad(row, sep_col + 1, 1, .{});
        const preview_col = sep_col + 2;
        const preview_w = scr.width -| preview_col + 1;
        if (content_row < preview_count) {
            const line = preview_lines[content_row];
            const tw: u16 = @intCast(@min(line.len, preview_w));
            _ = scr.write(row, preview_col, line[0..tw], .{ .dim = true });
            scr.pad(row, preview_col + tw, preview_w -| tw, .{});
        } else {
            scr.pad(row, preview_col, preview_w, .{});
        }
    }

    fn drawStatus(self: *const PickerState, scr: *Screen, row: u16, cols: u16) void {
        var col: u16 = 1;
        var cnt_buf: [32]u8 = undefined;
        const cnt_str = std.fmt.bufPrint(&cnt_buf, "  {d}/{d}", .{ self.filter.count, self.items.count }) catch "";
        col += scr.write(row, col, cnt_str, .{ .dim = true });
        if (self.multi) {
            var sel_buf: [16]u8 = undefined;
            const sel_str = std.fmt.bufPrint(&sel_buf, " ({d})", .{self.selected_count}) catch "";
            col += scr.write(row, col, sel_str, .{ .dim = true });
        }
        scr.pad(row, col, 1, .{ .dim = true });
        col += 1;
        scr.hline(row, col, cols -| col + 1, .{ .dim = true });
    }

    // ----- Inline rendering (raw ANSI, unchanged) -----

    fn renderInline(self: *PickerState, tty: std.fs.File) void {
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;

        pos += cp(buf[pos..], "\x1b[?25l\x1b[s");

        // Prompt
        pos += cp(buf[pos..], "\r\x1b[K\x1b[1;36m> \x1b[0m");
        const filter = self.input.value();
        @memcpy(buf[pos..][0..filter.len], filter);
        pos += filter.len;
        pos += cp(buf[pos..], "\x1b[2m");
        const cnt = std.fmt.bufPrint(buf[pos..], "  {d}/{d}", .{ self.filter.count, self.items.count }) catch "";
        pos += cnt.len;
        pos += cp(buf[pos..], "\x1b[0m");

        const vis = self.visibleRows();
        const visible_end = @min(self.scroll + vis, self.filter.count);

        for (self.scroll..visible_end) |i| {
            pos += cp(buf[pos..], "\r\n\x1b[K");
            const idx = self.filter.buf[i].index;
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
                &self.filter.buf[i].positions,
                self.filter.buf[i].match_count,
                base, hl,
            );

            if (is_cursor) pos += cp(buf[pos..], " \x1b[0m");
        }

        var vi = visible_end - self.scroll;
        while (vi < self.rendered_lines) : (vi += 1) {
            pos += cp(buf[pos..], "\r\n\x1b[K");
        }
        self.rendered_lines = visible_end - self.scroll;

        pos += cp(buf[pos..], "\x1b[u\x1b[?25h");
        const cursor_col = 2 + self.input.value().len;
        const cseq = std.fmt.bufPrint(buf[pos..], "\r\x1b[{d}C", .{cursor_col}) catch "";
        pos += cseq.len;

        tty.writeAll(buf[0..pos]) catch {};
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



