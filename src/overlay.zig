// overlay.zig — Floating overlay system for completion, tooltips, etc.
//
// Renders content as a floating block anchored to the cursor position.
// Automatically chooses above/below based on available screen space.
// Uses absolute cursor positioning (CSI sequences) and save/restore.

const std = @import("std");
const posix = std.posix;

pub var enabled: bool = true;
pub var on_demand: bool = false;

/// Screen position
pub const Pos = struct { row: usize, col: usize };

/// Direction decision
pub const Direction = enum { above, below };

/// Query current cursor position using DSR (Device Status Report).
/// Returns {row, col} (1-based). Returns {0,0} on failure.
pub fn getCursorPos() Pos {
    const stdout = std.fs.File.stdout();
    // Send DSR request
    stdout.writeAll("\x1b[6n") catch return .{ .row = 0, .col = 0 };

    // Read response: ESC [ row ; col R
    var buf: [32]u8 = undefined;
    var len: usize = 0;

    // Poll stdin for the response (timeout 100ms)
    var fds = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = posix.poll(&fds, 100) catch return .{ .row = 0, .col = 0 };
    if (ready == 0) return .{ .row = 0, .col = 0 };

    // Read bytes until we get 'R'
    while (len < buf.len) {
        const n = posix.read(posix.STDIN_FILENO, buf[len .. len + 1]) catch break;
        if (n == 0) break;
        if (buf[len] == 'R') { len += 1; break; }
        len += 1;
    }

    // Parse: ESC [ row ; col R
    return parseDSR(buf[0..len]);
}

fn parseDSR(response: []const u8) Pos {
    // Find the ESC [ ... ; ... R pattern
    var start: usize = 0;
    while (start < response.len and response[start] != '[') : (start += 1) {}
    if (start >= response.len) return .{ .row = 0, .col = 0 };
    start += 1; // skip [

    const semi = std.mem.indexOf(u8, response[start..], ";") orelse return .{ .row = 0, .col = 0 };
    const r_pos = std.mem.indexOf(u8, response[start..], "R") orelse return .{ .row = 0, .col = 0 };

    const row = std.fmt.parseInt(usize, response[start..][0..semi], 10) catch return .{ .row = 0, .col = 0 };
    const col = std.fmt.parseInt(usize, response[start + semi + 1 ..][0 .. r_pos - semi - 1], 10) catch return .{ .row = 0, .col = 0 };

    return .{ .row = row, .col = col };
}

/// Get terminal dimensions.
pub fn getTermSize() struct { rows: usize, cols: usize } {
    const c_ext = struct {
        const winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    };
    var ws: c_ext.winsize = undefined;
    if (c_ext.ioctl(posix.STDOUT_FILENO, 0x40087468, &ws) == 0) {
        return .{
            .rows = if (ws.ws_row > 0) ws.ws_row else 24,
            .cols = if (ws.ws_col > 0) ws.ws_col else 80,
        };
    }
    return .{ .rows = 24, .cols = 80 };
}

/// Decide whether to render above or below the cursor.
pub fn chooseDirection(cursor_row: usize, content_lines: usize, term_rows: usize) Direction {
    const space_below = if (term_rows > cursor_row) term_rows - cursor_row else 0;
    const space_above = if (cursor_row > 1) cursor_row - 1 else 0;

    if (space_below >= content_lines) return .below;
    if (space_above >= content_lines) return .above;
    // Not enough space either way — pick the side with more room
    return if (space_below >= space_above) .below else .above;
}

/// Render an overlay at the given position. Returns the number of lines used.
/// `renderFn` is called with (buf, max_lines) and should write content.
pub fn renderOverlay(
    stdout: std.fs.File,
    cursor_row: usize,
    content_lines: usize,
    term_rows: usize,
    direction: Direction,
    content: []const u8,
) void {
    // Save cursor
    stdout.writeAll("\x1b[s") catch {};

    const target_row = switch (direction) {
        .below => cursor_row + 1,
        .above => if (cursor_row > content_lines) cursor_row - content_lines else 1,
    };

    // Move to target row and render each line
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var row = target_row;
    while (line_iter.next()) |line| {
        if (row > term_rows) break;
        // Move to absolute position
        var pos_buf: [32]u8 = undefined;
        const pos_seq = std.fmt.bufPrint(&pos_buf, "\x1b[{d};1H\x1b[K", .{row}) catch continue;
        stdout.writeAll(pos_seq) catch {};
        stdout.writeAll(line) catch {};
        row += 1;
    }

    // Restore cursor
    stdout.writeAll("\x1b[u") catch {};
}

/// Clear the overlay area (call when closing).
pub fn clearOverlay(
    stdout: std.fs.File,
    cursor_row: usize,
    content_lines: usize,
    term_rows: usize,
    direction: Direction,
) void {
    stdout.writeAll("\x1b[s") catch {};

    const target_row = switch (direction) {
        .below => cursor_row + 1,
        .above => if (cursor_row > content_lines) cursor_row - content_lines else 1,
    };

    var row = target_row;
    var count: usize = 0;
    while (count < content_lines and row <= term_rows) : ({ row += 1; count += 1; }) {
        var pos_buf: [32]u8 = undefined;
        const pos_seq = std.fmt.bufPrint(&pos_buf, "\x1b[{d};1H\x1b[K", .{row}) catch continue;
        stdout.writeAll(pos_seq) catch {};
    }

    stdout.writeAll("\x1b[u") catch {};
}
