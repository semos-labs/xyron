// project/service_manager.zig — Service lifecycle manager.
//
// Starts, stops, and restarts project-defined services as detached
// background processes. Uses the context engine for env, the service
// store for persistence, and log files for output capture.

const std = @import("std");
const model = @import("model.zig");
const store_mod = @import("service_store.zig");
const resolver = @import("resolver.zig");
const loader = @import("loader.zig");
const types = @import("../types.zig");

/// Result of a service operation.
pub const ServiceOpResult = struct {
    service_name: []const u8,
    success: bool,
    message: []const u8 = "",
};

// =============================================================================
// Start
// =============================================================================

/// Start all services for a project.
pub fn startAll(
    allocator: std.mem.Allocator,
    mdl: *const model.ProjectModel,
    env_map: ?*const std.process.EnvMap,
    fingerprint: u64,
    results: []ServiceOpResult,
) usize {
    var count: usize = 0;
    for (mdl.services) |svc| {
        if (count >= results.len) break;
        results[count] = startOne(allocator, mdl, &svc, env_map, fingerprint);
        count += 1;
    }
    return count;
}

/// Start a single service.
pub fn startOne(
    allocator: std.mem.Allocator,
    mdl: *const model.ProjectModel,
    svc: *const model.Service,
    env_map: ?*const std.process.EnvMap,
    fingerprint: u64,
) ServiceOpResult {
    const store = store_mod.getStore();

    // Check if already running
    if (store.find(mdl.project_id, svc.name)) |existing| {
        if (existing.state == .running and existing.isProcessAlive()) {
            return .{
                .service_name = svc.name,
                .success = true,
                .message = "already running",
            };
        }
    }

    // Resolve cwd
    const abs_cwd = if (std.fs.path.isAbsolute(svc.cwd))
        svc.cwd
    else
        std.fs.path.join(allocator, &.{ mdl.root_path, svc.cwd }) catch svc.cwd;

    // Validate cwd
    {
        var dir = std.fs.openDirAbsolute(abs_cwd, .{}) catch {
            return .{ .service_name = svc.name, .success = false, .message = "cwd does not exist" };
        };
        dir.close();
    }

    // Prepare log file
    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = makeLogPath(&log_path_buf, mdl.project_id, svc.name) orelse {
        return .{ .service_name = svc.name, .success = false, .message = "cannot create log path" };
    };

    // Ensure log directory exists (recursive)
    if (std.mem.lastIndexOfScalar(u8, log_path, '/')) |sep| {
        makePathRecursive(log_path[0..sep]);
    }

    const log_file = std.fs.createFileAbsolute(log_path, .{ .truncate = false }) catch {
        return .{ .service_name = svc.name, .success = false, .message = "cannot open log file" };
    };

    // Seek to end for append
    log_file.seekFromEnd(0) catch {};

    log_file.close();

    // Build command that redirects stdout/stderr to log file
    var cmd_buf: [8192]u8 = undefined;
    const sh_cmd = std.fmt.bufPrintZ(&cmd_buf, "echo '--- service start: {s} ---' >> {s} 2>&1; {s} >> {s} 2>&1", .{
        svc.name, log_path, svc.command, log_path,
    }) catch {
        return .{ .service_name = svc.name, .success = false, .message = "command too long" };
    };

    // Spawn detached process
    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", sh_cmd },
        allocator,
    );
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Close;
    child.stderr_behavior = .Close;
    child.cwd = abs_cwd;
    if (env_map) |em| child.env_map = em;

    child.spawn() catch {
        // Record failure in store
        if (store.getOrCreate(mdl.project_id, svc.name)) |inst| {
            inst.state = .failed;
            inst.updated_at = types.timestampMs();
            store.save();
        }
        return .{ .service_name = svc.name, .success = false, .message = "failed to spawn" };
    };

    // Update the store with the new process info.
    const pid: i32 = @intCast(child.id);

    // Record in store
    if (store.getOrCreate(mdl.project_id, svc.name)) |inst| {
        inst.pid = pid;
        inst.state = .running;
        inst.started_at = types.timestampMs();
        inst.updated_at = inst.started_at;
        inst.setCommand(svc.command);
        inst.setCwd(abs_cwd);
        inst.setLogPath(log_path);
        inst.context_fingerprint = fingerprint;
    }
    store.save();

    return .{ .service_name = svc.name, .success = true, .message = "started" };
}

// =============================================================================
// Stop
// =============================================================================

