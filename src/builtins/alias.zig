const std = @import("std");
const aliases_mod = @import("../aliases.zig");
const rich = @import("../rich_output.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) {
        if (aliases_mod.aliasCount() == 0) return .{};
        var tbl = rich.Table{};
        tbl.addColumn(.{ .header = "alias", .color = "\x1b[1;33m" });
        tbl.addColumn(.{ .header = "command", .color = "\x1b[37m" });
        for (0..aliases_mod.aliasCount()) |i| {
            const r = tbl.addRow();
            tbl.setCell(r, 0, aliases_mod.nameAt(i));
            tbl.setCell(r, 1, aliases_mod.expansionAt(i));
        }
        tbl.render(stdout);
        return .{};
    }
    for (args) |arg| {
        if (std.mem.indexOf(u8, arg, "=")) |eq| {
            aliases_mod.set(arg[0..eq], arg[eq + 1 ..]);
        } else {
            if (aliases_mod.get(arg)) |expansion| {
                var buf: [1024]u8 = undefined;
                stdout.writeAll(std.fmt.bufPrint(&buf, "{s} -> {s}\n", .{ arg, expansion }) catch "") catch {};
            } else {
                var buf: [256]u8 = undefined;
                stderr.writeAll(std.fmt.bufPrint(&buf, "xyron: alias: {s}: not found\n", .{arg}) catch "") catch {};
            }
        }
    }
    return .{};
}
