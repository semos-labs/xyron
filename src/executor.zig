// executor.zig — Runs execution plans: foreground and background.
//
// Foreground jobs stay in the shell's process group so Ctrl+Z
// naturally delivers SIGTSTP to them. Background jobs get their
// own process group to avoid receiving terminal signals.

const std = @import("std");
const posix = std.posix;
const ast = @import("ast.zig");
const environ_mod = @import("environ.zig");
const planner_mod = @import("planner.zig");
const types = @import("types.zig");
const builtins = @import("builtins.zig");
const attyx_mod = @import("attyx.zig");
const history_db_mod = @import("history_db.zig");
const jobs_mod = @import("jobs.zig");

const MAX_PIPELINE: usize = 32;

pub const GroupResult = struct {
    exit_code: u8,
    duration_ms: i64,
    should_exit: bool = false,
    pids: [MAX_PIPELINE]posix.pid_t = undefined,
    pid_count: usize = 0,
    pgid: posix.pid_t = 0,
    backgrounded: bool = false,
    stopped: bool = false,
};

/// Shell's own pgid (for background process group setup).
var shell_pgid: posix.pid_t = 0;

pub fn initShellPgid() void {
    shell_pgid = std.c.getpid();
}

pub fn executeGroup(
    exec_plan: *const planner_mod.ExecutionPlan,
    ax: *const attyx_mod.Attyx,
    env: *environ_mod.Environ,
    hdb: ?*history_db_mod.HistoryDb,
    job_table: ?*jobs_mod.JobTable,
) GroupResult {
    const start = types.timestampMs();
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    ax.groupStarted(exec_plan);

    if (exec_plan.steps.len == 1) {
        const step = &exec_plan.steps[0];

        // Bare assignment
        if (step.argv.len == 0 and step.env_overrides.len > 0) {
            ax.stepStarted(exec_plan, step);
            for (step.env_overrides) |ov| env.set(ov.key, ov.value) catch {};
            ax.stepFinished(exec_plan, step, 0, 0);
            ax.groupFinished(exec_plan, 0, types.timestampMs() - start);
            return .{ .exit_code = 0, .duration_ms = types.timestampMs() - start };
        }

        // In-process builtin (not background)
        if (step.argv.len > 0 and builtins.isBuiltin(step.argv[0]) and !exec_plan.background) {
            ax.stepStarted(exec_plan, step);
            const result = builtins.execute(step.argv, stdout, stderr, env, hdb, job_table);
            // 255 = sentinel meaning "not handled, fall through to external"
            if (result.exit_code != 255) {
                ax.stepFinished(exec_plan, step, result.exit_code, 0);
                ax.groupFinished(exec_plan, result.exit_code, types.timestampMs() - start);
                return .{
                    .exit_code = result.exit_code,
                    .duration_ms = types.timestampMs() - start,
                    .should_exit = result.should_exit,
                };
            }
            // Fall through to external execution
        }
    }

    var result = forkPipeline(exec_plan, ax, env, exec_plan.background);

    if (exec_plan.background) {
        ax.groupFinished(exec_plan, 0, 0);
        result.backgrounded = true;
        result.duration_ms = 0;
        return result;
    }

    // Foreground: wait (WUNTRACED to detect Ctrl+Z)
    const final = waitForForeground(exec_plan, ax, &result);
    result.exit_code = final.exit_code;
    result.stopped = final.stopped;
    result.duration_ms = types.timestampMs() - start;

    if (!final.stopped) {
        ax.groupFinished(exec_plan, final.exit_code, result.duration_ms);
    }
    return result;
}

