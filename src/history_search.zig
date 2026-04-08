// history_search.zig — Full-screen history search (Ctrl+R).
//
// Alternate-screen TUI matching the history explorer design language.
// Fuzzy search, deduped entries, duration + relative time display.
// Uses Screen for flicker-free double-buffered rendering.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const fuzzy = @import("fuzzy.zig");
const history_db_mod = @import("history_db.zig");
const prompt_mod = @import("prompt.zig");
const style = @import("style.zig");
const tui = @import("tui.zig");
const keys = @import("keys.zig");

const Screen = tui.Screen;
const Key = keys.Key;
const MAX_ENTRIES: usize = 200;

const Entry = struct {
    id: i64,
    raw: [256]u8,
    raw_len: usize,
    exit_code: i64,
    duration_ms: i64,
    started_at: i64,

    fn rawSlice(self: *const Entry) []const u8 {
        return self.raw[0..self.raw_len];
    }
};

pub const SearchResult = union(enum) {
    selected: []const u8,
    cancelled,
};

pub fn run(
    hdb: ?*history_db_mod.HistoryDb,
    stdout: std.fs.File,
) SearchResult {
    _ = stdout;
    const db = hdb orelse return .cancelled;

    var entries: [MAX_ENTRIES]Entry = undefined;
    const total = loadEntries(db, &entries);
    if (total == 0) return .cancelled;

    // Open tty for interactive I/O
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
    };
    state.input.prompt = "> ";
    state.input.prompt_color = .yellow;
    state.input.focused = true;
    state.input.placeholder = "search...";
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
                // Select current entry
                if (alt_active) {
                    var xbuf: [64]u8 = undefined;
                    var xp: usize = 0;
                    xp += style.showCursor(xbuf[xp..]);
                    xp += style.altScreenOff(xbuf[xp..]);
                    tty.writeAll(xbuf[0..xp]) catch {};
                    alt_active = false;
                }
                if (state.scored_count > 0) {
                    const idx = state.scored_idx[state.selected];
                    return .{ .selected = entries[idx].rawSlice() };
                }
                return .cancelled;
            },
            .escape, .ctrl_c, .ctrl_r => break,
            .up, .ctrl_p => {
                if (state.selected > 0) state.selected -= 1;
                state.clampScroll(&screen);
            },
            .down, .ctrl_n => {
                if (state.scored_count > 0 and state.selected + 1 < state.scored_count)
                    state.selected += 1;
                state.clampScroll(&screen);
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
    input: tui.Input = .{},
    scored_idx: [MAX_ENTRIES]usize = undefined,
    scored_vals: [MAX_ENTRIES]i32 = undefined,
    scored_count: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,

    fn rescore(self: *State) void {
        const filter = self.input.value();
        self.scored_count = 0;
        for (0..self.total) |i| {
            const text = self.entries[i].rawSlice();
            if (filter.len == 0) {
                self.scored_idx[self.scored_count] = i;
                self.scored_vals[self.scored_count] = 0;
                self.scored_count += 1;
            } else {
                const s = fuzzy.score(text, filter);
                if (s.matched) {
                    var pos = self.scored_count;
                    while (pos > 0 and self.scored_vals[pos - 1] < s.value) {
                        self.scored_idx[pos] = self.scored_idx[pos - 1];
                        self.scored_vals[pos] = self.scored_vals[pos - 1];
                        pos -= 1;
                    }
                    self.scored_idx[pos] = i;
                    self.scored_vals[pos] = s.value;
                    self.scored_count += 1;
                }
            }
        }
        self.selected = 0;
        self.scroll = 0;
    }

    fn listHeight(self: *const State, scr: *const Screen) u16 {
        _ = self;
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
            tui.Size{ .fixed = 1 }, // filter
            tui.Size{ .flex = 1 },  // list (separator + entries)
            tui.Size{ .fixed = 1 }, // status
        }, &layout);

        self.drawTitle(scr, layout[0]);
        self.input.draw(scr, layout[1]);
        self.drawList(scr, layout[2]);
        self.drawStatusBar(scr, layout[3]);
    }

    fn drawTitle(self: *const State, scr: *Screen, rect: tui.Rect) void {
        const title = "  History Search";
        const dim_s: Screen.Style = .{ .dim = true };
        var col = rect.x;
        col += scr.write(rect.y, col, title, dim_s);

        var cnt_buf: [32]u8 = undefined;
        const cnt_str = std.fmt.bufPrint(&cnt_buf, "{d} matches  ", .{self.scored_count}) catch "";
        const cnt_w: u16 = @intCast(cnt_str.len);
        if (col + cnt_w < rect.x + rect.w) {
            scr.pad(rect.y, col, rect.x + rect.w - col - cnt_w, dim_s);
            _ = scr.write(rect.y, rect.x + rect.w - cnt_w, cnt_str, dim_s);
        } else {
            scr.pad(rect.y, col, rect.x + rect.w -| col, dim_s);
        }
    }

    fn drawList(self: *const State, scr: *Screen, rect: tui.Rect) void {
        if (rect.h == 0 or rect.w == 0) return;

        // Separator (first row)
        scr.hline(rect.y, rect.x, rect.w, .{ .dim = true });

        if (rect.h <= 1) return;
        const list_rect = tui.Rect{
            .x = rect.x,
            .y = rect.y + 1,
            .w = rect.w,
            .h = rect.h - 1,
        };

        const max_vis = list_rect.h;
        const vis_end = @min(self.scroll + max_vis, self.scored_count);
        const has_scrollbar = self.scored_count > max_vis and max_vis > 2;
        const content_w: u16 = if (has_scrollbar) list_rect.w -| 1 else list_rect.w;

        if (self.scored_count == 0) {
            scr.fill(list_rect, .{});
            const msg = if (self.input.value().len > 0) "No matches" else "No history";
            const msg_w: u16 = @intCast(msg.len);
            const mid = list_rect.h / 2;
            _ = scr.write(list_rect.y + mid, list_rect.x + (list_rect.w -| msg_w) / 2, msg, .{ .dim = true });
        } else {
            var row: u16 = 0;
            for (self.scroll..vis_end) |vi| {
                const idx = self.scored_idx[vi];
                const e = &self.entries[idx];
                const is_sel = vi == self.selected;
                self.drawEntry(scr, list_rect.y + row, list_rect.x, content_w, e, is_sel);
                row += 1;
            }
            // Clear remaining rows
            while (row < max_vis) : (row += 1) {
                scr.pad(list_rect.y + row, list_rect.x, content_w, .{});
            }
        }

        // Scrollbar
        if (has_scrollbar) {
            const col = list_rect.x + list_rect.w - 1;
            const thumb_h = @max(1, (@as(u32, max_vis) * max_vis) / @as(u32, @intCast(self.scored_count)));
            const max_off = self.scored_count - max_vis;
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

    fn drawEntry(self: *const State, scr: *Screen, row: u16, x: u16, w: u16, e: *const Entry, is_sel: bool) void {
        _ = self;
        var col = x;

        // Arrow
        if (is_sel) {
            col += scr.write(row, col, " > ", .{ .fg = .cyan });
        } else {
            scr.pad(row, col, 3, .{});
            col += 3;
        }

        // Status icon
        if (e.exit_code == 0) {
            col += scr.write(row, col, style.box.bullet, .{ .fg = .green });
        } else {
            col += scr.write(row, col, style.box.cross, .{ .fg = .red });
        }
        scr.pad(row, col, 1, .{});
        col += 1;

        // Command text
        const cmd = e.rawSlice();
        const right_w: u16 = 20;
        const max_cmd: u16 = if (w > right_w + 6) w - right_w - 6 else 20;
        const disp_len: u16 = @intCast(@min(cmd.len, max_cmd));
        const name_style: Screen.Style = if (is_sel) .{ .bold = true } else .{};
        col += scr.write(row, col, cmd[0..disp_len], name_style);
        if (cmd.len > max_cmd) col += scr.write(row, col, style.box.ellipsis, .{});

        // Right-align: duration + time
        const age = relativeTime(e.started_at);
        var right_parts_w: u16 = @intCast(age.len);
        var dur_str: []const u8 = "";
        if (e.duration_ms >= 100) {
            var dur_buf: [16]u8 = undefined;
            dur_str = prompt_mod.formatDuration(&dur_buf, e.duration_ms);
            right_parts_w += @as(u16, @intCast(dur_str.len)) + 2;
        }

        const end = x + w;
        if (col + right_parts_w < end) {
            scr.pad(row, col, end - col - right_parts_w, .{});
            col = end - right_parts_w;
        }

        if (dur_str.len > 0) {
            col += scr.write(row, col, dur_str, .{ .fg = .yellow });
            scr.pad(row, col, 2, .{});
            col += 2;
        }
        _ = scr.write(row, col, age, .{ .dim = true });
    }

    fn drawStatusBar(_: *const State, scr: *Screen, rect: tui.Rect) void {
        const bar = tui.StatusBar{
            .items = &.{
                .{ .key = "Enter", .label = "select" },
                .{ .key = "Esc", .label = "cancel" },
                .{ .key = "^W", .label = "del word" },
            },
            .transparent = true,
        };
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
