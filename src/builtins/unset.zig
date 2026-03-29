const std = @import("std");
const environ_mod = @import("../environ.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, env: *environ_mod.Environ) Result {
    for (args) |name| env.unset(name);
    return .{};
}
