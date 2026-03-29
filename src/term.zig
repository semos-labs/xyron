// term.zig — Terminal raw mode handling.
//
// Saves the original terminal state exactly once on first enable.
// All subsequent raw mode activations use that saved state as the
// base, so even if a child process (vim, less) corrupts the terminal,
// we always restore from the known-good original.

const std = @import("std");
const posix = std.posix;
const c = std.c;

var orig_termios: c.termios = undefined;
var raw_mode_active: bool = false;
var orig_saved: bool = false;

/// Enable raw terminal mode.
/// Saves the original terminal state only on the first call.
pub fn enableRawMode() !void {
    if (!orig_saved) {
        orig_termios = try posix.tcgetattr(posix.STDIN_FILENO);
        orig_saved = true;
    }

    // Always build raw mode from the saved original — never from
    // whatever state a child process may have left behind.
    var raw = orig_termios;

    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;

    raw.oflag.OPOST = false;

    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.cflag.CSIZE = .CS8;

    raw.cc[@intFromEnum(c.V.MIN)] = 1;
    raw.cc[@intFromEnum(c.V.TIME)] = 0;

    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    raw_mode_active = true;
}

/// Restore original terminal mode.
pub fn disableRawMode() void {
    if (raw_mode_active and orig_saved) {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig_termios) catch {};
        raw_mode_active = false;
    }
}

/// Suspend raw mode for child execution. Restores the clean original state.
pub fn suspendRawMode() void {
    if (raw_mode_active and orig_saved) {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig_termios) catch {};
    }
}

/// Re-enable raw mode after child execution.
pub fn resumeRawMode() void {
    if (raw_mode_active) {
        enableRawMode() catch {};
    }
}

/// Force-restore the saved original terminal attributes.
/// Used after child processes that may have corrupted terminal state.
pub fn restoreOriginal() void {
    if (orig_saved) {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig_termios) catch {};
    }
}

pub fn isRawMode() bool {
    return raw_mode_active;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "enableRawMode and disableRawMode do not crash on non-terminal" {
    enableRawMode() catch return;
    disableRawMode();
}
