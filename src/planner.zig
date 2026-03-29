// planner.zig — Converts an AST into an execution plan.
//
// Assigns group/step IDs, determines pipe wiring, and passes
// environment overrides through for the executor.

const std = @import("std");
const ast = @import("ast.zig");
const environ_mod = @import("environ.zig");
const types = @import("types.zig");

/// One step in an execution plan — corresponds to one process.
pub const PlanStep = struct {
    step_id: u64,
    argv: []const []const u8,
    redirects: []const ast.Redirect,
    env_overrides: []const environ_mod.EnvOverride,
    pipe_stdin: bool,
    pipe_stdout: bool,
};

/// Complete execution plan for one input line.
pub const ExecutionPlan = struct {
    group_id: u64,
    raw_input: []const u8,
    steps: []const PlanStep,
    cwd: []const u8,
    timestamp_ms: i64,
    background: bool = false,

    pub fn isPipeline(self: ExecutionPlan) bool {
        return self.steps.len > 1;
    }

    pub fn deinit(self: *ExecutionPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.steps);
        self.* = .{
            .group_id = 0,
            .raw_input = "",
            .steps = &.{},
            .cwd = "",
            .timestamp_ms = 0,
        };
    }
};

/// Build an execution plan from a parsed pipeline.
pub fn plan(
    allocator: std.mem.Allocator,
    pipeline: *const ast.Pipeline,
    ids: *types.IdGenerator,
    raw_input: []const u8,
    cwd: []const u8,
) !ExecutionPlan {
    const n = pipeline.commands.len;
    const steps = try allocator.alloc(PlanStep, n);

    for (pipeline.commands, 0..) |cmd, i| {
        steps[i] = .{
            .step_id = ids.next(),
            .argv = cmd.argv,
            .redirects = cmd.redirects,
            .env_overrides = cmd.env_overrides,
            .pipe_stdin = i > 0,
            .pipe_stdout = i < n - 1,
        };
    }

    return .{
        .group_id = ids.next(),
        .raw_input = raw_input,
        .steps = steps,
        .cwd = cwd,
        .timestamp_ms = types.timestampMs(),
        .background = pipeline.background,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "plan single command" {
    var ids = types.IdGenerator{};
    const argv = [_][]const u8{"ls"};
    const cmd = ast.SimpleCommand{ .argv = &argv, .redirects = &.{} };
    const commands = [_]ast.SimpleCommand{cmd};
    const pipeline = ast.Pipeline{ .commands = &commands };

    var p = try plan(std.testing.allocator, &pipeline, &ids, "ls", "/tmp");
    defer p.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), p.steps.len);
    try std.testing.expect(!p.isPipeline());
}

test "plan pipeline wires pipes" {
    var ids = types.IdGenerator{};
    const a1 = [_][]const u8{ "cat", "f" };
    const a2 = [_][]const u8{ "grep", "x" };
    const commands = [_]ast.SimpleCommand{
        .{ .argv = &a1, .redirects = &.{} },
        .{ .argv = &a2, .redirects = &.{} },
    };
    const pipeline = ast.Pipeline{ .commands = &commands };

    var p = try plan(std.testing.allocator, &pipeline, &ids, "cat f | grep x", "/tmp");
    defer p.deinit(std.testing.allocator);

    try std.testing.expect(p.steps[0].pipe_stdout);
    try std.testing.expect(p.steps[1].pipe_stdin);
}
