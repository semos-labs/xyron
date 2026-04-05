// builtins/project_cmd.zig — `xyron project` subcommand.
//
// Subcommands:
//   xyron project info       Show project info (root, commands, env, services)
//   xyron project context    Show resolved context (env values, provenance, secrets)

const std = @import("std");
const project = @import("../project/mod.zig");
const runner = @import("../project/runner.zig");
const term = @import("../term.zig");
const environ_mod = @import("../environ.zig");
const Result = @import("mod.zig").BuiltinResult;
pub const service_cmd = @import("service_cmd.zig");

// Service command re-exports
pub const serviceUp = service_cmd.serviceUp;
pub const serviceDown = service_cmd.serviceDown;
pub const serviceRestart = service_cmd.serviceRestart;
pub const servicePs = service_cmd.servicePs;
pub const serviceLogs = service_cmd.serviceLogs;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) return runInfo(stdout, stderr);
    if (std.mem.eql(u8, args[0], "info")) return runInfo(stdout, stderr);
    if (std.mem.eql(u8, args[0], "context")) return runContext(stdout, stderr);
    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) return runHelp(stdout);
    stderr.writeAll("xyron project: unknown subcommand. Try `xyron project help`\n") catch {};
    return .{ .exit_code = 1 };
}

fn runHelp(stdout: std.fs.File) Result {
    stdout.writeAll(
        \\xyron project — project management
        \\
        \\Commands:
        \\  xyron project info       Show project info
        \\  xyron project context    Show resolved context
        \\  xyron project help       Show this help
        \\
    ) catch {};
    return .{};
}

fn write(stdout: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    stdout.writeAll(std.fmt.bufPrint(&buf, fmt, args) catch return) catch {};
}

// =============================================================================
// xyron project info
// =============================================================================

fn runInfo(stdout: std.fs.File, stderr: std.fs.File) Result {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = project.loadFromCwd(allocator);

    switch (result.status) {
        .not_found => {
            stderr.writeAll("Not in a xyron project\n") catch {};
            return .{ .exit_code = 1 };
        },
        .invalid => {
            printInvalid(stdout, &result);
            return .{ .exit_code = 1 };
        },
        .valid => {
            printValid(stdout, &result);
            return .{};
        },
    }
}

fn printInvalid(stdout: std.fs.File, result: *const project.ProjectModelLoadResult) void {
    write(stdout, "\x1b[1mProject\x1b[0m  {s}\n", .{result.resolution.project_root orelse "unknown"});
    stdout.writeAll("\x1b[31mStatus\x1b[0m   invalid\n\n") catch {};

    if (result.errors.len > 0) {
        stdout.writeAll("\x1b[31mErrors:\x1b[0m\n") catch {};
        for (result.errors) |err| {
            write(stdout, "  \x1b[31m✗\x1b[0m {s}\n", .{err});
        }
    }

    if (result.warnings.len > 0) {
        stdout.writeAll("\n\x1b[33mWarnings:\x1b[0m\n") catch {};
        for (result.warnings) |warn| {
            write(stdout, "  \x1b[33m!\x1b[0m {s}\n", .{warn});
        }
    }
}

fn printValid(stdout: std.fs.File, result: *const project.ProjectModelLoadResult) void {
    const mdl = result.model.?;

    // Header
    if (mdl.project.name) |name| {
        write(stdout, "\x1b[1mProject\x1b[0m  {s}\n", .{name});
    }
    write(stdout, "\x1b[2mRoot\x1b[0m     {s}\n", .{mdl.root_path});

    // Commands
    if (mdl.commands.len > 0) {
        stdout.writeAll("\n\x1b[1mCommands\x1b[0m\n") catch {};
        for (mdl.commands) |cmd| {
            write(stdout, "  \x1b[32m▸\x1b[0m {s}  \x1b[2m{s}\x1b[0m\n", .{ cmd.name, cmd.command });
        }
    }

    // Env sources
    if (mdl.env.sources.len > 0) {
        stdout.writeAll("\n\x1b[1mEnv sources\x1b[0m\n") catch {};
        for (mdl.env.sources) |src| {
            write(stdout, "  \x1b[34m●\x1b[0m {s}\n", .{src});
        }
    }

    // Secrets
    if (mdl.secrets.required.len > 0) {
        stdout.writeAll("\n\x1b[1mRequired secrets\x1b[0m\n") catch {};
        for (mdl.secrets.required) |key| {
            write(stdout, "  \x1b[33m◆\x1b[0m {s}\n", .{key});
        }
    }

    // Services
    if (mdl.services.len > 0) {
        stdout.writeAll("\n\x1b[1mServices\x1b[0m\n") catch {};
        for (mdl.services) |svc| {
            write(stdout, "  \x1b[35m◉\x1b[0m {s}  \x1b[2m{s}\x1b[0m\n", .{ svc.name, svc.command });
        }
    }

    // Warnings
    if (result.warnings.len > 0) {
        stdout.writeAll("\n\x1b[33mWarnings:\x1b[0m\n") catch {};
        for (result.warnings) |warn| {
            write(stdout, "  \x1b[33m!\x1b[0m {s}\n", .{warn});
        }
    }
}

