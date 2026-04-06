// title.zig — Terminal title (OSC 0) management.
//
// Sets the terminal tab/window title so terminals can display
// the current command or working directory. Works in any terminal
// that supports OSC 0 (virtually all of them).

const std = @import("std");

const stderr = std.fs.File.stderr();

/// Set title to show the running command (first argv element + args).
pub fn setCommand(argv: []const []const u8) void {
    if (argv.len == 0) return;
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    pos += copy(buf[pos..], "\x1b]0;");
    // Use basename of the command
    const cmd = std.fs.path.basename(argv[0]);
    pos += copy(buf[pos..], cmd);
    // Append first few args for context (up to ~80 chars visible)
    for (argv[1..]) |arg| {
        if (pos > 100) break;
        pos += copy(buf[pos..], " ");
        pos += copy(buf[pos..], arg);
    }
    pos += copy(buf[pos..], "\x07");
    stderr.writeAll(buf[0..pos]) catch {};
}

/// Set title to idle state showing the cwd.
pub fn setIdle(cwd: []const u8) void {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    pos += copy(buf[pos..], "\x1b]0;xyron: ");
    // Shorten home prefix to ~
    if (std.posix.getenv("HOME")) |home| {
        if (std.mem.startsWith(u8, cwd, home)) {
            pos += copy(buf[pos..], "~");
            pos += copy(buf[pos..], cwd[home.len..]);
        } else {
            pos += copy(buf[pos..], cwd);
        }
    } else {
        pos += copy(buf[pos..], cwd);
    }
    pos += copy(buf[pos..], "\x07");
    stderr.writeAll(buf[0..pos]) catch {};
}

fn copy(dest: []u8, src: []const u8) usize {
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "setCommand does not panic on empty argv" {
    setCommand(&.{});
}

test "setIdle does not panic" {
    setIdle("/tmp");
}
