const std = @import("std");
const posix = std.posix;
const rich = @import("../rich_output.zig");
const pj = @import("../pipe_json.zig");
const jobs_mod = @import("../jobs.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(stdout: std.fs.File, job_table: ?*jobs_mod.JobTable) Result {
    const jt = job_table orelse return .{};
    const all = jt.allJobs();
    if (all.len == 0) return .{};

    // JSON output when piped
    if (!pj.isTerminal(posix.STDOUT_FILENO)) {
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;
        if (pos < buf.len) { buf[pos] = '['; pos += 1; }
        for (all, 0..) |*job, i| {
            if (i > 0 and pos < buf.len) { buf[pos] = ','; pos += 1; }
            const written = std.fmt.bufPrint(buf[pos..], "{{\"id\":{d},\"state\":\"{s}\",\"command\":\"{s}\"}}", .{ job.id, job.state.label(), job.rawInputSlice() }) catch break;
            pos += written.len;
        }
        if (pos < buf.len) { buf[pos] = ']'; pos += 1; }
        stdout.writeAll(buf[0..pos]) catch {};
        return .{};
    }

    var tbl = rich.Table{};
    tbl.addColumn(.{ .header = "id", .align_ = .right, .color = "\x1b[1;37m" });
    tbl.addColumn(.{ .header = "state", .color = "" });
    tbl.addColumn(.{ .header = "command", .color = "\x1b[37m" });

    for (all) |*job| {
        const r = tbl.addRow();
        var id_buf: [8]u8 = undefined;
        tbl.setCell(r, 0, std.fmt.bufPrint(&id_buf, "{d}", .{job.id}) catch "?");
        const sc: []const u8 = switch (job.state) { .running => "\x1b[32m", .stopped => "\x1b[33m", .completed => "\x1b[2m" };
        tbl.setCellColor(r, 1, job.state.label(), sc);
        tbl.setCell(r, 2, job.rawInputSlice());
    }
    tbl.render(stdout);
    return .{};
}
