const std = @import("std");
const environ_mod = @import("../environ.zig");
const rich = @import("../rich_output.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(stdout: std.fs.File, env: *const environ_mod.Environ) Result {
    var tbl = rich.Table{};
    tbl.addColumn(.{ .header = "variable", .color = "\x1b[1;36m" });
    tbl.addColumn(.{ .header = "value", .color = "\x1b[37m" });

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
