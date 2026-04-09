// history_search.zig — Unified full-screen history browser.
//
// Used by both Ctrl+R (insert mode) and `history explore` (replay mode).
// Fuzzy search, filter pills (^F failed, ^D cwd), detail toggle (Tab),
// deduped entries, duration + relative time display.
// Uses Screen for flicker-free double-buffered rendering.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const history_db_mod = @import("history_db.zig");
const prompt_mod = @import("prompt.zig");
const style = @import("style.zig");
const tui = @import("tui.zig");
const keys = @import("keys.zig");

const Screen = tui.Screen;
const Key = keys.Key;
const MAX_ENTRIES: usize = 500;

const Entry = struct {
    id: i64,
    raw: [256]u8,
    raw_len: usize,
    exit_code: i64,
    duration_ms: i64,
    started_at: i64,
    cwd: [256]u8 = undefined,
    cwd_len: usize = 0,

    fn rawSlice(self: *const Entry) []const u8 {
        return self.raw[0..self.raw_len];
    }

    fn cwdSlice(self: *const Entry) []const u8 {
        return self.cwd[0..self.cwd_len];
    }
};

pub const Mode = enum { insert, replay };

pub const SearchResult = union(enum) {
    selected: []const u8,
    cancelled,
};

/// Config — set via xyron.config.history({ local = true })
pub var default_local: bool = false;

/// Replay state — used by `history explore` mode to pass command back to shell.
pub var replay_command: [512]u8 = undefined;
pub var replay_len: usize = 0;
pub var replay_pending: bool = false;