/// Wait for a specific job (used by fg builtin).
pub fn waitForJobFg(job: *jobs_mod.Job) jobs_mod.JobState {
    if (job.state != .running) return job.state;

    var last_code: u8 = 0;
    var was_stopped = false;
    const W = posix.W;

    for (job.pids[0..job.pid_count]) |pid| {
        const result = posix.waitpid(pid, W.UNTRACED);
        if (result.pid == 0) continue;
        if (W.IFSTOPPED(result.status)) {
            was_stopped = true;
        } else {
            last_code = extractExitCode(result.status);
        }
    }

    if (was_stopped) {
        job.state = .stopped;
        return .stopped;
    }

    job.state = .completed;
    job.exit_code = last_code;
    job.end_time = types.timestampMs();
    return .completed;
}

// ---------------------------------------------------------------------------
// Fork pipeline
// ---------------------------------------------------------------------------

fn forkPipeline(
    exec_plan: *const planner_mod.ExecutionPlan,
    ax: *const attyx_mod.Attyx,
    env: *environ_mod.Environ,
    background: bool,
) GroupResult {
    var result = GroupResult{ .exit_code = 0, .duration_ms = 0 };
    const steps = exec_plan.steps;
    const n = steps.len;
    if (n == 0 or n > MAX_PIPELINE) return result;

    var envp_result = env.toEnvp(std.heap.page_allocator) catch return result;
    defer envp_result.deinit();

    var pipes: [MAX_PIPELINE - 1][2]posix.fd_t = undefined;
    for (0..n - 1) |i| pipes[i] = posix.pipe2(.{ .CLOEXEC = true }) catch return result;

    var pgid: posix.pid_t = 0;

    for (steps, 0..) |*step, i| {
        ax.stepStarted(exec_plan, step);

        var step_envp_result: ?environ_mod.EnvpResult = null;
        if (step.env_overrides.len > 0) {
            var tmp = env.cloneWithOverrides(std.heap.page_allocator, step.env_overrides) catch continue;
            defer tmp.deinit();
            step_envp_result = tmp.toEnvp(std.heap.page_allocator) catch continue;
        }
        defer if (step_envp_result) |*r| r.deinit();

        const effective_envp = if (step_envp_result) |*r| r.envp() else envp_result.envp();

        const pid = posix.fork() catch {
            ax.stepFinished(exec_plan, step, 127, 0);
            continue;
        };

        if (pid == 0) {
            // Child: background jobs get their own process group
            if (background) {
                const tgt = if (pgid == 0) @as(posix.pid_t, 0) else pgid;
                posix.setpgid(0, tgt) catch {};
            }
            childExec(steps, &pipes, n, i, effective_envp);
        }

        // Parent: set pgid for background jobs
        if (background) {
            if (i == 0) pgid = pid;
            posix.setpgid(pid, pgid) catch {};
        }

        if (result.pid_count < MAX_PIPELINE) {
            result.pids[result.pid_count] = pid;
            result.pid_count += 1;
        }
    }

    result.pgid = if (background) pgid else shell_pgid;

    for (0..n - 1) |i| {
        posix.close(pipes[i][0]);
        posix.close(pipes[i][1]);
    }

    return result;
}

const WaitResult = struct { exit_code: u8, stopped: bool };

fn waitForForeground(
    exec_plan: *const planner_mod.ExecutionPlan,
    ax: *const attyx_mod.Attyx,
    result: *const GroupResult,
) WaitResult {
    var last_code: u8 = 0;
    var was_stopped = false;
    const steps = exec_plan.steps;
    const W = posix.W;

    for (0..result.pid_count) |i| {
        const step_start = types.timestampMs();
        const wait = posix.waitpid(result.pids[i], W.UNTRACED);
        if (wait.pid == 0) continue;

        if (W.IFSTOPPED(wait.status)) {
            was_stopped = true;
        } else {
            last_code = extractExitCode(wait.status);
            if (i < steps.len) {
                ax.stepFinished(exec_plan, &steps[i], last_code, types.timestampMs() - step_start);
            }
        }
    }

    return .{ .exit_code = last_code, .stopped = was_stopped };
}

// ---------------------------------------------------------------------------
// Child process setup
// ---------------------------------------------------------------------------

