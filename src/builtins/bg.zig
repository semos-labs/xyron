const std = @import("std");
const jobs_mod = @import("../jobs.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File, job_table: ?*jobs_mod.JobTable) Result {
    const table = job_table orelse { stderr.writeAll("xyron: bg: no job table\n") catch {}; return .{ .exit_code = 1 }; };
    const job = if (args.len > 0) blk: {
        const id = std.fmt.parseInt(u32, args[0], 10) catch { stderr.writeAll("xyron: bg: invalid job id\n") catch {}; return .{ .exit_code = 1 }; };
        break :blk table.findById(id);
    } else table.findLastStopped();

    if (job) |j| {
        if (j.state != .stopped) { stderr.writeAll("xyron: bg: job is not stopped\n") catch {}; return .{ .exit_code = 1 }; }
        j.cont();
        j.background = true;
        var buf: [256]u8 = undefined;
        stdout.writeAll(std.fmt.bufPrint(&buf, "[{d}]  {s} &\n", .{ j.id, j.rawInputSlice() }) catch "") catch {};
        return .{};
    }
    stderr.writeAll("xyron: bg: no stopped job\n") catch {};
    return .{ .exit_code = 1 };
}
