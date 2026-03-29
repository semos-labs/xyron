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
    char: u8, // printable ASCII character
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
    ctrl_c,
    ctrl_d,
    ctrl_l, // clear screen
    ctrl_r, // reverse search
    escape, // bare ESC (no sequence followed)
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
        var buf: [1]u8 = undefined;
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 0) return .ctrl_d;
        break :blk buf[0];
    };

    // Control characters
    if (byte == 9) return .tab;
    if (byte == '\r' or byte == '\n') return .enter;
    if (byte == 127 or byte == 8) return .backspace; // DEL or BS
    if (byte == 3) return .ctrl_c;
    if (byte == 4) return .ctrl_d;
    if (byte == 12) return .ctrl_l;
    if (byte == 18) return .ctrl_r;

    // Escape sequence
    if (byte == 27) return parseEscapeSequence();

    // Printable ASCII
    if (byte >= 32 and byte < 127) return .{ .char = byte };

    return .unknown;
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
        // Not a CSI sequence — stash the byte so it's not lost
        stashed_byte = buf[0];
        return .escape;
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
