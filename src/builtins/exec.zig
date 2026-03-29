const std = @import("std");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stderr: std.fs.File) Result {
    if (args.len == 0) {
        stderr.writeAll("xyron: exec: usage: exec command [args...]\n") catch {};
        return .{ .exit_code = 1 };
    }
    var cmd_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0 and pos < cmd_buf.len) { cmd_buf[pos] = ' '; pos += 1; }
        const n = @min(arg.len, cmd_buf.len - pos);
        @memcpy(cmd_buf[pos..][0..n], arg[0..n]);
        pos += n;
    }
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd_buf[0..pos] }, std.heap.page_allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return .{ .exit_code = 127 };
    const term = child.wait() catch return .{ .exit_code = 127 };
    return .{ .exit_code = switch (term) { .Exited => |c| c, else => 1 } };
}
