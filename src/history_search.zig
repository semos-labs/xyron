// history_search.zig — Full-screen history search (Ctrl+R).
//
// Alternate-screen TUI matching the history explorer design language.
// Fuzzy search, deduped entries, duration + relative time display.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const fuzzy = @import("fuzzy.zig");
const history_db_mod = @import("history_db.zig");
const prompt_mod = @import("prompt.zig");
const style = @import("style.zig");

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

    // Raw mode on tty
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
    tty.writeAll("\x1b[?1049h\x1b[?25h") catch {};
    var alt_active = true;
    defer if (alt_active) tty.writeAll("\x1b[?25h\x1b[?1049l") catch {};

    // State
    var filter: [128]u8 = undefined;
    var filter_len: usize = 0;
    var scored_idx: [MAX_ENTRIES]usize = undefined;
    var scored_vals: [MAX_ENTRIES]i32 = undefined;
    var scored_count: usize = 0;
    var selected: usize = 0;
    var scroll: usize = 0;
    var ts = getTermSize(tty_fd);

    scoreEntries(&entries, total, filter[0..0], &scored_idx, &scored_vals, &scored_count);
    render(tty, &entries, &scored_idx, scored_count, selected, scroll, filter[0..filter_len], ts);

    while (true) {
        var key_buf: [1]u8 = undefined;
        const rc = c.read(tty_fd, &key_buf, 1);
        if (rc == -1) {
            // EINTR from SIGWINCH — resize
            ts = getTermSize(tty_fd);
            render(tty, &entries, &scored_idx, scored_count, selected, scroll, filter[0..filter_len], ts);
            continue;
        }
        if (rc <= 0) break;

        const max_vis = visibleRows(ts);

        switch (key_buf[0]) {
            10, 13 => { // Enter — select
                if (alt_active) { tty.writeAll("\x1b[?25h\x1b[?1049l") catch {}; alt_active = false; }
                if (scored_count > 0) {
                    const idx = scored_idx[selected];
                    return .{ .selected = entries[idx].rawSlice() };
                }
                return .cancelled;
            },
            27 => { // Escape / arrows
                var seq: [2]u8 = undefined;
                const rc2 = c.read(tty_fd, &seq, 2);
                if (rc2 == 2 and seq[0] == '[') {
                    switch (seq[1]) {
                        'C' => { // Right arrow — select
                            if (alt_active) { tty.writeAll("\x1b[?25h\x1b[?1049l") catch {}; alt_active = false; }
                            if (scored_count > 0) {
                                const idx2 = scored_idx[selected];
                                return .{ .selected = entries[idx2].rawSlice() };
                            }
                            return .cancelled;
                        },
                        'A' => { // Up
                            if (selected > 0) selected -= 1;
                            if (selected < scroll) scroll = selected;
                        },
                        'B' => { // Down
                            if (scored_count > 0 and selected + 1 < scored_count) selected += 1;
                            if (selected >= scroll + max_vis) scroll = selected - max_vis + 1;
                        },
                        else => {},
                    }
                } else if (rc2 <= 0) break; // plain Escape
            },
            3, 18 => break, // Ctrl+C, Ctrl+R again = cancel
            16 => { // Ctrl+P — up
                if (selected > 0) selected -= 1;
                if (selected < scroll) scroll = selected;
            },
            14 => { // Ctrl+N — down
                if (scored_count > 0 and selected + 1 < scored_count) selected += 1;
                if (selected >= scroll + max_vis) scroll = selected - max_vis + 1;
            },
            21 => { // Ctrl+U — clear
                filter_len = 0;
                rescore(&entries, total, filter[0..filter_len], &scored_idx, &scored_vals, &scored_count, &selected, &scroll);
            },
            23 => { // Ctrl+W — delete word
                while (filter_len > 0 and filter[filter_len - 1] == ' ') filter_len -= 1;
                while (filter_len > 0 and filter[filter_len - 1] != ' ') filter_len -= 1;
                rescore(&entries, total, filter[0..filter_len], &scored_idx, &scored_vals, &scored_count, &selected, &scroll);
            },
            127, 8 => { // Backspace
                if (filter_len > 0) {
                    filter_len -= 1;
                    rescore(&entries, total, filter[0..filter_len], &scored_idx, &scored_vals, &scored_count, &selected, &scroll);
                }
            },
            else => |ch| {
                if (ch >= 32 and ch < 127 and filter_len < 128) {
                    filter[filter_len] = ch;
                    filter_len += 1;
                    rescore(&entries, total, filter[0..filter_len], &scored_idx, &scored_vals, &scored_count, &selected, &scroll);
                }
            },
        }

        render(tty, &entries, &scored_idx, scored_count, selected, scroll, filter[0..filter_len], ts);
    }

    return .cancelled;
}

