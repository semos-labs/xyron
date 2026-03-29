const std = @import("std");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(stdout: std.fs.File, stderr: std.fs.File) Result {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&buf) catch {
        stderr.writeAll("xyron: pwd: unable to get current directory\n") catch {};
        return .{ .exit_code = 1 };
    };
    stdout.writeAll(cwd) catch {};
    stdout.writeAll("\n") catch {};
    return .{};
}
