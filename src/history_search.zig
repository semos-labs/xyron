// history_search.zig — Full-screen history search (Ctrl+R).
//
// Atuin-style interactive search: shows recent history entries with
// duration and relative timestamps, supports fuzzy filtering,
// navigating with arrows, and inserting the selected command.

const std = @import("std");
const posix = std.posix;
const keys = @import("keys.zig");
const fuzzy = @import("fuzzy.zig");
const history_db_mod = @import("history_db.zig");
const types = @import("types.zig");

const MAX_ENTRIES: usize = 200;
const MAX_VISIBLE: usize = 20;

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

/// Run the interactive history search. Returns the selected command or cancelled.
pub fn run(
    hdb: ?*history_db_mod.HistoryDb,
    stdout: std.fs.File,
) SearchResult {
    const db = hdb orelse return .cancelled;

    // Load entries from DB
    var entries: [MAX_ENTRIES]Entry = undefined;
    const total = loadEntries(db, &entries);
    if (total == 0) return .cancelled;

    // Filter/score state
    var filter: [128]u8 = undefined;
    var filter_len: usize = 0;
    var scored_idx: [MAX_ENTRIES]usize = undefined;
    var scored_vals: [MAX_ENTRIES]i32 = undefined;
    var scored_count: usize = 0;
    var selected: usize = 0;
    var scroll: usize = 0;

    // Initial: all entries, newest first
    scoreEntries(&entries, total, filter[0..0], &scored_idx, &scored_vals, &scored_count);

    const term_h = getTermHeight();
    const max_vis = @min(MAX_VISIBLE, if (term_h > 4) term_h - 3 else 5);

    renderSearch(stdout, &entries, &scored_idx, scored_count, selected, scroll, max_vis, filter[0..filter_len]);

    while (true) {
        const key = keys.readKey() catch break;

        switch (key) {
            .enter => {
                clearArea(stdout, max_vis + 2);
                if (scored_count > 0) {
                    const idx = scored_idx[selected];
                    return .{ .selected = entries[idx].rawSlice() };
                }
                return .cancelled;
            },
            .escape, .ctrl_c, .ctrl_r => {
                clearArea(stdout, max_vis + 2);
                return .cancelled;
            },
            .up => {
                if (selected > 0) selected -= 1;
                if (selected < scroll) scroll = selected;
            },
            .down => {
                if (scored_count > 0 and selected + 1 < scored_count) selected += 1;
                if (selected >= scroll + max_vis) scroll = selected - max_vis + 1;
            },
            .tab => {
                if (scored_count > 0) {
                    selected = if (selected + 1 >= scored_count) 0 else selected + 1;
                    if (selected >= scroll + max_vis) scroll = selected - max_vis + 1;
                    if (selected < scroll) scroll = selected;
                }
            },
            .backspace => {
                if (filter_len > 0) {
                    filter_len -= 1;
                    rescore(&entries, total, filter[0..filter_len], &scored_idx, &scored_vals, &scored_count, &selected, &scroll);
                }
            },
            .char => |ch| {
                if (ch >= 32 and filter_len < 128) {
                    filter[filter_len] = ch;
                    filter_len += 1;
                    rescore(&entries, total, filter[0..filter_len], &scored_idx, &scored_vals, &scored_count, &selected, &scroll);
                }
            },
            else => {},
        }

        renderSearch(stdout, &entries, &scored_idx, scored_count, selected, scroll, max_vis, filter[0..filter_len]);
    }

    clearArea(stdout, max_vis + 2);
    return .cancelled;
}

// ---------------------------------------------------------------------------
// Loading and scoring
// ---------------------------------------------------------------------------

fn loadEntries(db: *history_db_mod.HistoryDb, entries: *[MAX_ENTRIES]Entry) usize {
    var raw_entries: [MAX_ENTRIES]history_db_mod.HistoryEntry = undefined;
    var str_buf: [MAX_ENTRIES * 256]u8 = undefined;
    const count = db.recentEntries(&raw_entries, &str_buf);

    for (0..count) |i| {
        const e = &raw_entries[i];
        entries[i].id = e.id;
        const rl = @min(e.raw_input.len, 256);
        @memcpy(entries[i].raw[0..rl], e.raw_input[0..rl]);
        entries[i].raw_len = rl;
        entries[i].exit_code = e.exit_code;
        entries[i].duration_ms = e.duration_ms;
        entries[i].started_at = e.started_at;
    }
    return count;
}

fn scoreEntries(
    entries: *const [MAX_ENTRIES]Entry,
    total: usize,
    filter: []const u8,
    idx: *[MAX_ENTRIES]usize,
    vals: *[MAX_ENTRIES]i32,
    count: *usize,
) void {
    count.* = 0;
    for (0..total) |i| {
        const text = entries[i].rawSlice();
        if (filter.len == 0) {
            idx[count.*] = i;
            vals[count.*] = 0;
            count.* += 1;
        } else {
            const s = fuzzy.score(text, filter);
            if (s.matched) {
                var pos = count.*;
                while (pos > 0 and vals[pos - 1] < s.value) {
                    idx[pos] = idx[pos - 1];
                    vals[pos] = vals[pos - 1];
                    pos -= 1;
                }
                idx[pos] = i;
                vals[pos] = s.value;
                count.* += 1;
            }
        }
    }
}

