const std = @import("std");
const environ_mod = @import("../environ.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stderr: std.fs.File, env: *environ_mod.Environ) Result {
    if (args.len == 0) {
        stderr.writeAll("xyron: export: usage: export NAME=value\n") catch {};
        return .{ .exit_code = 1 };
    }
    for (args) |arg| {
        if (std.mem.indexOf(u8, arg, "=")) |eq| {
            env.set(arg[0..eq], arg[eq + 1 ..]) catch return .{ .exit_code = 1 };
        }
    }
    return .{};
}