// ---------------------------------------------------------------------------
// Loading / scoring
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
    selected.* = 0;
    scroll.* = 0;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const TermSize = struct { rows: usize, cols: usize };

fn visibleRows(ts: TermSize) usize {
    const header = 3; // title + filter + separator
    const footer = 2; // empty + status bar
    return if (ts.rows > header + footer) ts.rows - header - footer else 1;
}

fn render(
    tty: std.fs.File,
    entries: *const [MAX_ENTRIES]Entry,
    scored_idx: *const [MAX_ENTRIES]usize,
    count: usize,
    selected: usize,
    scroll: usize,
    filter: []const u8,
    ts: TermSize,
) void {
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;
    const cols = ts.cols;
    const rows = ts.rows;

    pos += style.home(buf[pos..]);

    // ── Title bar ──
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], "  History Search");
    const tw: usize = 16;
    var count_buf: [32]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d} matches", .{count}) catch "";
    const count_pad = if (cols > tw + count_str.len + 4) cols - tw - count_str.len - 4 else 1;
    { var p: usize = 0; while (p < count_pad and pos < buf.len) : (p += 1) { buf[pos] = ' '; pos += 1; } }
    pos += cp(buf[pos..], count_str);
    pos += cp(buf[pos..], "  ");
    pos += style.reset(buf[pos..]);
    pos += style.clearLine(buf[pos..]);
    pos += style.crlf(buf[pos..]);

    // ── Filter bar ──
    pos += cp(buf[pos..], "  ");
    pos += style.colored(buf[pos..], .yellow, "> ");
    if (filter.len > 0) {
        pos += style.boldText(buf[pos..], filter);
    } else {
        pos += style.dimText(buf[pos..], "search...");
    }
    pos += style.clearLine(buf[pos..]);
    pos += style.crlf(buf[pos..]);

    // ── Separator ──
    pos += style.dim(buf[pos..]);
    pos += style.hline(buf[pos..], cols);
    pos += style.reset(buf[pos..]);
    pos += style.crlf(buf[pos..]);

    // ── Entries ──
    const max_vis = visibleRows(ts);
    const vis_end = @min(scroll + max_vis, count);

    if (count == 0) {
        const empty_row = rows / 2;
        { var er: usize = 3; while (er < empty_row and pos < buf.len - 20) : (er += 1) {
            pos += style.clearLine(buf[pos..]);
            pos += style.crlf(buf[pos..]);
        }}
        const msg = if (filter.len > 0) "No matches" else "No history";
        const pad_l = if (cols > msg.len) (cols - msg.len) / 2 else 0;
        { var pl: usize = 0; while (pl < pad_l and pos < buf.len) : (pl += 1) { buf[pos] = ' '; pos += 1; } }
        pos += style.dimText(buf[pos..], msg);
        pos += style.clearLine(buf[pos..]);
        pos += style.crlf(buf[pos..]);
    } else {
        for (scroll..vis_end) |vi| {
            const idx = scored_idx[vi];
            const e = &entries[idx];
            const is_sel = vi == selected;

            // Arrow
            if (is_sel) {
                pos += style.colored(buf[pos..], .cyan, " > ");
            } else {
                pos += cp(buf[pos..], "   ");
            }

            // Status icon
            if (e.exit_code == 0) {
                pos += style.colored(buf[pos..], .green, style.box.bullet);
                pos += cp(buf[pos..], " ");
            } else {
                pos += style.colored(buf[pos..], .red, style.box.cross);
                pos += cp(buf[pos..], " ");
            }

            // Command text
            const cmd = e.rawSlice();
            const right_w: usize = 20;
            const max_cmd = if (cols > right_w + 6) cols - right_w - 6 else 20;
            const disp_len = @min(cmd.len, max_cmd);

            if (is_sel) pos += style.bold(buf[pos..]);
            pos += cp(buf[pos..], cmd[0..disp_len]);
            if (cmd.len > max_cmd) pos += cp(buf[pos..], style.box.ellipsis);
            pos += style.reset(buf[pos..]);

            // Right-align: duration + time
            const age = relativeTime(e.started_at);
            var rw: usize = age.len;
            var has_dur = false;
            var dur_str: []const u8 = "";
            if (e.duration_ms >= 100) {
                var dur_buf: [16]u8 = undefined;
                dur_str = prompt_mod.formatDuration(&dur_buf, e.duration_ms);
                rw += dur_str.len + 2;
                has_dur = true;
            }

            const cmd_vis = disp_len + @as(usize, if (cmd.len > max_cmd) 1 else 0);
            const used = 5 + cmd_vis;
            if (cols > used + rw + 2) {
                const gap = cols - used - rw - 2;
                { var g: usize = 0; while (g < gap and pos < buf.len) : (g += 1) { buf[pos] = ' '; pos += 1; } }
            }

            if (has_dur) {
                pos += style.colored(buf[pos..], .yellow, dur_str);
                pos += cp(buf[pos..], "  ");
            }
            pos += style.dimText(buf[pos..], age);
            pos += style.clearLine(buf[pos..]);
            pos += style.crlf(buf[pos..]);
        }
    }

    // Pad remaining
    const used_rows = 3 + (vis_end - scroll);
    { var r: usize = used_rows; while (r + 2 < rows and pos < buf.len - 10) : (r += 1) {
        pos += style.clearLine(buf[pos..]);
        pos += style.crlf(buf[pos..]);
    }}

    // ── Scrollbar ──
    if (count > max_vis and max_vis > 2) {
        const bar_h = @max(1, max_vis * max_vis / count);
        const bar_pos = if (count > max_vis) scroll * (max_vis - bar_h) / (count - max_vis) else 0;
        for (0..max_vis) |ri| {
            const row = 4 + ri;
            const in_bar = ri >= bar_pos and ri < bar_pos + bar_h;
            pos += style.moveTo(buf[pos..], row, cols);
            pos += style.dimText(buf[pos..], if (in_bar) style.box.scrollbar_thumb else style.box.scrollbar_track);
        }
    }

    // ── Status bar ──
    pos += style.moveTo(buf[pos..], rows, 1);
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], "  ");
    pos += style.unbold(buf[pos..]);
    pos += style.bold(buf[pos..]);
    pos += cp(buf[pos..], "Enter");
    pos += style.unbold(buf[pos..]);
    pos += cp(buf[pos..], " select  ");
    pos += style.bold(buf[pos..]);
    pos += cp(buf[pos..], "Esc");
    pos += style.unbold(buf[pos..]);
    pos += cp(buf[pos..], " cancel  ");
    pos += style.bold(buf[pos..]);
    pos += cp(buf[pos..], "^W");
    pos += style.unbold(buf[pos..]);
    pos += cp(buf[pos..], " del word");
    pos += style.reset(buf[pos..]);
    pos += style.clearLine(buf[pos..]);

    // Cursor in filter
    const cursor_col = 5 + filter.len;
    pos += style.moveTo(buf[pos..], 2, cursor_col);

    tty.writeAll(buf[0..pos]) catch {};
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

fn getTermSize(fd: posix.fd_t) TermSize {
    const ts = style.getTermSize(fd);
    return .{ .rows = ts.rows, .cols = ts.cols };
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}
