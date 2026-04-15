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
    ctrl_g, // TUI: edit
    ctrl_o, // TUI: add/open
    ctrl_v, // TUI: toggle view
    ctrl_x, // TUI: delete
    ctrl_space, // trigger completion
    escape,
    // Alt/Meta combos (ESC + key)
    ctrl_up, // preview scroll up (line)
    ctrl_down, // preview scroll down (line)
    page_up, // page up
    page_down, // page down
    alt_b, // word backward
    alt_f, // word forward
    alt_d, // kill word forward
    alt_backspace, // kill word backward (same as ctrl_w)
    paste_begin, // bracketed paste start (\x1b[200~)
    paste_end, // bracketed paste end (\x1b[201~)
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
        const shell_mod = @import("shell.zig");
        while (true) {
            // Drain any pending SIGWINCH BEFORE blocking — the signal may
            // have arrived between the previous render and this poll, in
            // which case EINTR from poll() won't fire (signal already ran)
            // and the prompt would stay at stale dims until the user types.
            if (shell_mod.winch_pending) {
                shell_mod.winch_pending = false;
                return .resize;
            }
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
        7 => .ctrl_g, // ^G — TUI edit
        8 => .backspace, // ^H — backspace
        9 => .tab,
        10, 13 => .enter, // ^J / ^M
        11 => .ctrl_k, // ^K — kill to end
        12 => .ctrl_l, // ^L — clear screen
        14 => .ctrl_n, // ^N — down
        15 => .ctrl_o, // ^O — TUI add/open
        16 => .ctrl_p, // ^P — up
        18 => .ctrl_r, // ^R — reverse search
        20 => .ctrl_t, // ^T — transpose
        21 => .ctrl_u, // ^U — kill to start
        22 => .ctrl_v, // ^V — TUI toggle view
        23 => .ctrl_w, // ^W — kill word backward
        24 => .ctrl_x, // ^X — TUI delete
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
    return readUtf8FromFd(posix.STDIN_FILENO, lead, expected_len);
}

