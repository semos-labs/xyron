const std = @import("std");
const bridge = @import("../attyx_bridge.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File) Result {
    if (args.len == 0) { stdout.writeAll("xyron: popup: usage: popup <text>\n") catch {}; return .{ .exit_code = 1 }; }
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0 and pos < buf.len) { buf[pos] = ' '; pos += 1; }
        const n = @min(arg.len, buf.len - pos);
        @memcpy(buf[pos..][0..n], arg[0..n]);
        pos += n;
    }
    bridge.popup(buf[0..pos], "popup", stdout, std.heap.page_allocator);
    return .{};
}
