// jobs.zig — Job tracking system with process group support.
//
// Tracks background and foreground jobs with states: running, stopped,
// completed. Supports suspension (Ctrl+Z), resume (fg/bg), and
// background reaping.

const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");

pub const MAX_JOBS: usize = 64;
pub const MAX_PIDS: usize = 32;
pub const MAX_INPUT: usize = 256;

pub const JobState = enum {
    running,
    stopped,
    completed,

    pub fn label(self: JobState) []const u8 {
        return switch (self) {
            .running => "Running",
            .stopped => "Stopped",
            .completed => "Done",
        };
    }
};

pub const Job = struct {
    id: u32,
    group_id: u64,
    raw_input: [MAX_INPUT]u8,
    raw_len: usize,
    pids: [MAX_PIDS]posix.pid_t,
    pid_count: usize,
    pgid: posix.pid_t, // process group ID for signaling
    state: JobState,
    exit_code: u8,
    start_time: i64,
    end_time: i64,
    background: bool,

    pub fn rawInputSlice(self: *const Job) []const u8 {
        return self.raw_input[0..self.raw_len];
    }

    /// Resume this job: send SIGCONT then SIGWINCH to force redraw.
    pub fn cont(self: *Job) void {
        for (self.pids[0..self.pid_count]) |pid| {
            posix.kill(pid, posix.SIG.CONT) catch {};
        }
        // Force programs to redraw by sending SIGWINCH
        for (self.pids[0..self.pid_count]) |pid| {
            posix.kill(pid, posix.SIG.WINCH) catch {};
        }
        self.state = .running;
    }
};

pub const JobTable = struct {
    jobs: [MAX_JOBS]Job = undefined,
    count: usize = 0,
    next_id: u32 = 1,
    /// PID of the currently active foreground job's process group.
    fg_pgid: posix.pid_t = 0,

    /// Create a new job. Returns the job ID.
    pub fn createJob(
        self: *JobTable,
        group_id: u64,
        raw_input: []const u8,
        pids: []const posix.pid_t,
        pgid: posix.pid_t,
        background: bool,
    ) ?u32 {
        if (self.count >= MAX_JOBS) {
            self.compact();
            if (self.count >= MAX_JOBS) return null;
        }

        const id = self.next_id;
        self.next_id += 1;

        var job = &self.jobs[self.count];
        job.* = .{
            .id = id,
            .group_id = group_id,
            .raw_input = undefined,
            .raw_len = @min(raw_input.len, MAX_INPUT),
            .pids = undefined,
            .pid_count = @min(pids.len, MAX_PIDS),
            .pgid = pgid,
            .state = .running,
            .exit_code = 0,
            .start_time = types.timestampMs(),
            .end_time = 0,
            .background = background,
        };
        @memcpy(job.raw_input[0..job.raw_len], raw_input[0..job.raw_len]);
        for (pids[0..job.pid_count], 0..) |pid, i| job.pids[i] = pid;

        self.count += 1;
        return id;
    }

    /// Reap completed background jobs (non-blocking).
    pub fn reapCompleted(self: *JobTable) ReapResult {
        var result = ReapResult{};

        for (self.jobs[0..self.count]) |*job| {
            if (job.state != .running or !job.background) continue;

            var all_done = true;
            var last_code: u8 = 0;

            for (job.pids[0..job.pid_count]) |pid| {
                const wait = posix.waitpid(pid, posix.W.NOHANG);
                if (wait.pid == 0) {
                    all_done = false;
                } else {
                    last_code = extractExitCode(wait.status);
                }
            }

            if (all_done) {
                job.state = .completed;
                job.exit_code = last_code;
                job.end_time = types.timestampMs();
                if (result.count < ReapResult.MAX) {
                    result.ids[result.count] = job.id;
                    result.count += 1;
                }
            }
        }
        return result;
    }

    pub fn findById(self: *JobTable, id: u32) ?*Job {
        for (self.jobs[0..self.count]) |*job| {
            if (job.id == id) return job;
        }
        return null;
    }

    /// Find the most recent job that is running or stopped.
    pub fn findLastActive(self: *JobTable) ?*Job {
        var i = self.count;
        while (i > 0) {
            i -= 1;
            if (self.jobs[i].state == .running or self.jobs[i].state == .stopped) {
                return &self.jobs[i];
            }
        }
        return null;
    }

    /// Find the most recent stopped job (for bg).
    pub fn findLastStopped(self: *JobTable) ?*Job {
        var i = self.count;
        while (i > 0) {
            i -= 1;
            if (self.jobs[i].state == .stopped) return &self.jobs[i];
        }
        return null;
    }

    fn compact(self: *JobTable) void {
        var write: usize = 0;
        for (0..self.count) |read| {
            if (self.jobs[read].state != .completed) {
                if (write != read) self.jobs[write] = self.jobs[read];
                write += 1;
            }
        }
        self.count = write;
    }

    pub fn allJobs(self: *const JobTable) []const Job {
        return self.jobs[0..self.count];
    }
};

pub const ReapResult = struct {
    const MAX: usize = 16;
    ids: [MAX]u32 = undefined,
    count: usize = 0,
};

fn extractExitCode(status: u32) u8 {
    const W = posix.W;
    if (W.IFEXITED(status)) return W.EXITSTATUS(status);
    if (W.IFSIGNALED(status)) return 128 +| @as(u8, @truncate(W.TERMSIG(status)));
    return 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "create and find job" {
    var table = JobTable{};
    const pids = [_]posix.pid_t{123};
    const id = table.createJob(1, "sleep 10", &pids, 123, true);
    try std.testing.expect(id != null);

    const job = table.findById(1);
    try std.testing.expect(job != null);
    try std.testing.expectEqualStrings("sleep 10", job.?.rawInputSlice());
    try std.testing.expectEqual(JobState.running, job.?.state);
}

test "find last stopped" {
    var table = JobTable{};
    const pids = [_]posix.pid_t{100};
    _ = table.createJob(1, "job1", &pids, 100, true);
    _ = table.createJob(2, "job2", &pids, 200, true);

    // Stop the first job
    table.jobs[0].state = .stopped;

    const stopped = table.findLastStopped();
    try std.testing.expect(stopped != null);
    try std.testing.expectEqualStrings("job1", stopped.?.rawInputSlice());
}

test "compact removes completed" {
    var table = JobTable{};
    const pids = [_]posix.pid_t{100};
    _ = table.createJob(1, "done", &pids, 100, true);
    _ = table.createJob(2, "running", &pids, 200, true);

    table.jobs[0].state = .completed;
    table.compact();

    try std.testing.expectEqual(@as(usize, 1), table.count);
}

test "job state labels" {
    try std.testing.expectEqualStrings("Running", JobState.running.label());
    try std.testing.expectEqualStrings("Stopped", JobState.stopped.label());
    try std.testing.expectEqualStrings("Done", JobState.completed.label());
}
