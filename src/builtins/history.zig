const std = @import("std");
const rich = @import("../rich_output.zig");
const history_db_mod = @import("../history_db.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, hdb: ?*history_db_mod.HistoryDb) Result {
    const db = hdb orelse { stdout.writeAll("xyron: history: no database\n") catch {}; return .{ .exit_code = 1 }; };

    var limit: usize = 25;
    if (args.len > 0) limit = std.fmt.parseInt(usize, args[0], 10) catch 25;

    var entries: [100]history_db_mod.HistoryEntry = undefined;
    var str_buf: [100 * 256]u8 = undefined;
    const count = db.recentEntries(entries[0..@min(limit, 100)], &str_buf);

    var tbl = rich.Table{};
    tbl.addColumn(.{ .header = "#", .align_ = .right, .color = "\x1b[2m" });
    tbl.addColumn(.{ .header = "command", .color = "" });
    tbl.addColumn(.{ .header = "exit", .align_ = .right, .color = "" });

    var i = count;
    while (i > 0) {
        i -= 1;
        const r = tbl.addRow();
        var id_buf: [16]u8 = undefined;
        tbl.setCell(r, 0, std.fmt.bufPrint(&id_buf, "{d}", .{entries[i].id}) catch "?");
        tbl.setCell(r, 1, entries[i].raw_input);
        var code_buf: [8]u8 = undefined;
        tbl.setCellColor(r, 2, std.fmt.bufPrint(&code_buf, "{d}", .{entries[i].exit_code}) catch "?", if (entries[i].exit_code == 0) "\x1b[32m" else "\x1b[31m");
    }
    tbl.render(stdout);
    return .{};
}