fn readUtf8FromFd(fd: posix.fd_t, lead: u8, expected_len: u3) Key {
    var bytes: [4]u8 = undefined;
    bytes[0] = lead;
    var i: usize = 1;
    while (i < expected_len) : (i += 1) {
        var buf: [1]u8 = undefined;
        const rc = c.read(fd, &buf, 1);
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
    return parseEscapeFromFd(posix.STDIN_FILENO);
}

fn parseEscapeFromFd(fd: posix.fd_t) Key {
    var fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const ready = posix.poll(&fds, 50) catch return .escape;
    if (ready == 0) return .escape;

    var buf: [1]u8 = undefined;
    const n1 = posix.read(fd, &buf) catch return .escape;
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
    const n2 = posix.read(fd, &cmd) catch return .escape;
    if (n2 == 0) return .escape;

    return switch (cmd[0]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end_key,
        'Z' => .shift_tab,
        // Numeric CSI sequences: bracketed paste, delete, CSI u, etc.
        '0'...'9' => parseCsiParamsFromFd(fd, cmd[0]),
        else => .unknown,
    };
}

/// Read a key event from an arbitrary file descriptor.
/// Unlike readKey(), does not poll IPC — suitable for TUI apps
/// that open /dev/tty directly.
/// Returns .resize on EINTR (SIGWINCH), null on EOF/error.
pub fn readKeyFromFd(fd: posix.fd_t) ?Key {
    var key_buf: [1]u8 = undefined;
    const rc = c.read(fd, &key_buf, 1);
    if (rc == -1) return .resize; // EINTR from SIGWINCH
    if (rc <= 0) return null; // EOF

    const byte = key_buf[0];
    return switch (byte) {
        0 => .ctrl_space,
        1 => .ctrl_a,
        2 => .ctrl_b,
        3 => .ctrl_c,
        4 => .ctrl_d,
        5 => .ctrl_e,
        6 => .ctrl_f,
        7 => .ctrl_g,
        8 => .backspace,
        9 => .tab,
        10, 13 => .enter,
        11 => .ctrl_k,
        12 => .ctrl_l,
        14 => .ctrl_n,
        15 => .ctrl_o,
        16 => .ctrl_p,
        18 => .ctrl_r,
        20 => .ctrl_t,
        21 => .ctrl_u,
        22 => .ctrl_v,
        23 => .ctrl_w,
        24 => .ctrl_x,
        25 => .ctrl_y,
        27 => parseEscapeFromFd(fd),
        127 => .backspace,
        32...126 => .{ .char = byte },
        0xC0...0xDF => readUtf8FromFd(fd, byte, 2),
        0xE0...0xEF => readUtf8FromFd(fd, byte, 3),
        0xF0...0xF7 => readUtf8FromFd(fd, byte, 4),
        else => .unknown,
    };
}

/// Parse CSI sequences with numeric parameters: ESC [ <digits> [; <digits>] <final>
/// Handles CSI u (fixterms/kitty keyboard protocol) and extended function keys.
fn parseCsiParams(first_digit: u8) Key {
    return parseCsiParamsFromFd(posix.STDIN_FILENO, first_digit);
}

fn parseCsiParamsFromFd(fd: posix.fd_t, first_digit: u8) Key {
    var param_buf: [16]u8 = undefined;
    param_buf[0] = first_digit;
    var len: usize = 1;

    // Read until we hit a letter (final byte) or overflow
    while (len < param_buf.len) {
        var ch: [1]u8 = undefined;
        const rc = c.read(fd, &ch, 1);
        if (rc <= 0) return .unknown;
        param_buf[len] = ch[0];
        len += 1;
        // Final byte is 0x40-0x7E (letters, ~, u, etc.)
        if (ch[0] >= 0x40 and ch[0] <= 0x7E) break;
    }
    if (len == 0) return .unknown;

    const final = param_buf[len - 1];
    const params = param_buf[0 .. len - 1];

    // CSI u: ESC [ keycode ; modifiers u
    if (final == 'u') {
        // Parse keycode and modifiers
        var keycode: u32 = 0;
        var modifiers: u32 = 0;
        if (std.mem.indexOf(u8, params, ";")) |sep| {
            keycode = parseNum(params[0..sep]);
            modifiers = parseNum(params[sep + 1 ..]);
        } else {
            keycode = parseNum(params);
        }
        return mapCsiU(keycode, modifiers);
    }

    // CSI ~ sequences
    if (final == '~') {
        const code = parseNum(params);
        return switch (code) {
            3 => .delete,
            5 => .page_up, // CSI 5~
            6 => .page_down, // CSI 6~
            200 => .paste_begin,
            201 => .paste_end,
            else => .unknown,
        };
    }

    // Modified arrow keys: CSI 1;mod A/B/C/D
    if (final == 'A' or final == 'B') {
        // Parse modifier: 5=ctrl, 2=shift, 3=alt
        if (std.mem.indexOf(u8, params, ";")) |sep| {
            const modifier = parseNum(params[sep + 1 ..]);
            if (modifier == 5) { // Ctrl
                return if (final == 'A') .ctrl_up else .ctrl_down;
            }
        }
        return if (final == 'A') .up else .down;
    }

    return .unknown;
}

fn parseNum(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') break;
        n = n * 10 + (ch - '0');
    }
    return n;
}

/// Map CSI u keycode + modifiers to a Key.
/// Modifier encoding: 1=none, 2=shift, 3=alt, 5=ctrl, etc.
fn mapCsiU(keycode: u32, modifiers: u32) Key {
    const ctrl = (modifiers > 0) and ((modifiers - 1) & 4 != 0);
    const shift = (modifiers > 0) and ((modifiers - 1) & 1 != 0);
    _ = shift;

    return switch (keycode) {
        32 => if (ctrl) .ctrl_space else .{ .char = ' ' },
        9 => .tab,
        13 => .enter,
        27 => .escape,
        127 => .backspace,
        else => .unknown,
    };
}

/// Parse bracketed paste sequences: ESC [ 2 0 0 ~ (start) / ESC [ 2 0 1 ~ (end).
/// Called after reading ESC [ 2.
fn parseBracketedPaste() Key {
    // We've read ESC [ 2 — expect 0 0 ~ or 0 1 ~
    var seq: [3]u8 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const rc = c.read(posix.STDIN_FILENO, @ptrCast(&seq[i]), 1);
        if (rc <= 0) return .unknown;
    }
    if (seq[0] == '0' and seq[2] == '~') {
        if (seq[1] == '0') return .paste_begin;
        if (seq[1] == '1') return .paste_end;
    }
    return .unknown;
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