// =============================================================================
// xyron project context
// =============================================================================

fn runContext(stdout: std.fs.File, stderr: std.fs.File) Result {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const load_result = project.loadFromCwd(allocator);

    switch (load_result.status) {
        .not_found => {
            stderr.writeAll("Not in a xyron project\n") catch {};
            return .{ .exit_code = 1 };
        },
        .invalid => {
            printInvalid(stdout, &load_result);
            return .{ .exit_code = 1 };
        },
        .valid => {},
    }

    const mdl = load_result.model.?;

    // Build system env source from current process environment
    const sys_env = buildSystemEnv(allocator);

    const empty_ovr = project.EnvSource{ .keys = &.{}, .values = &.{} };
    const resolved = project.resolver.resolveContext(allocator, &mdl, &sys_env, &empty_ovr);

    printContext(stdout, &resolved);
    return .{};
}

/// Capture the current process environment as an EnvSource.
fn buildSystemEnv(allocator: std.mem.Allocator) project.EnvSource {
    const env_map = std.process.getEnvMap(allocator) catch {
        return .{ .keys = &.{}, .values = &.{} };
    };

    var keys: std.ArrayListUnmanaged([]const u8) = .{};
    var vals: std.ArrayListUnmanaged([]const u8) = .{};

    var iter = env_map.iterator();
    while (iter.next()) |entry| {
        keys.append(allocator, entry.key_ptr.*) catch {};
        vals.append(allocator, entry.value_ptr.*) catch {};
    }

    return .{
        .keys = keys.toOwnedSlice(allocator) catch &.{},
        .values = vals.toOwnedSlice(allocator) catch &.{},
    };
}

fn printContext(stdout: std.fs.File, resolved: *const project.ResolvedContext) void {
    // Header
    if (resolved.project_name) |name| {
        write(stdout, "\x1b[1mProject\x1b[0m  {s}\n", .{name});
    }
    write(stdout, "\x1b[2mRoot\x1b[0m     {s}\n", .{resolved.project_root});
    write(stdout, "\x1b[2mFprint\x1b[0m   {x}\n", .{resolved.fingerprint});

    // Env sources
    if (resolved.env_sources.len > 0) {
        stdout.writeAll("\n\x1b[1mSources\x1b[0m\n") catch {};
        for (resolved.env_sources) |src| {
            const status_icon: []const u8 = switch (src.status) {
                .loaded => "\x1b[32m●\x1b[0m",
                .file_not_found => "\x1b[33m○\x1b[0m",
                .read_error => "\x1b[31m✗\x1b[0m",
                .parse_error => "\x1b[31m✗\x1b[0m",
            };
            const kind_label: []const u8 = switch (src.source_kind) {
                .system => "system",
                .env_file => "file",
                .manifest => "manifest",
                .override => "override",
            };
            write(stdout, "  {s} {s}  \x1b[2m{s} ({d} keys)\x1b[0m\n", .{
                status_icon, src.source_name, kind_label, src.loaded_keys.len,
            });
        }
    }

    // Project env values (from env files only, not all system env)
    var project_key_count: usize = 0;
    for (resolved.provenance.keys(), resolved.provenance.values()) |_, prov| {
        if (prov.winner_source != .system) {
            project_key_count += 1;
        }
    }
    if (project_key_count > 0) {
        stdout.writeAll("\n\x1b[1mProject env\x1b[0m\n") catch {};
        for (resolved.provenance.keys(), resolved.provenance.values()) |key, prov| {
            if (prov.winner_source == .system) continue;
            const source_label: []const u8 = switch (prov.winner_source) {
                .env_file => prov.winner_source_name,
                .manifest => "xyron.toml",
                .override => "override",
                .system => "system",
            };
            // Truncate long values
            const val = if (prov.final_value.len > 40)
                prov.final_value[0..40]
            else
                prov.final_value;
            const suffix: []const u8 = if (prov.final_value.len > 40) "…" else "";
            const override_mark: []const u8 = if (prov.was_overridden) " \x1b[33m⚡\x1b[0m" else "";
            write(stdout, "  \x1b[36m{s}\x1b[0m = {s}{s}  \x1b[2m← {s}\x1b[0m{s}\n", .{
                key, val, suffix, source_label, override_mark,
            });
        }
    }

    // Missing secrets
    if (resolved.missing_required.len > 0) {
        stdout.writeAll("\n\x1b[31mMissing required secrets\x1b[0m\n") catch {};
        for (resolved.missing_required) |key| {
            write(stdout, "  \x1b[31m✗\x1b[0m {s}\n", .{key});
        }
    }

    // Summary
    stdout.writeAll("\n") catch {};
    write(stdout, "\x1b[2mTotal keys: {d}  |  Project keys: {d}  |  Missing: {d}\x1b[0m\n", .{
        resolved.values.count(),
        project_key_count,
        resolved.missing_required.len,
    });

    // Warnings
    if (resolved.warnings.len > 0) {
        stdout.writeAll("\n\x1b[33mWarnings:\x1b[0m\n") catch {};
        for (resolved.warnings) |warn| {
            write(stdout, "  \x1b[33m!\x1b[0m {s}\n", .{warn});
        }
    }
}

