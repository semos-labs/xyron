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

const MAX_ENTRIES = 500;

pub var replay_command: [512]u8 = undefined;
pub var replay_len: usize = 0;
pub var replay_pending: bool = false;

pub fn run(hdb: ?*history_db_mod.HistoryDb, stdout: std.fs.File) Result {
    const db = hdb orelse {
        stdout.writeAll("history: no database\n") catch {};
        return .{ .exit_code = 1 };
    };

    var entries: [MAX_ENTRIES]history_db_mod.HistoryEntry = undefined;
    var str_buf: [MAX_ENTRIES * 256]u8 = undefined;
    const count = db.recentEntries(&entries, &str_buf);
    if (count == 0) {
        stdout.writeAll("No history.\n") catch {};
        return .{};
    }

    const tty_fd = posix.openZ("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return .{ .exit_code = 1 };
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

    tty.writeAll("\x1b[?1049h\x1b[?25h") catch {};
    var alt_active = true;
    defer if (alt_active) tty.writeAll("\x1b[?25h\x1b[?1049l") catch {};

    var state = State{
        .entries = entries[0..count],
        .count = count,
        .ts = getTermSize(tty_fd),
    };
    state.cwd = posix.getcwd(&state.cwd_buf) catch ".";
    for (0..count) |i| state.scored_idx[i] = i;
    state.scored_count = count;

    state.render(tty);

    while (true) {
        var key_buf: [1]u8 = undefined;
        const rc = c.read(tty_fd, &key_buf, 1);
        if (rc == -1) {
            // EINTR from SIGWINCH — update terminal size and re-render
            state.ts = getTermSize(tty_fd);
            state.render(tty);
            continue;
        }
        if (rc <= 0) break;

        switch (key_buf[0]) {
            10, 13 => { // Enter
                if (state.scored_count > 0) {
                    const idx = state.scored_idx[state.cursor];
                    const cmd = state.entries[idx].raw_input;
                    const n = @min(cmd.len, replay_command.len);
                    @memcpy(replay_command[0..n], cmd[0..n]);
                    replay_len = n;
                    replay_pending = true;
                }
                if (alt_active) { tty.writeAll("\x1b[?25h\x1b[?1049l") catch {}; alt_active = false; }
                return .{};
            },
            9 => { // Tab — toggle detail view
                state.show_detail = !state.show_detail;
            },
            27 => { // Escape / arrows
                var seq: [2]u8 = undefined;
                const rc2 = c.read(tty_fd, &seq, 2);
                if (rc2 == 2 and seq[0] == '[') {
                    switch (seq[1]) {
                        'A' => state.moveUp(),
                        'B' => state.moveDown(),
                        else => {},
                    }
                } else if (rc2 <= 0) break;
            },
            16 => state.moveUp(), // Ctrl+P
            14 => state.moveDown(), // Ctrl+N
            6 => { // Ctrl+F — toggle failed
                state.show_failed_only = !state.show_failed_only;
                state.rescore();
            },
            4 => { // Ctrl+D — toggle cwd
                state.show_cwd_only = !state.show_cwd_only;
                state.rescore();
            },
            21 => { // Ctrl+U — clear filter
                state.filter_len = 0;
                state.rescore();
            },
            23 => { // Ctrl+W — delete word
                while (state.filter_len > 0 and state.filter[state.filter_len - 1] == ' ') state.filter_len -= 1;
                while (state.filter_len > 0 and state.filter[state.filter_len - 1] != ' ') state.filter_len -= 1;
                state.rescore();
            },
            127, 8 => { // Backspace
                if (state.filter_len > 0) {
                    state.filter_len -= 1;
                    state.rescore();
                }
            },
            3 => break, // Ctrl+C
            else => |ch| {
                if (ch >= 32 and ch < 127 and state.filter_len < 128) {
                    state.filter[state.filter_len] = ch;
                    state.filter_len += 1;
                    state.rescore();
                }
            },
        }

        state.render(tty);
    }

    return .{};
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const State = struct {
    entries: []const history_db_mod.HistoryEntry,
    count: usize,
    cursor: usize = 0,
    scroll: usize = 0,
    filter: [128]u8 = undefined,
    filter_len: usize = 0,
    scored_idx: [MAX_ENTRIES]usize = undefined,
    scored_count: usize = 0,
    show_failed_only: bool = false,
    show_cwd_only: bool = false,
    show_detail: bool = false,
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd: []const u8 = ".",
    ts: TermSize,

    fn moveUp(self: *State) void {
        if (self.cursor > 0) self.cursor -= 1;
        if (self.cursor < self.scroll) self.scroll = self.cursor;
    }

    fn moveDown(self: *State) void {
        if (self.scored_count > 0 and self.cursor + 1 < self.scored_count) self.cursor += 1;
        const vis = self.visibleRows();
        if (self.cursor >= self.scroll + vis) self.scroll = self.cursor - vis + 1;
    }

    fn visibleRows(self: *const State) usize {
        const header = 3; // title + filter + separator
        const footer = 2; // empty line + status bar
        return if (self.ts.rows > header + footer) self.ts.rows - header - footer else 1;
    }

    fn rescore(self: *State) void {
        self.scored_count = 0;
        for (self.entries, 0..) |*e, i| {
            if (self.show_failed_only and e.exit_code == 0) continue;
            if (self.show_cwd_only and !std.mem.eql(u8, e.cwd, self.cwd)) continue;
            if (self.filter_len > 0) {
                const s = fuzzy.score(e.raw_input, self.filter[0..self.filter_len]);
                if (!s.matched) continue;
            }
            if (self.scored_count < MAX_ENTRIES) {
                self.scored_idx[self.scored_count] = i;
                self.scored_count += 1;
            }
        }
        self.cursor = 0;
        self.scroll = 0;
    }

    // -----------------------------------------------------------------------
    // Rendering
    // -----------------------------------------------------------------------

    fn render(self: *const State, tty: std.fs.File) void {
        var buf: [65536]u8 = undefined;
        var pos: usize = 0;
        const cols = self.ts.cols;
        const rows = self.ts.rows;

        pos += cp(buf[pos..], "\x1b[H"); // home

        // ── Title bar (dim, subtle) ──
        pos += cp(buf[pos..], "\x1b[2m");
        pos += cp(buf[pos..], "  History Explorer");
        const tw: usize = 18;

        // Entry count (right-aligned)
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d} commands", .{self.scored_count}) catch "";
        const count_pad = if (cols > tw + count_str.len + 2) cols - tw - count_str.len - 2 else 1;
        { var p: usize = 0; while (p < count_pad and pos < buf.len) : (p += 1) { buf[pos] = ' '; pos += 1; } }
        pos += cp(buf[pos..], count_str);
        pos += cp(buf[pos..], "  ");
        pos += cp(buf[pos..], "\x1b[0m\x1b[K\r\n");

        // ── Filter bar ──
        pos += cp(buf[pos..], "  \x1b[33m> \x1b[0m"); // yellow >
        if (self.filter_len > 0) {
            pos += cp(buf[pos..], "\x1b[1m"); // bold
            pos += cp(buf[pos..], self.filter[0..self.filter_len]);
            pos += cp(buf[pos..], "\x1b[0m");
        } else {
            pos += cp(buf[pos..], "\x1b[2m"); // dim placeholder
            pos += cp(buf[pos..], "search commands...");
            pos += cp(buf[pos..], "\x1b[0m");
        }

        // Filter pills
        if (self.show_failed_only) {
            pos += cp(buf[pos..], "  \x1b[31;7m \xe2\x9c\x97 failed \x1b[0m"); // red inverse
        }
        if (self.show_cwd_only) {
            pos += cp(buf[pos..], "  \x1b[34;7m cwd \x1b[0m"); // blue inverse
        }
        pos += cp(buf[pos..], "\x1b[K\r\n");

        // ── Separator ──
        pos += cp(buf[pos..], "\x1b[2m");
        { var w: usize = 0; while (w < cols and pos < buf.len - 3) : (w += 1) {
            buf[pos] = 0xe2; buf[pos + 1] = 0x94; buf[pos + 2] = 0x80; pos += 3; // ─
        }}
        pos += cp(buf[pos..], "\x1b[0m\r\n");

        // ── Entries ──
        const max_vis = self.visibleRows();
        const vis_end = @min(self.scroll + max_vis, self.scored_count);

        if (self.scored_count == 0) {
            const empty_row = rows / 2;
            { var er: usize = 3; while (er < empty_row and pos < buf.len - 20) : (er += 1) {
                pos += cp(buf[pos..], "\x1b[K\r\n");
            }}
            const msg = if (self.filter_len > 0) "No matching commands" else "No history yet";
            const pad_l = if (cols > msg.len) (cols - msg.len) / 2 else 0;
            { var pl: usize = 0; while (pl < pad_l and pos < buf.len) : (pl += 1) { buf[pos] = ' '; pos += 1; } }
            pos += cp(buf[pos..], "\x1b[2m");
            pos += cp(buf[pos..], msg);
            pos += cp(buf[pos..], "\x1b[0m\x1b[K\r\n");
        } else {
            for (self.scroll..vis_end) |vi| {
                const ei = self.scored_idx[vi];
                const e = &self.entries[ei];
                const is_sel = vi == self.cursor;

                // Arrow / padding
                if (is_sel) {
                    pos += cp(buf[pos..], "\x1b[36m > \x1b[0m"); // cyan arrow
                } else {
                    pos += cp(buf[pos..], "   ");
                }

                // Status icon
                if (e.exit_code == 0) {
                    pos += cp(buf[pos..], "\x1b[32m\xe2\x97\x8f\x1b[0m "); // ● green
                } else {
                    pos += cp(buf[pos..], "\x1b[31m\xe2\x9c\x97\x1b[0m "); // ✗ red
                }

                // Command text
                const cmd = e.raw_input;
                const right_info_w: usize = 24;
                const max_cmd = if (cols > right_info_w + 6) cols - right_info_w - 6 else 20;
                const disp_len = @min(cmd.len, max_cmd);

                if (is_sel) pos += cp(buf[pos..], "\x1b[1m"); // bold
                pos += cp(buf[pos..], cmd[0..disp_len]);
                if (cmd.len > max_cmd) pos += cp(buf[pos..], "\xe2\x80\xa6"); // …

                // Right-align: duration + relative time
                const age = relativeTime(e.started_at);
                var right_w: usize = age.len;
                var has_dur = false;
                var dur_str: []const u8 = "";
                if (e.duration_ms >= 100) {
                    var dur_buf: [16]u8 = undefined;
                    dur_str = prompt_mod.formatDuration(&dur_buf, e.duration_ms);
                    right_w += dur_str.len + 2;
                    has_dur = true;
                }

                const cmd_vis = disp_len + @as(usize, if (cmd.len > max_cmd) 1 else 0);
                const used_w = 5 + cmd_vis;
                if (cols > used_w + right_w + 2) {
                    const gap = cols - used_w - right_w - 2;
                    { var g: usize = 0; while (g < gap and pos < buf.len) : (g += 1) { buf[pos] = ' '; pos += 1; } }
                }

                if (has_dur) {
                    pos += cp(buf[pos..], "\x1b[33m"); // yellow
                    pos += cp(buf[pos..], dur_str);
                    pos += cp(buf[pos..], "\x1b[0m  ");
                }
                pos += cp(buf[pos..], "\x1b[2m"); // dim timestamp
                pos += cp(buf[pos..], age);

                pos += cp(buf[pos..], "\x1b[0m\x1b[K\r\n");

                // Detail row (cwd)
                if (is_sel and self.show_detail and e.cwd.len > 0) {
                    pos += cp(buf[pos..], "     \x1b[2;36m"); // dim cyan
                    const max_cwd = if (cols > 10) cols - 10 else cols;
                    const cwd_len = @min(e.cwd.len, max_cwd);
                    pos += cp(buf[pos..], e.cwd[0..cwd_len]);
                    pos += cp(buf[pos..], "\x1b[0m\x1b[K\r\n");
                }
            }
        }

        // Pad remaining rows
        const detail_extra: usize = if (self.show_detail and self.scored_count > 0) 1 else 0;
        const used_rows = 3 + (vis_end - self.scroll) + detail_extra;
        { var r: usize = used_rows; while (r + 2 < rows and pos < buf.len - 10) : (r += 1) {
            pos += cp(buf[pos..], "\x1b[K\r\n");
        }}

        // ── Scrollbar ──
        if (self.scored_count > max_vis and max_vis > 2) {
            const bar_h = @max(1, max_vis * max_vis / self.scored_count);
            const bar_pos = if (self.scored_count > max_vis)
                self.scroll * (max_vis - bar_h) / (self.scored_count - max_vis)
            else 0;
            for (0..max_vis) |ri| {
                const row = 4 + ri;
                const in_bar = ri >= bar_pos and ri < bar_pos + bar_h;
                const ch: []const u8 = if (in_bar) "\x1b[2m\xe2\x96\x90\x1b[0m" else "\x1b[2m\xe2\x96\x91\x1b[0m";
                const goto = std.fmt.bufPrint(buf[pos..], "\x1b[{d};{d}H", .{ row, cols }) catch "";
                pos += goto.len;
                pos += cp(buf[pos..], ch);
            }
        }

        // ── Status bar (dim) ──
        const status_row = std.fmt.bufPrint(buf[pos..], "\x1b[{d};1H", .{rows}) catch "";
        pos += status_row.len;
        pos += cp(buf[pos..], "\x1b[2m");
        pos += cp(buf[pos..], "  ");
        pos += renderPill(buf[pos..], "Enter", "rerun");
        pos += cp(buf[pos..], " ");
        pos += renderPill(buf[pos..], "Esc", "close");
        pos += cp(buf[pos..], " ");
        pos += renderPill(buf[pos..], "Tab", "detail");
        pos += cp(buf[pos..], " ");
        pos += renderPill(buf[pos..], "^F", if (self.show_failed_only) "all" else "failed");
        pos += cp(buf[pos..], " ");
        pos += renderPill(buf[pos..], "^D", if (self.show_cwd_only) "all dirs" else "this dir");
        pos += cp(buf[pos..], "\x1b[0m\x1b[K");

        // Cursor in filter bar
        const cursor_col = 5 + self.filter_len;
        const goto_filter = std.fmt.bufPrint(buf[pos..], "\x1b[2;{d}H", .{cursor_col}) catch "";
        pos += goto_filter.len;

        tty.writeAll(buf[0..pos]) catch {};
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn renderPill(dest: []u8, key: []const u8, label: []const u8) usize {
    var pos: usize = 0;
    pos += cp(dest[pos..], "\x1b[1m"); // bold key
    pos += cp(dest[pos..], key);
    pos += cp(dest[pos..], "\x1b[22m "); // unbold, space
    pos += cp(dest[pos..], label);
    pos += cp(dest[pos..], "  ");
    return pos;
}

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