/// Stop all services for a project.
pub fn stopAll(project_id: []const u8, results: []ServiceOpResult) usize {
    const store = store_mod.getStore();
    store.refreshStates();

    var ptrs: [store_mod.max_services]?*store_mod.ServiceInstance = .{null} ** store_mod.max_services;
    const n = store.listForProject(project_id, &ptrs);
    var count: usize = 0;
    for (ptrs[0..n]) |maybe_inst| {
        if (count >= results.len) break;
        const inst = maybe_inst orelse continue;
        results[count] = stopInstance(inst);
        count += 1;
    }
    store.save();
    return count;
}

/// Stop a single named service.
pub fn stopOne(project_id: []const u8, name: []const u8) ServiceOpResult {
    const store = store_mod.getStore();
    const inst = store.find(project_id, name) orelse {
        return .{ .service_name = name, .success = false, .message = "not found" };
    };
    const result = stopInstance(inst);
    store.save();
    return result;
}

fn stopInstance(inst: *store_mod.ServiceInstance) ServiceOpResult {
    const name = inst.nameSlice();
    if (inst.state != .running and inst.state != .starting) {
        return .{ .service_name = name, .success = true, .message = "not running" };
    }

    if (inst.pid <= 0) {
        inst.state = .stopped;
        inst.updated_at = types.timestampMs();
        return .{ .service_name = name, .success = true, .message = "stopped (no pid)" };
    }

    // Send SIGTERM
    const kill_result = std.c.kill(inst.pid, 15); // SIGTERM
    if (kill_result != 0) {
        // Process might already be dead
        if (!inst.isProcessAlive()) {
            inst.state = .stopped;
            inst.updated_at = types.timestampMs();
            return .{ .service_name = name, .success = true, .message = "stopped" };
        }
        return .{ .service_name = name, .success = false, .message = "kill failed" };
    }

    // Wait briefly for graceful shutdown
    var attempts: usize = 0;
    while (attempts < 10) : (attempts += 1) {
        std.posix.nanosleep(0, 100_000_000);
        if (!inst.isProcessAlive()) break;
    }

    if (inst.isProcessAlive()) {
        // Force kill
        _ = std.c.kill(inst.pid, 9); // SIGKILL
        std.posix.nanosleep(0, 50_000_000);
    }

    inst.state = .stopped;
    inst.pid = 0;
    inst.updated_at = types.timestampMs();
    return .{ .service_name = name, .success = true, .message = "stopped" };
}

// =============================================================================
// Restart
// =============================================================================

/// Restart a single service.
pub fn restartOne(
    allocator: std.mem.Allocator,
    mdl: *const model.ProjectModel,
    name: []const u8,
    env_map: ?*const std.process.EnvMap,
    fingerprint: u64,
) ServiceOpResult {
    // Find service definition
    for (mdl.services) |svc| {
        if (std.mem.eql(u8, svc.name, name)) {
            _ = stopOne(mdl.project_id, name);
            return startOne(allocator, mdl, &svc, env_map, fingerprint);
        }
    }
    return .{ .service_name = name, .success = false, .message = "service not defined in project" };
}

// =============================================================================
// Logs
// =============================================================================

/// Read log content for a service. Returns the log content or null.
pub fn readLogs(allocator: std.mem.Allocator, project_id: []const u8, name: []const u8, max_bytes: usize) ?[]const u8 {
    const store = store_mod.getStore();
    const inst = store.find(project_id, name) orelse return null;
    const log_path = inst.logPathSlice();
    if (log_path.len == 0) return null;

    const file = std.fs.openFileAbsolute(log_path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    const size = stat.size;

    // Read last max_bytes
    if (size > max_bytes) {
        file.seekTo(size - max_bytes) catch {};
    }

    return file.readToEndAlloc(allocator, max_bytes) catch null;
}

// =============================================================================
// Helpers
// =============================================================================

fn makePathRecursive(path: []const u8) void {
    // Walk forward, creating each component
    var i: usize = 1; // skip leading /
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            std.fs.makeDirAbsolute(path[0..i]) catch {};
        }
    }
    std.fs.makeDirAbsolute(path) catch {};
}

fn makeLogPath(buf: []u8, project_id: []const u8, name: []const u8) ?[]const u8 {
    const data_home = std.posix.getenv("XDG_DATA_HOME");
    // Hash project_id for a short directory name
    var hash: u64 = 0xcbf29ce484222325;
    const prime: u64 = 0x100000001b3;
    for (project_id) |b| {
        hash ^= b;
        hash *%= prime;
    }

    if (data_home) |xdg| {
        return std.fmt.bufPrintZ(buf, "{s}/xyron/logs/{x}/{s}.log", .{ xdg, hash, name }) catch null;
    }
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.local/share/xyron/logs/{x}/{s}.log", .{ home, hash, name }) catch null;
}

// =============================================================================
// Tests
// =============================================================================

test "makeLogPath produces path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = makeLogPath(&buf, "/tmp/proj", "web");
    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.endsWith(u8, path.?, "web.log"));
}
