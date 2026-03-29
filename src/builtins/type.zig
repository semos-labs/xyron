const std = @import("std");
const environ_mod = @import("../environ.zig");
const path_search = @import("../path_search.zig");
const mod = @import("mod.zig");
const Result = mod.BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File, env: *const environ_mod.Environ) Result {
    if (args.len == 0) {
        stderr.writeAll("xyron: type: usage: type command\n") catch {};
        return .{ .exit_code = 1 };
    }
    const name = args[0];
    var buf: [1024]u8 = undefined;
    if (mod.isBuiltin(name)) {
        stdout.writeAll(std.fmt.bufPrint(&buf, "{s} is a shell builtin\n", .{name}) catch "") catch {};
        return .{};
    }
    const result = path_search.findInPath(std.heap.page_allocator, name, env) catch return .{ .exit_code = 1 };
    if (result) |path| {
        defer std.heap.page_allocator.free(path);
        stdout.writeAll(std.fmt.bufPrint(&buf, "{s} is {s}\n", .{ name, path }) catch "") catch {};
        return .{};
    }
    stderr.writeAll(std.fmt.bufPrint(&buf, "xyron: type: {s} not found\n", .{name}) catch "") catch {};
    return .{ .exit_code = 1 };
}
