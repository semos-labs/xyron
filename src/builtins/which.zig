const std = @import("std");
const environ_mod = @import("../environ.zig");
const path_search = @import("../path_search.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File, env: *const environ_mod.Environ) Result {
    if (args.len == 0) {
        stderr.writeAll("xyron: which: usage: which command\n") catch {};
        return .{ .exit_code = 1 };
    }
    const result = path_search.findInPath(std.heap.page_allocator, args[0], env) catch return .{ .exit_code = 1 };
    if (result) |path| {
        defer std.heap.page_allocator.free(path);
        stdout.writeAll(path) catch {};
        stdout.writeAll("\n") catch {};
        return .{};
    }
    var buf: [512]u8 = undefined;
    stderr.writeAll(std.fmt.bufPrint(&buf, "xyron: which: {s} not found\n", .{args[0]}) catch "") catch {};
    return .{ .exit_code = 1 };
}
