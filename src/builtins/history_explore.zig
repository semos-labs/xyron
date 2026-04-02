// builtins/history_explore.zig — Interactive TUI history browser.
//
// Full-screen alternate-buffer browser with fuzzy search, filters,
// and rerun. Uses /dev/tty for I/O (works when stdout is piped).

const std = @import("std");
const posix = std.posix;
const c = std.c;
const history_db_mod = @import("../history_db.zig");
const fuzzy = @import("../fuzzy.zig");
const prompt_mod = @import("../prompt.zig");
const Result = @import("mod.zig").BuiltinResult;

const MAX_ENTRIES = 200;
const MAX_VISIBLE = 50;

pub var replay_command: [512]u8 = undefined;
pub var replay_len: usize = 0;
pub var replay_pending: bool = false;

pub fn run(hdb: ?*history_db_mod.HistoryDb, stdout: std.fs.File) Result {
    const db = hdb orelse {
        stdout.writeAll("history: no database\n") catch {};
        return .{ .exit_code = 1 };
    };

    // Load entries
    var entries: [MAX_ENTRIES]history_db_mod.HistoryEntry = undefined;
    var str_buf: [MAX_ENTRIES * 256]u8 = undefined;
    const count = db.recentEntries(&entries, &str_buf);
    if (count == 0) {
        stdout.writeAll("No history.\n") catch {};
        return .{};
    }

    // Open tty for interactive I/O
    const tty_fd = posix.openZ("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return .{ .exit_code = 1 };
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
    tty.writeAll("\x1b[?1049h\x1b[?25h") catch {};
    var alt_active = true;
    defer if (alt_active) tty.writeAll("\x1b[?1049l") catch {};

    // State
    var filter: [128]u8 = undefined;
    var filter_len: usize = 0;
    var cursor: usize = 0;
    var scroll: usize = 0;
    var scored_idx: [MAX_ENTRIES]usize = undefined;
    var scored_count: usize = count;
    var show_failed_only = false;
    var show_cwd_only = false;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch ".";

    // Initial: all entries
    for (0..count) |i| scored_idx[i] = i;

    const ts = getTermSize(tty_fd);

    rescore(entries[0..count], filter[0..filter_len], &scored_idx, &scored_count, show_failed_only, show_cwd_only, cwd);
    render(tty, entries[0..count], &scored_idx, scored_count, cursor, scroll, filter[0..filter_len], ts, show_failed_only, show_cwd_only);

    while (true) {
        var key_buf: [1]u8 = undefined;
        const rc = c.read(tty_fd, &key_buf, 1);
        if (rc <= 0) break;

        switch (key_buf[0]) {
            10, 13 => { // Enter — rerun selected command
                if (scored_count > 0) {
                    const idx = scored_idx[cursor];
                    const cmd = entries[idx].raw_input;
                    const n = @min(cmd.len, replay_command.len);
                    @memcpy(replay_command[0..n], cmd[0..n]);
                    replay_len = n;
                    replay_pending = true;
                }
                if (alt_active) { tty.writeAll("\x1b[?1049l") catch {}; alt_active = false; }
                return .{};
            },
            27 => { // Escape / arrow keys
                var seq: [2]u8 = undefined;
                const rc2 = c.read(tty_fd, &seq, 2);
                if (rc2 == 2 and seq[0] == '[') {
                    switch (seq[1]) {
                        'A' => { // Up
                            if (cursor > 0) cursor -= 1;
                            if (cursor < scroll) scroll = cursor;
                        },
                        'B' => { // Down
                            if (scored_count > 0 and cursor + 1 < scored_count) cursor += 1;
                            const vis = @min(MAX_VISIBLE, ts.rows -| 4);
                            if (cursor >= scroll + vis) scroll = cursor - vis + 1;
                        },
                        else => {},
                    }
                } else if (rc2 <= 0) {
                    // Plain Escape — exit
                    break;
                }
            },
            16 => { // Ctrl+P — up
                if (cursor > 0) cursor -= 1;
                if (cursor < scroll) scroll = cursor;
            },
            14 => { // Ctrl+N — down
                if (scored_count > 0 and cursor + 1 < scored_count) cursor += 1;
                const vis = @min(MAX_VISIBLE, ts.rows -| 4);
                if (cursor >= scroll + vis) scroll = cursor - vis + 1;
            },
            6 => { // Ctrl+F — toggle failed filter
                show_failed_only = !show_failed_only;
                rescore(entries[0..count], filter[0..filter_len], &scored_idx, &scored_count, show_failed_only, show_cwd_only, cwd);
                cursor = 0; scroll = 0;
            },
            4 => { // Ctrl+D — toggle cwd filter
                show_cwd_only = !show_cwd_only;
                rescore(entries[0..count], filter[0..filter_len], &scored_idx, &scored_count, show_failed_only, show_cwd_only, cwd);
                cursor = 0; scroll = 0;
            },
            21 => { // Ctrl+U — clear filter
                filter_len = 0;
                rescore(entries[0..count], filter[0..filter_len], &scored_idx, &scored_count, show_failed_only, show_cwd_only, cwd);
                cursor = 0; scroll = 0;
            },
            127, 8 => { // Backspace
                if (filter_len > 0) {
                    filter_len -= 1;
                    rescore(entries[0..count], filter[0..filter_len], &scored_idx, &scored_count, show_failed_only, show_cwd_only, cwd);
                    cursor = 0; scroll = 0;
                }
            },
            3 => break, // Ctrl+C
            else => |ch| {
                if (ch >= 32 and ch < 127 and filter_len < 128) {
                    filter[filter_len] = ch;
                    filter_len += 1;
                    rescore(entries[0..count], filter[0..filter_len], &scored_idx, &scored_count, show_failed_only, show_cwd_only, cwd);
                    cursor = 0; scroll = 0;
                }
            },
        }

        render(tty, entries[0..count], &scored_idx, scored_count, cursor, scroll, filter[0..filter_len], ts, show_failed_only, show_cwd_only);
    }

    return .{};
}

// ---------------------------------------------------------------------------
// Scoring and filtering
// ---------------------------------------------------------------------------

fn rescore(
    entries: []const history_db_mod.HistoryEntry,
    filter: []const u8,
    idx: *[MAX_ENTRIES]usize,
    count: *usize,
    failed_only: bool,
    cwd_only: bool,
    cwd: []const u8,
) void {
    count.* = 0;
    for (entries, 0..) |*e, i| {
        if (failed_only and e.exit_code == 0) continue;
        if (cwd_only and !std.mem.eql(u8, e.cwd, cwd)) continue;
        if (filter.len > 0) {
            const s = fuzzy.score(e.raw_input, filter);
            if (!s.matched) continue;
        }
        if (count.* < MAX_ENTRIES) {
            idx[count.*] = i;
            count.* += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const TermSize = struct { rows: usize, cols: usize };

fn render(
    tty: std.fs.File,
    entries: []const history_db_mod.HistoryEntry,
    idx: *const [MAX_ENTRIES]usize,
    count: usize,
    cursor: usize,
    scroll: usize,
    filter: []const u8,
    ts: TermSize,
    failed_only: bool,
    cwd_only: bool,
) void {
    var buf: [32768]u8 = undefined;
    var pos: usize = 0;

    // Clear screen, home
    pos += cp(buf[pos..], "\x1b[H\x1b[J");

    // Title bar
    pos += cp(buf[pos..], "\x1b[7m");
    pos += cp(buf[pos..], " History Explorer");
    const count_str = std.fmt.bufPrint(buf[pos..], "  ({d} entries)", .{count}) catch "";
    pos += count_str.len;
    // Pad to terminal width
    var title_w: usize = 17 + count_str.len;
    while (title_w < ts.cols and pos < buf.len) : (title_w += 1) {
        buf[pos] = ' ';
        pos += 1;
    }
    pos += cp(buf[pos..], "\x1b[0m\r\n");

    // Filter bar
    pos += cp(buf[pos..], "\x1b[33m  > \x1b[0m");
    if (filter.len > 0) {
        pos += cp(buf[pos..], filter);
    } else {
        pos += cp(buf[pos..], "\x1b[2mtype to search...\x1b[0m");
    }

    // Filter indicators
    if (failed_only) pos += cp(buf[pos..], "  \x1b[31m[failed]\x1b[0m");
    if (cwd_only) pos += cp(buf[pos..], "  \x1b[34m[cwd]\x1b[0m");
    pos += cp(buf[pos..], "\x1b[K\r\n");

    // Separator
    pos += cp(buf[pos..], "\x1b[2m");
    {
        var w: usize = 0;
        while (w < ts.cols and pos < buf.len) : (w += 1) {
            buf[pos] = '-';
            pos += 1;
        }
    }
    pos += cp(buf[pos..], "\x1b[0m\r\n");

    // Entries
    const max_vis = @min(MAX_VISIBLE, ts.rows -| 6);
    const vis_end = @min(scroll + max_vis, count);

    for (scroll..vis_end) |vi| {
        const ei = idx[vi];
        const e = &entries[ei];
        const is_sel = vi == cursor;

        if (is_sel) pos += cp(buf[pos..], "\x1b[7m");

        // Exit code indicator
        if (e.exit_code == 0) {
            pos += cp(buf[pos..], "  \x1b[32m•\x1b[0m ");
        } else {
            pos += cp(buf[pos..], "  \x1b[31m✗\x1b[0m ");
        }
        if (is_sel) pos += cp(buf[pos..], "\x1b[7m");

        // Command text (truncated to fit)
        const max_cmd = if (ts.cols > 30) ts.cols - 30 else 20;
        const cmd = e.raw_input;
        const disp_len = @min(cmd.len, max_cmd);
        pos += cp(buf[pos..], cmd[0..disp_len]);
        if (cmd.len > max_cmd) pos += cp(buf[pos..], "...");

        // Duration (right side)
        if (!is_sel) {
            pos += cp(buf[pos..], "\x1b[2m");
        }
        if (e.duration_ms > 0) {
            var dur_buf: [16]u8 = undefined;
            const dur = prompt_mod.formatDuration(&dur_buf, e.duration_ms);
            pos += cp(buf[pos..], "  ");
            pos += cp(buf[pos..], dur);
        }
        pos += cp(buf[pos..], "\x1b[0m\x1b[K\r\n");
    }

    // Pad remaining rows
    const used = 3 + (vis_end - scroll);
    var r = used;
    while (r + 2 < ts.rows) : (r += 1) {
        pos += cp(buf[pos..], "\x1b[K\r\n");
    }

    // Status bar
    pos += cp(buf[pos..], "\x1b[2m");
    pos += cp(buf[pos..], "  Enter: rerun  Esc: cancel  ^F: failed  ^D: cwd  ^U: clear");
    pos += cp(buf[pos..], "\x1b[0m\x1b[K");

    tty.writeAll(buf[0..pos]) catch {};
}

fn getTermSize(fd: posix.fd_t) TermSize {
    const ext = struct {
        const winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    };
    var ws: ext.winsize = undefined;
    if (ext.ioctl(fd, 0x40087468, &ws) == 0) {
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