fn childExec(
    steps: []const planner_mod.PlanStep,
    pipes_ptr: *const [MAX_PIPELINE - 1][2]posix.fd_t,
    n: usize,
    i: usize,
    envp: [*:null]const ?[*:0]const u8,
) void {
    // Reset signals to default for child
    const dfl_act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &dfl_act, null);
    posix.sigaction(posix.SIG.TSTP, &dfl_act, null);
    posix.sigaction(posix.SIG.TTIN, &dfl_act, null);
    posix.sigaction(posix.SIG.TTOU, &dfl_act, null);

    if (i > 0) posix.dup2(pipes_ptr[i - 1][0], posix.STDIN_FILENO) catch std.process.exit(126);
    if (i < n - 1) posix.dup2(pipes_ptr[i][1], posix.STDOUT_FILENO) catch std.process.exit(126);

    applyRedirects(steps[i].redirects);

    for (0..n - 1) |j| {
        posix.close(pipes_ptr[j][0]);
        posix.close(pipes_ptr[j][1]);
    }

    const argv = steps[i].argv;

    // Pipe-friendly builtins: run in-process in the forked child
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "json")) {
        const json_cmd = @import("builtins/json.zig");
        json_cmd.runFromPipe(if (argv.len > 1) argv[1..] else &.{});
        // runFromPipe calls exit, but just in case:
        std.process.exit(0);
    }

    var argv_buf: [256]?[*:0]const u8 = undefined;
    if (argv.len >= argv_buf.len) std.process.exit(127);
    for (argv, 0..) |arg, k| argv_buf[k] = toZ(arg);
    argv_buf[argv.len] = null;

    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);
    const err = posix.execvpeZ(argv_buf[0].?, argv_ptr, envp);
    _ = posix.write(posix.STDERR_FILENO, "xyron: ") catch {};
    _ = posix.write(posix.STDERR_FILENO, argv[0]) catch {};
    _ = posix.write(posix.STDERR_FILENO, ": ") catch {};
    _ = posix.write(posix.STDERR_FILENO, @errorName(err)) catch {};
    _ = posix.write(posix.STDERR_FILENO, "\n") catch {};
    std.process.exit(127);
}

fn applyRedirects(redirects: []const ast.Redirect) void {
    for (redirects) |redir| {
        const path_z = toZ(redir.path) orelse continue;
        switch (redir.kind) {
            .stdout => {
                const fd = posix.openZ(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch continue;
                posix.dup2(fd, posix.STDOUT_FILENO) catch {};
                posix.close(fd);
            },
            .stderr => {
                const fd = posix.openZ(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch continue;
                posix.dup2(fd, posix.STDERR_FILENO) catch {};
                posix.close(fd);
            },
            .stdin => {
                const fd = posix.openZ(path_z, .{ .ACCMODE = .RDONLY }, 0o0) catch continue;
                posix.dup2(fd, posix.STDIN_FILENO) catch {};
                posix.close(fd);
            },
        }
    }
}

fn toZ(s: []const u8) ?[*:0]const u8 {
    if (s.len > 0 and s.ptr[s.len] == 0) return @ptrCast(s.ptr);
    const S = struct { var bufs: [256][256]u8 = undefined; var next: usize = 0; };
    if (s.len >= 255 or S.next >= S.bufs.len) return null;
    const idx = S.next;
    S.next += 1;
    @memcpy(S.bufs[idx][0..s.len], s);
    S.bufs[idx][s.len] = 0;
    return @ptrCast(&S.bufs[idx]);
}

fn extractExitCode(status: u32) u8 {
    const W = posix.W;
    if (W.IFEXITED(status)) return W.EXITSTATUS(status);
    if (W.IFSIGNALED(status)) return 128 +| @as(u8, @truncate(W.TERMSIG(status)));
    return 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "extractExitCode" {
    try std.testing.expectEqual(@as(u8, 0), extractExitCode(0));
    try std.testing.expectEqual(@as(u8, 42), extractExitCode(42 << 8));
}