fn rescore(
    entries: *const [MAX_ENTRIES]Entry,
    total: usize,
    filter: []const u8,
    idx: *[MAX_ENTRIES]usize,
    vals: *[MAX_ENTRIES]i32,
    count: *usize,
    selected: *usize,
    scroll: *usize,
) void {
    scoreEntries(entries, total, filter, idx, vals, count);
    if (selected.* >= count.*) selected.* = if (count.* > 0) count.* - 1 else 0;
    if (scroll.* > selected.*) scroll.* = selected.*;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn renderSearch(
    stdout: std.fs.File,
    entries: *const [MAX_ENTRIES]Entry,
    scored_idx: *const [MAX_ENTRIES]usize,
    count: usize,
    selected: usize,
    scroll: usize,
    max_vis: usize,
    filter: []const u8,
) void {
    var buf: [16384]u8 = undefined;
    var pos: usize = 0;

    // Search prompt line
    pos += cp(buf[pos..], "\r\x1b[J"); // clear from cursor down
    pos += cp(buf[pos..], "\x1b[1;36m  history\x1b[0m \x1b[2m[\x1b[0m");
    if (filter.len > 0) {
        pos += cp(buf[pos..], filter);
    }
    pos += cp(buf[pos..], "\x1b[2m]\x1b[0m\r\n");

    const now = types.timestampMs();
    const visible_end = @min(scroll + max_vis, count);

    for (scroll..visible_end) |i| {
        const idx = scored_idx[i];
        const e = &entries[idx];
        const is_sel = (i == selected);

        pos += cp(buf[pos..], "\x1b[K"); // clear line

        // Selection indicator
        if (is_sel) {
            pos += cp(buf[pos..], "\x1b[48;5;236m\x1b[1;32m > \x1b[0m\x1b[48;5;236m");
        } else {
            pos += cp(buf[pos..], "   ");
        }

        // Duration
        var dur_buf: [12]u8 = undefined;
        const dur_str = formatDuration(&dur_buf, e.duration_ms);
        if (is_sel) pos += cp(buf[pos..], "\x1b[48;5;236m");
        pos += cp(buf[pos..], "\x1b[33m");
        // Right-align duration in 6 chars
        const dur_pad = if (6 > dur_str.len) 6 - dur_str.len else 0;
        for (0..dur_pad) |_| { if (pos < buf.len) { buf[pos] = ' '; pos += 1; } }
        pos += cp(buf[pos..], dur_str);
        pos += cp(buf[pos..], "\x1b[0m");

        // Time ago
        if (is_sel) pos += cp(buf[pos..], "\x1b[48;5;236m");
        pos += cp(buf[pos..], "\x1b[2m");
        var ago_buf: [16]u8 = undefined;
        const ago_str = formatTimeAgo(&ago_buf, e.started_at, now);
        // Right-align in 8 chars
        const ago_pad = if (8 > ago_str.len) 8 - ago_str.len else 0;
        for (0..ago_pad) |_| { if (pos < buf.len) { buf[pos] = ' '; pos += 1; } }
        pos += cp(buf[pos..], ago_str);
        pos += cp(buf[pos..], "\x1b[0m ");

        // Command text
        if (is_sel) pos += cp(buf[pos..], "\x1b[48;5;236m\x1b[1;37m") else pos += cp(buf[pos..], "\x1b[37m");
        pos += cp(buf[pos..], e.rawSlice());
        pos += cp(buf[pos..], "\x1b[0m");

        // Exit code indicator
        if (e.exit_code != 0) {
            pos += cp(buf[pos..], " \x1b[31m✘\x1b[0m");
        }

        pos += cp(buf[pos..], "\r\n");

        if (pos > buf.len - 512) {
            stdout.writeAll(buf[0..pos]) catch {};
            pos = 0;
        }
    }

    // Clear remaining lines
    for (0..max_vis -| (visible_end - scroll)) |_| {
        pos += cp(buf[pos..], "\x1b[K\r\n");
    }

    // Move cursor back to search line
    const total_lines = max_vis + 1;
    const n = std.fmt.bufPrint(buf[pos..], "\x1b[{d}A", .{total_lines}) catch "";
    pos += n.len;
    // Position cursor in search field
    const cursor_col = 12 + filter.len; // "  history [" = 12 chars
    const cn = std.fmt.bufPrint(buf[pos..], "\r\x1b[{d}C", .{cursor_col}) catch "";
    pos += cn.len;

    stdout.writeAll(buf[0..pos]) catch {};
}

fn clearArea(stdout: std.fs.File, lines: usize) void {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    pos += cp(buf[pos..], "\r\x1b[J"); // clear from cursor down
    // Move up if needed
    _ = lines;
    stdout.writeAll(buf[0..pos]) catch {};
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

fn formatDuration(buf: []u8, ms: i64) []const u8 {
    if (ms < 0) return "0s";
    if (ms < 1000) return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch "?";
    if (ms < 60000) return std.fmt.bufPrint(buf, "{d}s", .{@divTrunc(ms, 1000)}) catch "?";
    if (ms < 3600000) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(ms, 60000)}) catch "?";
    return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(ms, 3600000)}) catch "?";
}

fn formatTimeAgo(buf: []u8, started_at: i64, now: i64) []const u8 {
    const diff = if (now > started_at) now - started_at else 0;
    const secs = @divTrunc(diff, 1000);
    if (secs < 60) return std.fmt.bufPrint(buf, "{d}s ago", .{secs}) catch "?";
    const mins = @divTrunc(secs, 60);
    if (mins < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{mins}) catch "?";
    const hours = @divTrunc(mins, 60);
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hours}) catch "?";
    const days = @divTrunc(hours, 24);
    return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "?";
}

fn getTermHeight() usize {
    const c_e = struct {
        const winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    };
    var ws: c_e.winsize = undefined;
    if (c_e.ioctl(posix.STDOUT_FILENO, 0x40087468, &ws) == 0 and ws.ws_row > 0) return ws.ws_row;
    return 24;
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}
