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
const block_ui = @import("block_ui.zig");
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

        // In-process builtin (not background) — capture output unless interactive
        if (step.argv.len > 0 and builtins.isBuiltin(step.argv[0]) and !exec_plan.background
            and !isInteractiveBuiltin(step.argv))
        {
            ax.stepStarted(exec_plan, step);

            const pipe_fds = posix.pipe2(.{}) catch [2]posix.fd_t{ -1, -1 };
            if (pipe_fds[0] >= 0) blk: {
                const write_end = std.fs.File{ .handle = pipe_fds[1] };
                const read_end = std.fs.File{ .handle = pipe_fds[0] };

                const result = builtins.execute(step.argv, write_end, stderr, env, hdb, job_table);
                posix.close(pipe_fds[1]);

                if (result.exit_code == 255) {
                    posix.close(pipe_fds[0]);
                    break :blk; // not handled — fall through to external
                }

                // Read captured output
                var cap_buf: [65536]u8 = undefined;
                var cap_total: usize = 0;
                while (cap_total < cap_buf.len) {
                    const n = read_end.read(cap_buf[cap_total..]) catch break;
                    if (n == 0) break;
                    cap_total += n;
                }
                posix.close(pipe_fds[0]);

                var output = cap_buf[0..cap_total];
                while (output.len > 0 and output[output.len - 1] == '\n') output = output[0 .. output.len - 1];

                block_ui.last_duration_ms = types.timestampMs() - start;

                if (block_ui.enabled) {
                    // Block mode: render with borders
                    var cmd_disp: [256]u8 = undefined;
                    var cmd_len: usize = 0;
                    for (step.argv, 0..) |arg, ai| {
                        if (ai > 0 and cmd_len < cmd_disp.len) { cmd_disp[cmd_len] = ' '; cmd_len += 1; }
                        const n = @min(arg.len, cmd_disp.len - cmd_len);
                        @memcpy(cmd_disp[cmd_len..][0..n], arg[0..n]);
                        cmd_len += n;
                    }
                    block_ui.renderBlock(stdout, cmd_disp[0..cmd_len], output, result.exit_code);
                } else {
                    // Non-block: print raw, store for overlay restoration
                    if (output.len > 0) {
                        stdout.writeAll(output) catch {};
                        stdout.writeAll("\n") catch {};
                    }
                    block_ui.storeOutputOnly(exec_plan.raw_input, output, result.exit_code);
                }

                const dur = types.timestampMs() - start;
                ax.stepFinished(exec_plan, step, result.exit_code, dur);
                ax.groupFinished(exec_plan, result.exit_code, dur);
                return .{ .exit_code = result.exit_code, .duration_ms = dur, .should_exit = result.should_exit };
            }
            // Fall through to external execution
        }

        // Interactive builtins: run with direct stdout (no capture)
        if (step.argv.len > 0 and isInteractiveBuiltin(step.argv)) {
            ax.stepStarted(exec_plan, step);
            const result = builtins.execute(step.argv, stdout, stderr, env, hdb, job_table);
            const dur = types.timestampMs() - start;
            ax.stepFinished(exec_plan, step, result.exit_code, dur);
            ax.groupFinished(exec_plan, result.exit_code, dur);
            return .{ .exit_code = result.exit_code, .duration_ms = dur, .should_exit = result.should_exit };
        }
    }

    // Block UI: capture output and render bordered block.
    // Single external commands use /bin/sh. Pipelines and commands with
    // builtins use forkPipeline with stdout captured to a pipe.
    if (block_ui.enabled and !exec_plan.background and exec_plan.steps.len >= 1) {
        const last_step = &exec_plan.steps[exec_plan.steps.len - 1];
        if (!block_ui.isPassthrough(last_step.argv)) {
            // Check if any step is a builtin (can't delegate to /bin/sh)
            var has_builtin = false;
            for (exec_plan.steps) |*s| {
                if (s.argv.len > 0 and (builtins.isBuiltin(s.argv[0]) or std.mem.eql(u8, s.argv[0], "json"))) {
                    has_builtin = true;
                    break;
                }
            }

            // Check if last step is a pipe builtin that renders its own table.
            // If so, skip block UI capture — let it render directly.
            const last_is_pipe_builtin = if (last_step.argv.len > 0) isPipeBuiltin(last_step.argv[0]) else false;

            if (last_is_pipe_builtin) {
                // Pipeline ends with where/select/sort/csv/json — skip block capture,
                // use regular forkPipeline. Last command renders table to terminal.
            } else if (exec_plan.steps.len == 1 and !has_builtin) {
                // Single external command — use /bin/sh path
                const step0 = &exec_plan.steps[0];
                ax.stepStarted(exec_plan, step0);
                block_ui.last_duration_ms = types.timestampMs() - start;
                const code = block_ui.runAndRender(exec_plan.raw_input, exec_plan.steps, stdout);
                const dur = types.timestampMs() - start;
                ax.stepFinished(exec_plan, step0, code, dur);
                ax.groupFinished(exec_plan, code, dur);
                return .{ .exit_code = code, .duration_ms = dur };
            } else {
                // Pipeline or has builtins — fork pipeline with stdout capture
                block_ui.last_duration_ms = types.timestampMs() - start;
                const code = block_ui.forkAndRender(exec_plan, ax, env, stdout);
                const dur = types.timestampMs() - start;
                ax.groupFinished(exec_plan, code, dur);
                return .{ .exit_code = code, .duration_ms = dur };
            }
        }
    }

    // Non-block mode: capture single external commands for overlay restoration
    if (!block_ui.enabled and !exec_plan.background and exec_plan.steps.len == 1) {
        const step0 = &exec_plan.steps[0];
        if (step0.argv.len > 0 and !block_ui.isPassthrough(step0.argv) and !isPipeBuiltin(step0.argv[0])) {
            ax.stepStarted(exec_plan, step0);
            block_ui.last_duration_ms = types.timestampMs() - start;
            const code = block_ui.runCaptureAndPrintRaw(exec_plan.raw_input, exec_plan.steps, stdout);
            const dur = types.timestampMs() - start;
            ax.stepFinished(exec_plan, step0, code, dur);
            ax.groupFinished(exec_plan, code, dur);
            return .{ .exit_code = code, .duration_ms = dur };
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

/// Public wrapper for block UI pipeline capture.
pub fn forkPipelineForBlock(
    exec_plan: *const planner_mod.ExecutionPlan,
    ax: *const attyx_mod.Attyx,
    env: *environ_mod.Environ,
) GroupResult {
    return forkPipeline(exec_plan, ax, env, false);
}

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

/// Pipe builtins that render their own tables — skip block UI capture.
/// Builtins that need direct stdout (interactive I/O, TUI, prompts).
fn isInteractiveBuiltin(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const name = argv[0];
    return std.mem.eql(u8, name, "xyron") or
        std.mem.eql(u8, name, "fz") or
        std.mem.eql(u8, name, "jump");
}

/// Pipe builtins that render their own tables — skip block UI capture.
fn isPipeBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "where") or
        std.mem.eql(u8, name, "select") or
        std.mem.eql(u8, name, "sort") or
        std.mem.eql(u8, name, "csv") or
        std.mem.eql(u8, name, "json") or
        std.mem.eql(u8, name, "to_json") or
        std.mem.eql(u8, name, "query");
}

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
        std.process.exit(0);
    }
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "query")) {
        const query_cmd = @import("builtins/query.zig");
        query_cmd.runFromPipe(if (argv.len > 1) argv[1..] else &.{});
        std.process.exit(0);
    }
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "select")) {
        @import("builtins/select.zig").runFromPipe(if (argv.len > 1) argv[1..] else &.{});
        std.process.exit(0);
    }
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "where")) {
        @import("builtins/where.zig").runFromPipe(if (argv.len > 1) argv[1..] else &.{});
        std.process.exit(0);
    }
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "sort")) {
        @import("builtins/sort_cmd.zig").runFromPipe(if (argv.len > 1) argv[1..] else &.{});
        std.process.exit(0);
    }
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "csv")) {
        @import("builtins/csv.zig").runFromPipe(if (argv.len > 1) argv[1..] else &.{});
        std.process.exit(0);
    }
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "to_json")) {
        @import("builtins/to_json.zig").runFromPipe(if (argv.len > 1) argv[1..] else &.{});
        std.process.exit(0);
    }
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "fz")) {
        @import("builtins/fz.zig").runFromPipe(if (argv.len > 1) argv[1..] else &.{});
        std.process.exit(0);
    }
    if (argv.len > 0 and (std.mem.eql(u8, argv[0], "jump") or std.mem.eql(u8, argv[0], "j"))) {
        const jump_mod = @import("builtins/jump.zig");
        // Re-open the database in the child — SQLite handles don't survive fork()
        jump_mod.deinitDb();
        jump_mod.initDb(std.heap.page_allocator);
        const stdout_f = std.fs.File{ .handle = posix.STDOUT_FILENO };
        const stderr_f = std.fs.File{ .handle = posix.STDERR_FILENO };
        const args = if (argv.len > 1) argv[1..] else &[_][]const u8{};
        const r = if (std.mem.eql(u8, argv[0], "j"))
            jump_mod.runJ(args, stderr_f)
        else
            jump_mod.run(args, stdout_f, stderr_f);
        std.process.exit(r.exit_code);
    }

    // Structured builtins: run in-process.
    // Output JSON only if next step is a xyron pipe builtin; otherwise text.
    if (argv.len > 0) {
        const name = argv[0];
        // Check if next pipeline step expects structured (JSON) input
        const next_wants_json = if (i + 1 < n and steps[i + 1].argv.len > 0)
            isPipeBuiltin(steps[i + 1].argv[0])
        else
            false;

        if (std.mem.eql(u8, name, "ls") or std.mem.eql(u8, name, "ll")) {
            // Set flag so ls knows whether to output JSON or table
            const pj_mod = @import("pipe_json.zig");
            pj_mod.output_mode = if (next_wants_json) .json else .text;

            const ls_mod = @import("builtins/ls.zig");
            const stdout_file = std.fs.File{ .handle = posix.STDOUT_FILENO };
            if (std.mem.eql(u8, name, "ll")) {
                _ = ls_mod.run(&.{"-la"}, stdout_file);
            } else {
                _ = ls_mod.run(if (argv.len > 1) argv[1..] else &.{}, stdout_file);
            }
            std.process.exit(0);
        }
        if (std.mem.eql(u8, name, "ps")) {
            const pj_mod = @import("pipe_json.zig");
            pj_mod.output_mode = if (next_wants_json) .json else .text;

            const ps_mod = @import("builtins/ps.zig");
            _ = ps_mod.run(if (argv.len > 1) argv[1..] else &.{}, std.fs.File{ .handle = posix.STDOUT_FILENO });
            std.process.exit(0);
        }
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
