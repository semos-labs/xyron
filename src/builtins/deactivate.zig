// deactivate — undo the most recent `source`.
//
// Pops the top env snapshot from source_stack and restores the previous
// values (re-setting changed vars, unsetting vars that were created by
// the source). Works for venv / nvm / rbenv style activators whose only
// side effects are env changes.

const std = @import("std");
const environ_mod = @import("../environ.zig");
const source_stack = @import("source_stack.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stderr: std.fs.File, env: *environ_mod.Environ) Result {
    if (args.len > 0 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) {
        stderr.writeAll(
            \\xyron: deactivate: usage: deactivate
            \\
            \\Undoes the most recent `source` by restoring the env snapshot
            \\taken before the script was run.
            \\
        ) catch {};
        return .{};
    }

    var snap = source_stack.pop() orelse {
        stderr.writeAll("xyron: deactivate: nothing to deactivate (no active source)\n") catch {};
        return .{ .exit_code = 1 };
    };
    defer snap.deinit();

    source_stack.restore(&snap, env);
    return .{};
}
