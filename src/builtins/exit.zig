const std = @import("std");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8) Result {
    var code: u8 = 0;
    if (args.len > 0) code = std.fmt.parseInt(u8, args[0], 10) catch 1;
    return .{ .exit_code = code, .should_exit = true };
}
