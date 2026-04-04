// builtins/service_cmd.zig — Service CLI commands.
//
// Implements: xyron up, xyron down, xyron restart, xyron ps, xyron logs
// All commands are project-scoped via the active project.

const std = @import("std");
const project = @import("../project/mod.zig");
const svc_mgr = @import("../project/service_manager.zig");
const svc_store = @import("../project/service_store.zig");
const environ_mod = @import("../environ.zig");
const types = @import("../types.zig");
const Result = @import("mod.zig").BuiltinResult;

fn write(f: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    f.writeAll(std.fmt.bufPrint(&buf, fmt, args) catch return) catch {};
}

/// Helper: load project model and resolve context fingerprint.
fn loadProject(allocator: std.mem.Allocator, stderr: std.fs.File) ?struct { mdl: project.ProjectModel, fingerprint: u64 } {
    const load_result = project.loadFromCwd(allocator);
    switch (load_result.status) {
        .not_found => {
            stderr.writeAll("Not in a xyron project\n") catch {};
            return null;
        },
        .invalid => {
            stderr.writeAll("Invalid project config\n") catch {};
            return null;
        },
        .valid => {
            const mdl = load_result.model.?;
            // Resolve context for fingerprint
            const sys_env = buildSystemEnv(allocator);
            const empty_ovr = project.EnvSource{ .keys = &.{}, .values = &.{} };
            const resolved = project.resolver.resolveContext(allocator, &mdl, &sys_env, &empty_ovr);
            return .{ .mdl = mdl, .fingerprint = resolved.fingerprint };
        },
    }
}

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

// =============================================================================
// xyron up [service]
// =============================================================================

pub fn serviceUp(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File, env_inst: *environ_mod.Environ) Result {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const proj = loadProject(allocator, stderr) orelse return .{ .exit_code = 1 };
    const mdl = proj.mdl;

    if (mdl.services.len == 0) {
        stderr.writeAll("No services defined in this project\n") catch {};
        return .{ .exit_code = 1 };
    }

    // Single service or all
    if (args.len > 0) {
        // Start specific service
        for (mdl.services) |svc| {
            if (std.mem.eql(u8, svc.name, args[0])) {
                const result = svc_mgr.startOne(allocator, &mdl, &svc, &env_inst.map, proj.fingerprint);
                printOpResult(stdout, &result);
                return .{ .exit_code = if (result.success) 0 else 1 };
            }
        }
        write(stderr, "Unknown service: {s}\n", .{args[0]});
        return .{ .exit_code = 1 };
    }

    // Start all
    var results: [svc_store.max_services]svc_mgr.ServiceOpResult = undefined;
    const count = svc_mgr.startAll(allocator, &mdl, &env_inst.map, proj.fingerprint, &results);
    var any_failed = false;
    for (results[0..count]) |*r| {
        printOpResult(stdout, r);
        if (!r.success) any_failed = true;
    }
    return .{ .exit_code = if (any_failed) 1 else 0 };
}

// =============================================================================
// xyron down
// =============================================================================

pub fn serviceDown(stdout: std.fs.File, stderr: std.fs.File) Result {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const load_result = project.loadFromCwd(allocator);
    if (load_result.status != .valid) {
        stderr.writeAll("Not in a valid xyron project\n") catch {};
        return .{ .exit_code = 1 };
    }
    const mdl = load_result.model.?;

    var results: [svc_store.max_services]svc_mgr.ServiceOpResult = undefined;
    const count = svc_mgr.stopAll(mdl.project_id, &results);
    if (count == 0) {
        stdout.writeAll("No services running\n") catch {};
        return .{};
    }
    for (results[0..count]) |*r| {
        printOpResult(stdout, r);
    }
    return .{};
}

// =============================================================================
// xyron restart <service>
// =============================================================================

pub fn serviceRestart(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File, env_inst: *environ_mod.Environ) Result {
    if (args.len == 0) {
        stderr.writeAll("Usage: xyron restart <service>\n") catch {};
        return .{ .exit_code = 1 };
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const proj = loadProject(allocator, stderr) orelse return .{ .exit_code = 1 };
    const result = svc_mgr.restartOne(allocator, &proj.mdl, args[0], &env_inst.map, proj.fingerprint);
    printOpResult(stdout, &result);
    return .{ .exit_code = if (result.success) 0 else 1 };
}

// =============================================================================
// xyron ps
// =============================================================================

pub fn servicePs(stdout: std.fs.File, stderr: std.fs.File) Result {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const load_result = project.loadFromCwd(allocator);
    if (load_result.status != .valid) {
        stderr.writeAll("Not in a valid xyron project\n") catch {};
        return .{ .exit_code = 1 };
    }
    const mdl = load_result.model.?;

    const store = svc_store.getStore();
    store.refreshStates();

    if (mdl.services.len == 0) {
        stdout.writeAll("No services defined\n") catch {};
        return .{};
    }

    // Print header
    stdout.writeAll("\x1b[1mServices\x1b[0m\n") catch {};

    // For each declared service, show its state
    for (mdl.services) |svc| {
        const inst = store.find(mdl.project_id, svc.name);
        if (inst) |i| {
            const state_style: []const u8 = switch (i.state) {
                .running => "\x1b[32m",
                .failed => "\x1b[31m",
                .starting => "\x1b[33m",
                .stopped => "\x1b[2m",
            };
            const stale = if (i.state == .running and i.context_fingerprint != 0) blk: {
                // Check staleness by resolving current context
                const sys_env = buildSystemEnv(allocator);
                const empty_ovr = project.EnvSource{ .keys = &.{}, .values = &.{} };
                const resolved = project.resolver.resolveContext(allocator, &mdl, &sys_env, &empty_ovr);
                break :blk if (resolved.fingerprint != i.context_fingerprint) " \x1b[33m(stale)\x1b[0m" else "";
            } else "";

            write(stdout, "  {s}●\x1b[0m {s}  {s}{s}\x1b[0m  \x1b[2mpid {d}\x1b[0m{s}\n", .{
                state_style, svc.name, state_style, i.state.label(), i.pid, stale,
            });
        } else {
            write(stdout, "  \x1b[2m○\x1b[0m {s}  \x1b[2mstopped\x1b[0m\n", .{svc.name});
        }
    }

    return .{};
}

// =============================================================================
// xyron logs <service>
// =============================================================================

pub fn serviceLogs(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) {
        stderr.writeAll("Usage: xyron logs <service>\n") catch {};
        return .{ .exit_code = 1 };
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const load_result = project.loadFromCwd(allocator);
    if (load_result.status != .valid) {
        stderr.writeAll("Not in a valid xyron project\n") catch {};
        return .{ .exit_code = 1 };
    }
    const mdl = load_result.model.?;

    const content = svc_mgr.readLogs(allocator, mdl.project_id, args[0], 65536) orelse {
        write(stderr, "No logs for service: {s}\n", .{args[0]});
        return .{ .exit_code = 1 };
    };

    stdout.writeAll(content) catch {};
    // Ensure trailing newline
    if (content.len > 0 and content[content.len - 1] != '\n') {
        stdout.writeAll("\n") catch {};
    }
    return .{};
}

// =============================================================================
// Helpers
// =============================================================================

fn printOpResult(stdout: std.fs.File, r: *const svc_mgr.ServiceOpResult) void {
    if (r.success) {
        write(stdout, "  \x1b[32m●\x1b[0m {s}  {s}\n", .{ r.service_name, r.message });
    } else {
        write(stdout, "  \x1b[31m✗\x1b[0m {s}  {s}\n", .{ r.service_name, r.message });
    }
}
