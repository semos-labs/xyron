const std = @import("std");
const environ_mod = @import("../environ.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stderr: std.fs.File, env: *const environ_mod.Environ) Result {
    const target: []const u8 = if (args.len > 0) args[0] else env.home() orelse {
        stderr.writeAll("xyron: cd: HOME not set\n") catch {};
        return .{ .exit_code = 1 };
    };
    std.posix.chdir(target) catch |err| {
        var buf: [512]u8 = undefined;
        stderr.writeAll(std.fmt.bufPrint(&buf, "xyron: cd: {s}: {s}\n", .{ target, @errorName(err) }) catch "xyron: cd: error\n") catch {};
        return .{ .exit_code = 1 };
    };
    return .{};
}
