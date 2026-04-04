// project/runner.zig — Project command runner.
//
// Resolves and executes commands defined in xyron.toml.
// Always uses the active project context (env already applied by Phase 3).
// This module is a consumer of ProjectModel and the shell's Environ —
// it does NOT parse manifests or merge env.

const std = @import("std");
const model = @import("model.zig");
const types = @import("../types.zig");

// =============================================================================
// Execution result
// =============================================================================

pub const ExecutionResult = struct {
    command_name: []const u8,
    command_string: []const u8,
    cwd: []const u8,
    project_id: []const u8,
    start_time: i64,
    end_time: i64,
    exit_code: u8,
    success: bool,
    error_msg: ?[]const u8 = null,
};

// =============================================================================
// Command resolution errors
// =============================================================================

pub const ResolveError = enum {
    no_project,
    invalid_project,
    command_not_found,
    cwd_invalid,
    spawn_failed,
};

pub const ResolveResult = union(enum) {
    ok: struct {
        command: model.Command,
        abs_cwd: []const u8,
    },
    err: struct {
        kind: ResolveError,
        message: []const u8,
        available_commands: []const model.Command,
    },
};

/// Resolve a command name against the project model.
/// Returns the command definition and absolute cwd, or an error.
pub fn resolveCommand(
    allocator: std.mem.Allocator,
    project_model: ?model.ProjectModel,
    command_name: []const u8,
) ResolveResult {
    const mdl = project_model orelse {
        return .{ .err = .{
            .kind = .no_project,
            .message = "not in a xyron project",
            .available_commands = &.{},
        } };
    };

    // Find the command
    for (mdl.commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, command_name)) {
            // Resolve cwd to absolute path
            const abs_cwd = if (std.fs.path.isAbsolute(cmd.cwd))
                cmd.cwd
            else
                std.fs.path.join(allocator, &.{ mdl.root_path, cmd.cwd }) catch cmd.cwd;

            // Validate cwd exists
            var dir = std.fs.openDirAbsolute(abs_cwd, .{}) catch {
                return .{ .err = .{
                    .kind = .cwd_invalid,
                    .message = std.fmt.allocPrint(
                        allocator,
                        "working directory does not exist: {s}",
                        .{abs_cwd},
                    ) catch "working directory does not exist",
                    .available_commands = mdl.commands,
                } };
            };
            dir.close();

            return .{ .ok = .{
                .command = cmd,
                .abs_cwd = abs_cwd,
            } };
        }
    }

    return .{ .err = .{
        .kind = .command_not_found,
        .message = std.fmt.allocPrint(
            allocator,
            "unknown command: {s}",
            .{command_name},
        ) catch "unknown command",
        .available_commands = mdl.commands,
    } };
}

/// Execute a resolved command. Runs via /bin/sh -c with the shell's env.
/// The shell's Environ already has the project overlay applied (Phase 3).
///
/// `env_map` is the shell's EnvMap — used to set the child process environment.
/// Returns a structured ExecutionResult.
pub fn execute(
    allocator: std.mem.Allocator,
    command: *const model.Command,
    abs_cwd: []const u8,
    project_id: []const u8,
    env_map: ?*const std.process.EnvMap,
) ExecutionResult {
    const start_time = types.timestampMs();

    // Build the /bin/sh -c command
    var cmd_buf: [8192]u8 = undefined;
    const sh_cmd = std.fmt.bufPrintZ(&cmd_buf, "{s}", .{command.command}) catch {
        return .{
            .command_name = command.name,
            .command_string = command.command,
            .cwd = abs_cwd,
            .project_id = project_id,
            .start_time = start_time,
            .end_time = types.timestampMs(),
            .exit_code = 127,
            .success = false,
            .error_msg = "command too long",
        };
    };

    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", sh_cmd },
        allocator,
    );
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    // Set working directory
    child.cwd = abs_cwd;

    // Set environment from shell's Environ (includes project overlay)
    child.env_map = env_map;

    child.spawn() catch {
        return .{
            .command_name = command.name,
            .command_string = command.command,
            .cwd = abs_cwd,
            .project_id = project_id,
            .start_time = start_time,
            .end_time = types.timestampMs(),
            .exit_code = 127,
            .success = false,
            .error_msg = "failed to spawn process",
        };
    };

    const term_result = child.wait() catch {
        return .{
            .command_name = command.name,
            .command_string = command.command,
            .cwd = abs_cwd,
            .project_id = project_id,
            .start_time = start_time,
            .end_time = types.timestampMs(),
            .exit_code = 127,
            .success = false,
            .error_msg = "failed to wait for process",
        };
    };

    const code: u8 = switch (term_result) {
        .Exited => |c| c,
        else => 1,
    };

    return .{
        .command_name = command.name,
        .command_string = command.command,
        .cwd = abs_cwd,
        .project_id = project_id,
        .start_time = start_time,
        .end_time = types.timestampMs(),
        .exit_code = code,
        .success = code == 0,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "resolveCommand finds command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cmds = [_]model.Command{
        .{ .name = "dev", .command = "npm run dev", .cwd = "/tmp" },
        .{ .name = "test", .command = "npm test", .cwd = "/tmp" },
    };
    const mdl = model.ProjectModel{
        .root_path = "/tmp",
        .project_id = "/tmp",
        .commands = &cmds,
    };

    const result = resolveCommand(arena.allocator(), mdl, "dev");
    switch (result) {
        .ok => |r| {
            try std.testing.expectEqualStrings("dev", r.command.name);
            try std.testing.expectEqualStrings("npm run dev", r.command.command);
        },
        .err => return error.TestUnexpectedResult,
    }
}

test "resolveCommand not found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cmds = [_]model.Command{
        .{ .name = "dev", .command = "npm run dev", .cwd = "/tmp" },
    };
    const mdl = model.ProjectModel{
        .root_path = "/tmp",
        .project_id = "/tmp",
        .commands = &cmds,
    };

    const result = resolveCommand(arena.allocator(), mdl, "nonexistent");
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| {
            try std.testing.expectEqual(ResolveError.command_not_found, e.kind);
            try std.testing.expectEqual(@as(usize, 1), e.available_commands.len);
        },
    }
}

test "resolveCommand no project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = resolveCommand(arena.allocator(), null, "dev");
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| try std.testing.expectEqual(ResolveError.no_project, e.kind),
    }
}

test "resolveCommand invalid cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cmds = [_]model.Command{
        .{ .name = "dev", .command = "echo hi", .cwd = "/nonexistent_dir_12345" },
    };
    const mdl = model.ProjectModel{
        .root_path = "/tmp",
        .project_id = "/tmp",
        .commands = &cmds,
    };

    const result = resolveCommand(arena.allocator(), mdl, "dev");
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| try std.testing.expectEqual(ResolveError.cwd_invalid, e.kind),
    }
}

test "execute runs simple command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cmd = model.Command{
        .name = "echo",
        .command = "true",
        .cwd = "/tmp",
    };

    const result = execute(arena.allocator(), &cmd, "/tmp", "/tmp", null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(result.success);
    try std.testing.expect(result.error_msg == null);
}

test "execute captures nonzero exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cmd = model.Command{
        .name = "fail",
        .command = "false",
        .cwd = "/tmp",
    };

    const result = execute(arena.allocator(), &cmd, "/tmp", "/tmp", null);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(!result.success);
}
