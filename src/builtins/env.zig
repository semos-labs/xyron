const std = @import("std");
const posix = std.posix;
const environ_mod = @import("../environ.zig");
const rich = @import("../rich_output.zig");
const pj = @import("../pipe_json.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(stdout: std.fs.File, env: *const environ_mod.Environ) Result {
    var key_buf: [256][]const u8 = undefined;
    var count: usize = 0;
    var iter = env.map.iterator();
    while (iter.next()) |entry| {
        if (count >= 256) break;
        key_buf[count] = entry.key_ptr.*;
        count += 1;
    }
    std.mem.sort([]const u8, key_buf[0..count], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    // JSON output when piped
    if (!pj.isTerminal(posix.STDOUT_FILENO)) {
        var buf: [65536]u8 = undefined;
        var pos: usize = 0;
        if (pos < buf.len) { buf[pos] = '['; pos += 1; }
        for (key_buf[0..count], 0..) |key, i| {
            if (i > 0 and pos < buf.len) { buf[pos] = ','; pos += 1; }
            const val = env.get(key) orelse "";
            const written = std.fmt.bufPrint(buf[pos..], "{{\"variable\":\"{s}\",\"value\":\"{s}\"}}", .{ key, val }) catch break;
            pos += written.len;
        }
        if (pos < buf.len) { buf[pos] = ']'; pos += 1; }
        stdout.writeAll(buf[0..pos]) catch {};
        return .{};
    }

    var tbl = rich.Table{};
    tbl.addColumn(.{ .header = "variable", .color = "\x1b[1;36m" });
    tbl.addColumn(.{ .header = "value", .color = "\x1b[37m" });

    for (key_buf[0..count]) |key| {
        const val = env.get(key) orelse "";
        const r = tbl.addRow();
        tbl.setCell(r, 0, key);
        if (val.len > 80) {
            var trunc: [83]u8 = undefined;
            @memcpy(trunc[0..80], val[0..80]);
            trunc[80] = '.'; trunc[81] = '.'; trunc[82] = '.';
            tbl.setCell(r, 1, trunc[0..83]);
        } else {
            tbl.setCell(r, 1, val);
        }
    }
    tbl.render(stdout);
    return .{};
}