// =============================================================================
// xyron run <command>
// =============================================================================

pub fn runCommand(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File, env_inst: *environ_mod.Environ) Result {
    if (args.len == 0) {
        return runCommandHelp(stdout, stderr);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const command_name = args[0];

    // Load project from cwd
    const load_result = project.loadFromCwd(allocator);

    const mdl: ?project.ProjectModel = switch (load_result.status) {
        .not_found => {
            stderr.writeAll("Not in a xyron project\n") catch {};
            return .{ .exit_code = 1 };
        },
        .invalid => {
            write(stderr, "\x1b[31mInvalid project config\x1b[0m\n", .{});
            for (load_result.errors) |err| {
                write(stderr, "  \x1b[31m✗\x1b[0m {s}\n", .{err});
            }
            return .{ .exit_code = 1 };
        },
        .valid => load_result.model,
    };

    // Resolve command
    const resolve_result = runner.resolveCommand(allocator, mdl, command_name);

    switch (resolve_result) {
        .err => |e| {
            write(stderr, "\x1b[31m{s}\x1b[0m\n", .{e.message});
            if (e.kind == .command_not_found and e.available_commands.len > 0) {
                stderr.writeAll("\nAvailable commands:\n") catch {};
                for (e.available_commands) |cmd| {
                    write(stdout, "  \x1b[32m▸\x1b[0m {s}  \x1b[2m{s}\x1b[0m\n", .{ cmd.name, cmd.command });
                }
            }
            return .{ .exit_code = 1 };
        },
        .ok => |resolved| {
            // Execute the command with shell's env (includes project overlay)
            term.suspendRawMode();
            const exec_result = runner.execute(allocator, &resolved.command, resolved.abs_cwd, mdl.?.project_id, &env_inst.map);
            term.resumeRawMode();

            return .{ .exit_code = exec_result.exit_code };
        },
    }
}

fn runCommandHelp(stdout: std.fs.File, stderr: std.fs.File) Result {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Try to show available commands from current project
    const load_result = project.loadFromCwd(allocator);
    if (load_result.status == .valid) {
        const mdl = load_result.model.?;
        if (mdl.commands.len > 0) {
            stdout.writeAll("Usage: xyron run <command>\n\nAvailable commands:\n") catch {};
            for (mdl.commands) |cmd| {
                write(stdout, "  \x1b[32m▸\x1b[0m {s}  \x1b[2m{s}\x1b[0m\n", .{ cmd.name, cmd.command });
            }
            return .{};
        }
    }

    stderr.writeAll("Usage: xyron run <command>\n") catch {};
    return .{ .exit_code = 1 };
}
