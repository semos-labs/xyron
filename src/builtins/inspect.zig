const std = @import("std");
const bridge = @import("../attyx_bridge.zig");
const history_db_mod = @import("../history_db.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, hdb: ?*history_db_mod.HistoryDb) Result {
    if (args.len == 0) { stdout.writeAll("xyron: inspect: usage: inspect <history|env|attyx>\n") catch {}; return .{ .exit_code = 1 }; }
    if (bridge.runInspect(args, stdout, hdb)) return .{};
    var buf: [256]u8 = undefined;
    stdout.writeAll(std.fmt.bufPrint(&buf, "xyron: inspect: unknown kind: {s}\n", .{args[0]}) catch "") catch {};
    return .{ .exit_code = 1 };
}