pub fn run(
    hdb: ?*history_db_mod.HistoryDb,
    stdout: std.fs.File,
    mode: Mode,
) SearchResult {
    _ = stdout;
    const db = hdb orelse return .cancelled;

    var entries: [MAX_ENTRIES]Entry = undefined;
    const total = loadEntries(db, &entries);
    if (total == 0) return .cancelled;

    // Open tty
    const tty_fd = posix.openZ("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return .cancelled;
    defer posix.close(tty_fd);
    const tty = std.fs.File{ .handle = tty_fd };

    // Raw mode
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

    // Alternate screen
    {
        var ebuf: [64]u8 = undefined;
        var ep: usize = 0;
        ep += style.altScreenOn(ebuf[ep..]);
        ep += style.showCursor(ebuf[ep..]);
        tty.writeAll(ebuf[0..ep]) catch {};
    }
    var alt_active = true;
    defer if (alt_active) {
        var xbuf: [64]u8 = undefined;
        var xp: usize = 0;
        xp += style.showCursor(xbuf[xp..]);
        xp += style.altScreenOff(xbuf[xp..]);
        tty.writeAll(xbuf[0..xp]) catch {};
    };

    // State
    var state = State{
        .entries = &entries,
        .total = total,
        .mode = mode,
        .show_cwd_only = default_local,
    };
    state.input.prompt = "> ";
    state.input.prompt_color = .yellow;
    state.input.focused = true;
    state.input.placeholder = "search...";
    state.current_cwd = posix.getcwd(&state.cwd_buf) catch ".";
    state.rescore();

    var ts = getTermSize(tty_fd);
    var screen = Screen.init(
        @intCast(@min(ts.cols, Screen.max_cols)),
        @intCast(@min(ts.rows, Screen.max_rows)),
    );

    state.draw(&screen);
    screen.flush(tty);

    // Event loop
    while (true) {
        const key = keys.readKeyFromFd(tty_fd) orelse break;

        if (key == .resize) {
            ts = getTermSize(tty_fd);
            screen.resize(
                @intCast(@min(ts.cols, Screen.max_cols)),
                @intCast(@min(ts.rows, Screen.max_rows)),
            );
            state.draw(&screen);
            screen.flush(tty);
            continue;
        }

        switch (key) {
            .enter, .right => {
                if (state.filter.count > 0) {
                    const idx = state.filter.buf[state.selected].index;
                    const cmd = entries[idx].rawSlice();
                    if (mode == .replay) {
                        const n = @min(cmd.len, replay_command.len);
                        @memcpy(replay_command[0..n], cmd[0..n]);
                        replay_len = n;
                        replay_pending = true;
                    }
                    // Exit alt screen before returning
                    if (alt_active) {
                        var xbuf: [64]u8 = undefined;
                        var xp: usize = 0;
                        xp += style.showCursor(xbuf[xp..]);
                        xp += style.altScreenOff(xbuf[xp..]);
                        tty.writeAll(xbuf[0..xp]) catch {};
                        alt_active = false;
                    }
                    return .{ .selected = cmd };
                }
                return .cancelled;
            },
            .escape, .ctrl_r => break,
            .ctrl_c => {
                if (state.input.value().len > 0) {
                    state.input.clear();
                    state.rescore();
                } else break;
            },
            .up, .ctrl_p => {
                if (state.selected > 0) state.selected -= 1;
                state.clampScroll(&screen);
            },
            .down, .ctrl_n => {
                if (state.filter.count > 0 and state.selected + 1 < state.filter.count)
                    state.selected += 1;
                state.clampScroll(&screen);
            },
            .tab => state.show_detail = !state.show_detail,
            .ctrl_f => {
                state.show_failed_only = !state.show_failed_only;
                state.rescore();
            },
            .ctrl_d => {
                state.show_cwd_only = !state.show_cwd_only;
                state.rescore();
            },
            else => {
                const action = state.input.handleKey(key);
                if (action == .changed) state.rescore();
            },
        }

        screen.beginFrame();
        state.draw(&screen);
        screen.flush(tty);
    }

    return .cancelled;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const State = struct {
    entries: *const [MAX_ENTRIES]Entry,
    total: usize,
    mode: Mode,
    input: tui.Input = .{},
    filter: tui.FuzzyFilter(MAX_ENTRIES) = tui.FuzzyFilter(MAX_ENTRIES).init(),
    selected: usize = 0,
    scroll: usize = 0,
    show_failed_only: bool = false,
    show_cwd_only: bool = false,
    show_detail: bool = false,
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    current_cwd: []const u8 = ".",

    fn rescore(self: *State) void {
        const query = self.input.value();
        self.filter.reset();
        for (0..self.total) |i| {
            const e = &self.entries[i];
            if (self.show_failed_only and e.exit_code == 0) continue;
            if (self.show_cwd_only and !std.mem.eql(u8, e.cwdSlice(), self.current_cwd)) continue;
            self.filter.push(query, e.rawSlice(), @intCast(i));
        }
        self.selected = 0;
        self.scroll = 0;
    }

    fn listHeight(_: *const State, scr: *const Screen) u16 {
        // title + filter + separator = 3, status = 1
        return if (scr.height > 4) scr.height - 4 else 1;
    }

    fn clampScroll(self: *State, scr: *const Screen) void {
        const vis = self.listHeight(scr);
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + vis) self.scroll = self.selected - vis + 1;
    }

    // -------------------------------------------------------------------
    // Drawing
    // -------------------------------------------------------------------

    fn draw(self: *const State, scr: *Screen) void {
        const scr_rect = tui.Rect.fromSize(scr.width, scr.height);
        var layout: [4]tui.Rect = undefined;
        _ = scr_rect.splitRows(&.{
            tui.Size{ .fixed = 1 }, // title
            tui.Size{ .fixed = 1 }, // filter + pills
            tui.Size{ .flex = 1 },  // separator + list
            tui.Size{ .fixed = 1 }, // status
        }, &layout);

        self.drawTitle(scr, layout[0]);
        self.drawFilter(scr, layout[1]);
        self.drawList(scr, layout[2]);
        self.drawStatusBar(scr, layout[3]);
    }

    fn drawTitle(self: *const State, scr: *Screen, rect: tui.Rect) void {
        const title = if (self.mode == .insert) "  History Search" else "  History Explorer";
        const dim_s: Screen.Style = .{ .dim = true };
        var col = rect.x;
        col += scr.write(rect.y, col, title, dim_s);

        var cnt_buf: [32]u8 = undefined;
        const cnt_str = std.fmt.bufPrint(&cnt_buf, "{d} commands  ", .{self.filter.count}) catch "";
        const cnt_w: u16 = @intCast(cnt_str.len);
        if (col + cnt_w < rect.x + rect.w) {
            scr.pad(rect.y, col, rect.x + rect.w - col - cnt_w, dim_s);
            _ = scr.write(rect.y, rect.x + rect.w - cnt_w, cnt_str, dim_s);
        } else {
            scr.pad(rect.y, col, rect.x + rect.w -| col, dim_s);
        }
    }

    fn drawFilter(self: *const State, scr: *Screen, rect: tui.Rect) void {
        var col = rect.x;

        // Filter pills first (left side)
        if (self.show_failed_only) {
            col += scr.write(rect.y, col, " ", .{ .fg = .red, .inverse = true });
            col += scr.write(rect.y, col, style.box.cross, .{ .fg = .red, .inverse = true });
            col += scr.write(rect.y, col, " failed ", .{ .fg = .red, .inverse = true });
            scr.pad(rect.y, col, 1, .{});
            col += 1;
        }
        if (self.show_cwd_only) {
            col += scr.write(rect.y, col, " cwd ", .{ .fg = .blue, .inverse = true });
            scr.pad(rect.y, col, 1, .{});
            col += 1;
        }

        // Input takes remaining space
        const input_w = rect.x + rect.w -| col;
        self.input.draw(scr, tui.Rect{ .x = col, .y = rect.y, .w = input_w, .h = 1 });
    }

    fn drawList(self: *const State, scr: *Screen, rect: tui.Rect) void {
        if (rect.h == 0 or rect.w == 0) return;

        // Separator
        scr.hline(rect.y, rect.x, rect.w, .{ .dim = true });

        if (rect.h <= 1) return;
        const list_rect = tui.Rect{ .x = rect.x, .y = rect.y + 1, .w = rect.w, .h = rect.h - 1 };
        const max_vis = list_rect.h;
        const vis_end = @min(self.scroll + max_vis, self.filter.count);
        const has_scrollbar = self.filter.count > max_vis and max_vis > 2;
        const content_w: u16 = if (has_scrollbar) list_rect.w -| 1 else list_rect.w;

        if (self.filter.count == 0) {
            scr.fill(list_rect, .{});
            const msg = if (self.input.value().len > 0) "No matches" else "No history";
            const msg_w: u16 = @intCast(msg.len);
            const mid = list_rect.h / 2;
            _ = scr.write(list_rect.y + mid, list_rect.x + (list_rect.w -| msg_w) / 2, msg, .{ .dim = true });
        } else {
            var row: u16 = 0;
            for (self.scroll..vis_end) |vi| {
                const idx = self.filter.buf[vi].index;
                const e = &self.entries[idx];
                const is_sel = vi == self.selected;
                self.drawEntry(scr, list_rect.y + row, list_rect.x, content_w, e, is_sel);
                row += 1;

                // Detail row
                if (is_sel and self.show_detail and e.cwd_len > 0 and row < max_vis) {
                    scr.pad(list_rect.y + row, list_rect.x, 5, .{});
                    const cwd_max: u16 = if (content_w > 10) content_w - 10 else content_w;
                    const cwd_s = e.cwdSlice();
                    const dcol = list_rect.x + 5;
                    const dw = scr.write(list_rect.y + row, dcol, cwd_s[0..@min(cwd_s.len, cwd_max)], .{ .dim = true, .fg = .cyan });
                    scr.pad(list_rect.y + row, dcol + dw, content_w -| (5 + dw), .{});
                    row += 1;
                }
            }
            while (row < max_vis) : (row += 1) {
                scr.pad(list_rect.y + row, list_rect.x, content_w, .{});
            }
        }

        // Scrollbar
        if (has_scrollbar) {
            const col = list_rect.x + list_rect.w - 1;
            const thumb_h = @max(1, (@as(u32, max_vis) * max_vis) / @as(u32, @intCast(self.filter.count)));
            const max_off = self.filter.count - max_vis;
            const track_space = max_vis - @as(u16, @intCast(thumb_h));
            const thumb_top: u16 = if (max_off > 0)
                @intCast((@as(u32, @intCast(self.scroll)) * track_space) / @as(u32, @intCast(max_off)))
            else
                0;
            var sr: u16 = 0;
            while (sr < max_vis) : (sr += 1) {
                const ch = if (sr >= thumb_top and sr < thumb_top + @as(u16, @intCast(thumb_h)))
                    style.box.scrollbar_thumb
                else
                    style.box.scrollbar_track;
                _ = scr.write(list_rect.y + sr, col, ch, .{ .dim = true });
            }
        }
    }

    // Column widths for aligned layout
    const col_arrow: u16 = 3; // " > " or "   "
    const col_icon: u16 = 2; // "● " or "✗ "
    const col_age: u16 = 9; // "just now " or "999w ago "
    const col_dur: u16 = 8; // "  1.23s " or "        "

    fn drawEntry(_: *const State, scr: *Screen, row: u16, x: u16, w: u16, e: *const Entry, is_sel: bool) void {
        var col = x;
        const end = x + w;

        // Arrow (3 cols)
        if (is_sel) {
            col += scr.write(row, col, " > ", .{ .fg = .cyan });
        } else {
            scr.pad(row, col, col_arrow, .{});
            col += col_arrow;
        }

        // Status icon (2 cols)
        if (e.exit_code == 0) {
            col += scr.write(row, col, style.box.bullet, .{ .fg = .green });
        } else {
            col += scr.write(row, col, style.box.cross, .{ .fg = .red });
        }
        scr.pad(row, col, 1, .{});
        col += 1;

        // Relative time (9 cols, left-aligned, padded)
        const age = relativeTime(e.started_at);
        const age_w = scr.write(row, col, age, .{ .dim = true });
        scr.pad(row, col + age_w, col_age -| age_w, .{});
        col += col_age;

        // Duration (8 cols, right-aligned within column)
        if (e.duration_ms >= 100) {
            var dur_buf: [16]u8 = undefined;
            const dur_str = prompt_mod.formatDuration(&dur_buf, e.duration_ms);
            const dur_w: u16 = @intCast(dur_str.len);
            const dur_pad = col_dur -| dur_w -| 1;
            scr.pad(row, col, dur_pad, .{});
            _ = scr.write(row, col + dur_pad, dur_str, .{ .fg = .yellow });
            scr.pad(row, col + dur_pad + dur_w, col_dur -| dur_pad -| dur_w, .{});
        } else {
            scr.pad(row, col, col_dur, .{});
        }
        col += col_dur;

        // Right side: cwd (right-aligned, dim)
        const cwd = e.cwdSlice();
        const cwd_w: u16 = @intCast(@min(cwd.len, w / 3)); // max 1/3 of width
        const cmd_area = end -| col -| (if (cwd_w > 0) cwd_w + 2 else 0);

        // Command text (flex)
        const cmd = e.rawSlice();
        const disp_len: u16 = @intCast(@min(cmd.len, cmd_area));
        const name_style: Screen.Style = if (is_sel) .{ .bold = true } else .{};
        col += scr.write(row, col, cmd[0..disp_len], name_style);
        if (cmd.len > cmd_area) col += scr.write(row, col, style.box.ellipsis, .{});

        // Pad gap + cwd (right-aligned)
        if (cwd_w > 0) {
            const cwd_col = end - cwd_w;
            scr.pad(row, col, cwd_col -| col, .{});
            _ = scr.write(row, cwd_col, cwd[0..cwd_w], .{ .dim = true });
        } else {
            scr.pad(row, col, end -| col, .{});
        }
    }

    fn drawStatusBar(self: *const State, scr: *Screen, rect: tui.Rect) void {
        const select_label = if (self.mode == .replay) "rerun" else "select";
        const items = [_]tui.StatusBar.Item{
            .{ .key = "Enter", .label = select_label },
            .{ .key = "Esc", .label = "cancel" },
            .{ .key = "Tab", .label = "detail" },
            .{ .key = "^F", .label = if (self.show_failed_only) "all" else "failed" },
            .{ .key = "^D", .label = if (self.show_cwd_only) "all dirs" else "this dir" },
        };
        const bar = tui.StatusBar{ .items = &items, .transparent = true };
        bar.draw(scr, rect);
    }
};

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

fn loadEntries(db: *history_db_mod.HistoryDb, entries: *[MAX_ENTRIES]Entry) usize {
    var raw_entries: [MAX_ENTRIES]history_db_mod.HistoryEntry = undefined;
    var str_buf: [MAX_ENTRIES * 256]u8 = undefined;
    const count = db.recentEntries(&raw_entries, &str_buf);

    var deduped: usize = 0;
    for (0..count) |i| {
        const e = &raw_entries[i];
        const rl = @min(e.raw_input.len, 256);
        var dupe = false;
        for (0..deduped) |j| {
            if (entries[j].raw_len == rl and std.mem.eql(u8, entries[j].raw[0..rl], e.raw_input[0..rl])) {
                dupe = true;
                break;
            }
        }
        if (dupe) continue;
        entries[deduped].id = e.id;
        @memcpy(entries[deduped].raw[0..rl], e.raw_input[0..rl]);
        entries[deduped].raw_len = rl;
        entries[deduped].exit_code = e.exit_code;
        entries[deduped].duration_ms = e.duration_ms;
        entries[deduped].started_at = e.started_at;
        // Copy cwd
        const cl = @min(e.cwd.len, 256);
        @memcpy(entries[deduped].cwd[0..cl], e.cwd[0..cl]);
        entries[deduped].cwd_len = cl;
        deduped += 1;
    }
    return deduped;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

var relative_buf: [32]u8 = undefined;

fn relativeTime(started_ms: i64) []const u8 {
    const now_ms = std.time.milliTimestamp();
    const age_s = @divTrunc(now_ms - started_ms, 1000);
    if (age_s < 0) return "just now";
    if (age_s < 60) return "just now";
    if (age_s < 3600) return std.fmt.bufPrint(&relative_buf, "{d}m ago", .{@divTrunc(age_s, 60)}) catch "?";
    if (age_s < 86400) return std.fmt.bufPrint(&relative_buf, "{d}h ago", .{@divTrunc(age_s, 3600)}) catch "?";
    if (age_s < 604800) return std.fmt.bufPrint(&relative_buf, "{d}d ago", .{@divTrunc(age_s, 86400)}) catch "?";
    return std.fmt.bufPrint(&relative_buf, "{d}w ago", .{@divTrunc(age_s, 604800)}) catch "?";
}

const TermSize = struct { rows: usize, cols: usize };

fn getTermSize(fd: posix.fd_t) TermSize {
    const ts = style.getTermSize(fd);
    return .{ .rows = ts.rows, .cols = ts.cols };
}
