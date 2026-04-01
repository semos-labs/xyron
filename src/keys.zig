// keys.zig — Key event types and escape sequence parser.
//
// Reads raw bytes from stdin and interprets them as key events.
// Handles ASCII control characters and common ANSI escape sequences
// (arrow keys). Unknown sequences are silently ignored.

const std = @import("std");
const posix = std.posix;
const c = std.c;

// ---------------------------------------------------------------------------
// Key types
// ---------------------------------------------------------------------------

pub const Key = union(enum) {
    char: u8,
    /// Multi-byte UTF-8 character (2-4 bytes).
    utf8: struct { bytes: [4]u8, len: u3 },
    tab,
    shift_tab,
    enter,
    backspace,
    left,
    right,
    up,
    down,
    home,
    end_key,
    delete,
    ctrl_a, // home
    ctrl_b, // left
    ctrl_c, // interrupt
    ctrl_d, // EOF / delete at cursor
    ctrl_e, // end
    ctrl_f, // right
    ctrl_k, // kill to end of line
    ctrl_l, // clear screen
    ctrl_n, // down (history next)
    ctrl_p, // up (history previous)
    ctrl_r, // reverse search
    ctrl_t, // transpose chars
    ctrl_u, // kill to start of line
    ctrl_w, // kill word backward
    ctrl_y, // yank (paste kill buffer)
    ctrl_space, // trigger completion
    escape,
    // Alt/Meta combos (ESC + key)
    alt_b, // word backward
    alt_f, // word forward
    alt_d, // kill word forward
    alt_backspace, // kill word backward (same as ctrl_w)
    resize, // terminal resized (SIGWINCH)
    unknown,
};

// ---------------------------------------------------------------------------
// Key reader
// ---------------------------------------------------------------------------

/// Read one key event from stdin. Blocks until a key is available.
/// Parses escape sequences for arrow keys and other special keys.
pub fn readKey() !Key {
    // Check for stashed byte from a previous ESC + non-bracket sequence
    const byte = if (stashed_byte) |b| blk: {
        stashed_byte = null;
        break :blk b;
    } else blk: {
        // Poll stdin + IPC socket simultaneously. This lets xyron handle
        // IPC requests (like handshake) while waiting for user input.
        const ipc_mod = @import("ipc.zig");
        while (true) {
            var fds: [2]posix.pollfd = .{
                .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = ipc_mod.getListenFd(), .events = posix.POLL.IN, .revents = 0 },
            };
            const nfds: usize = if (fds[1].fd >= 0) 2 else 1;
            const ready = posix.poll(fds[0..nfds], -1) catch |err| {
                if (err == error.Interrupted) return .resize; // SIGWINCH
                return error.InputOutput;
            };
            if (ready == 0) continue;

            // Handle IPC if ready (before stdin so handshake completes fast)
            if (nfds > 1 and fds[1].revents & posix.POLL.IN != 0) {
                ipc_mod.poll();
            }

            // Handle stdin if ready
            if (fds[0].revents & posix.POLL.IN != 0) {
                var buf: [1]u8 = undefined;
                const rc = c.read(posix.STDIN_FILENO, &buf, 1);
                if (rc > 0) break :blk buf[0];
                if (rc == 0) return .ctrl_d;
                const err = std.posix.errno(rc);
                if (err == .INTR) return .resize;
                return error.InputOutput;
            }
        }
    };

    // Control characters (byte values 0-31)
    return switch (byte) {
        0 => .ctrl_space, // ^@ — Ctrl+Space
        1 => .ctrl_a, // ^A — home
        2 => .ctrl_b, // ^B — left
        3 => .ctrl_c, // ^C — interrupt
        4 => .ctrl_d, // ^D — EOF / delete at cursor
        5 => .ctrl_e, // ^E — end
        6 => .ctrl_f, // ^F — right
        8 => .backspace, // ^H — backspace
        9 => .tab,
        10, 13 => .enter, // ^J / ^M
        11 => .ctrl_k, // ^K — kill to end
        12 => .ctrl_l, // ^L — clear screen
        14 => .ctrl_n, // ^N — down
        16 => .ctrl_p, // ^P — up
        18 => .ctrl_r, // ^R — reverse search
        20 => .ctrl_t, // ^T — transpose
        21 => .ctrl_u, // ^U — kill to start
        23 => .ctrl_w, // ^W — kill word backward
        25 => .ctrl_y, // ^Y — yank
        27 => parseEscapeSequence(), // ESC
        127 => .backspace, // DEL
        32...126 => .{ .char = byte }, // printable ASCII
        // UTF-8 multi-byte sequences
        0xC0...0xDF => readUtf8(byte, 2), // 2-byte (Latin, Greek, Cyrillic, etc.)
        0xE0...0xEF => readUtf8(byte, 3), // 3-byte (CJK, emoji, etc.)
        0xF0...0xF7 => readUtf8(byte, 4), // 4-byte (emoji, rare scripts)
        else => .unknown,
    };
}

/// Read remaining UTF-8 continuation bytes and return as a utf8 key.
fn readUtf8(lead: u8, expected_len: u3) Key {
    var bytes: [4]u8 = undefined;
    bytes[0] = lead;
    var i: usize = 1;
    while (i < expected_len) : (i += 1) {
        var buf: [1]u8 = undefined;
        const rc = c.read(posix.STDIN_FILENO, &buf, 1);
        if (rc <= 0) return .unknown;
        if (buf[0] & 0xC0 != 0x80) return .unknown; // not a continuation byte
        bytes[i] = buf[0];
    }
    return .{ .utf8 = .{ .bytes = bytes, .len = expected_len } };
}

/// Stashed byte from a failed escape sequence parse (ESC + non-bracket).
/// Returned on the next readKey() call.
var stashed_byte: ?u8 = null;

/// After reading ESC (0x1b), try to read the rest of the sequence.
/// Uses poll with a short timeout to detect bare ESC vs. sequence.
fn parseEscapeSequence() Key {
    var fds = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = posix.poll(&fds, 50) catch return .escape;
    if (ready == 0) return .escape;

    var buf: [1]u8 = undefined;
    const n1 = posix.read(posix.STDIN_FILENO, &buf) catch return .escape;
    if (n1 == 0) return .escape;

    if (buf[0] != '[') {
        // Alt/Meta combo: ESC + letter
        return switch (buf[0]) {
            'b' => .alt_b, // Alt+B — word backward
            'f' => .alt_f, // Alt+F — word forward
            'd' => .alt_d, // Alt+D — kill word forward
            127 => .alt_backspace, // Alt+Backspace — kill word backward
            else => blk: {
                // Not a known combo — stash byte for next readKey
                stashed_byte = buf[0];
                break :blk .escape;
            },
        };
    }

    // Read the command byte
    var cmd: [1]u8 = undefined;
    const n2 = posix.read(posix.STDIN_FILENO, &cmd) catch return .escape;
    if (n2 == 0) return .escape;

    return switch (cmd[0]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end_key,
        'Z' => .shift_tab,
        '3' => blk: {
            // Delete key: ESC [ 3 ~
            var tilde: [1]u8 = undefined;
            _ = posix.read(posix.STDIN_FILENO, &tilde) catch {};
            break :blk .delete;
        },
        else => .unknown,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Key enum is constructible" {
    const k1: Key = .enter;
    const k2: Key = .{ .char = 'a' };
    try std.testing.expect(k1 == .enter);
    try std.testing.expectEqual(@as(u8, 'a'), k2.char);
}
