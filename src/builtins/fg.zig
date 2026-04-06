const std = @import("std");
const jobs_mod = @import("../jobs.zig");
const executor = @import("../executor.zig");
const term_mod = @import("../term.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File, job_table: ?*jobs_mod.JobTable) Result {
    const table = job_table orelse { stderr.writeAll("xyron: fg: no job table\n") catch {}; return .{ .exit_code = 1 }; };
    const job = if (args.len > 0) blk: {
        const id = std.fmt.parseInt(u32, args[0], 10) catch { stderr.writeAll("xyron: fg: invalid job id\n") catch {}; return .{ .exit_code = 1 }; };
        break :blk table.findById(id);
    } else table.findLastActive();

    if (job) |j| {
        if (j.state == .completed) { stderr.writeAll("xyron: fg: job has already completed\n") catch {}; return .{ .exit_code = 1 }; }
        var buf: [256]u8 = undefined;
        stdout.writeAll(std.fmt.bufPrint(&buf, "{s}\n", .{j.rawInputSlice()}) catch "") catch {};
        term_mod.suspendRawMode();
        // Give terminal control to the job's process group before resuming.
        executor.giveTerminal(j.pgid);
        if (j.state == .stopped) j.cont();
        const state = executor.waitForJobFg(j);
        // waitForJobFg calls takeTerminal() to reclaim the terminal.
        term_mod.resumeRawMode();
        if (state == .stopped) return .{ .exit_code = 148 };
        return .{ .exit_code = j.exit_code };
    }
    stderr.writeAll("xyron: fg: no current job\n") catch {};
    return .{ .exit_code = 1 };
}
