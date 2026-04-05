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
const s = @import("../style.zig");
const Result = @import("mod.zig").BuiltinResult;

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

pub fn serviceUp(args: []const []const u8, _: std.fs.File, stderr: std.fs.File, env_inst: *environ_mod.Environ) Result {
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
                s.printDim(stderr, "starting {s}...", .{svc.name});
                const result = svc_mgr.startOne(allocator, &mdl, &svc, &env_inst.map, proj.fingerprint);
                printOpResult(stderr, &result);
                if (result.success) {
                    s.printDim(stderr, "  cmd: {s}", .{svc.command});
                    s.printDim(stderr, "  cwd: {s}", .{svc.cwd});
                }
                return .{ .exit_code = if (result.success) 0 else 1 };
            }
        }
        s.print(stderr, "Unknown service: {s}\n", .{args[0]});
        return .{ .exit_code = 1 };
    }

    // Start all
    if (mdl.services.len > 1) {
        s.printDim(stderr, "starting {d} services...", .{mdl.services.len});
    }
    var results: [svc_store.max_services]svc_mgr.ServiceOpResult = undefined;
    const count = svc_mgr.startAll(allocator, &mdl, &env_inst.map, proj.fingerprint, &results);
    var any_failed = false;
    for (results[0..count]) |*r| {
        printOpResult(stderr, r);
        if (!r.success) any_failed = true;
    }
    return .{ .exit_code = if (any_failed) 1 else 0 };
}

// =============================================================================
// xyron down
// =============================================================================

pub fn serviceDown(_: std.fs.File, stderr: std.fs.File) Result {
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
        stderr.writeAll("No services running\r\n") catch {};
        return .{};
    }
    for (results[0..count]) |*r| {
        printOpResult(stderr, r);
    }
    return .{};
}

// =============================================================================
// xyron restart <service>
// =============================================================================

pub fn serviceRestart(args: []const []const u8, _: std.fs.File, stderr: std.fs.File, env_inst: *environ_mod.Environ) Result {
    if (args.len == 0) {
        stderr.writeAll("Usage: xyron restart <service>\n") catch {};
        return .{ .exit_code = 1 };
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const proj = loadProject(allocator, stderr) orelse return .{ .exit_code = 1 };
    const result = svc_mgr.restartOne(allocator, &proj.mdl, args[0], &env_inst.map, proj.fingerprint);
    printOpResult(stderr, &result);
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

    s.printHeader(stderr, "Services");

    // For each declared service, show its state
    for (mdl.services) |svc| {
        const inst = store.find(mdl.project_id, svc.name);
        if (inst) |i| {
            const stale_suffix: []const u8 = if (i.state == .running and i.context_fingerprint != 0) blk: {
                const sys_env = buildSystemEnv(allocator);
                const empty_ovr = project.EnvSource{ .keys = &.{}, .values = &.{} };
                const resolved = project.resolver.resolveContext(allocator, &mdl, &sys_env, &empty_ovr);
                break :blk if (resolved.fingerprint != i.context_fingerprint) " (stale)" else "";
            } else "";

            var line_buf: [512]u8 = undefined;
            var pos: usize = 0;
            pos += s.cp(line_buf[pos..], "  ");
            const color: s.Color = switch (i.state) {
                .running => .green,
                .failed => .red,
                .starting => .yellow,
                .stopped => .bright_black,
            };
            pos += s.fg(line_buf[pos..], color);
            pos += s.cp(line_buf[pos..], s.box.bullet);
            pos += s.reset(line_buf[pos..]);
            pos += s.cp(line_buf[pos..], " ");
            pos += s.cp(line_buf[pos..], svc.name);
            pos += s.cp(line_buf[pos..], "  ");
            pos += s.fg(line_buf[pos..], color);
            pos += s.cp(line_buf[pos..], i.state.label());
            pos += s.reset(line_buf[pos..]);
            pos += s.dim(line_buf[pos..]);
            pos += (std.fmt.bufPrint(line_buf[pos..], "  pid {d}", .{i.pid}) catch "").len;
            pos += s.cp(line_buf[pos..], stale_suffix);
            pos += s.reset(line_buf[pos..]);
            pos += s.crlf(line_buf[pos..]);
            stderr.writeAll(line_buf[0..pos]) catch {};
        } else {
            s.printDim(stderr, "  ○ {s}  stopped", .{svc.name});
        }
    }

    return .{};
}

// =============================================================================
// xyron logs <service>
// =============================================================================

pub fn serviceLogs(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) {
        stderr.writeAll("Usage: xyron logs [-f] <service>\n") catch {};
        return .{ .exit_code = 1 };
    }

    // Parse -f flag
    var follow = false;
    var service_name: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
            follow = true;
        } else {
            service_name = arg;
        }
    }

    if (service_name == null) {
        stderr.writeAll("Usage: xyron logs [-f] <service>\n") catch {};
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

    // Get log file path from store
    const store = svc_store.getStore();
    const inst = store.find(mdl.project_id, service_name.?) orelse {
        s.print(stderr, "No logs for service: {s}\n", .{service_name.?});
        return .{ .exit_code = 1 };
    };
    const log_path = inst.logPathSlice();
    if (log_path.len == 0) {
        s.print(stderr, "No log path for service: {s}\n", .{service_name.?});
        return .{ .exit_code = 1 };
    }

    if (follow) {
        return followLogs(log_path, stdout, stderr);
    }

    // One-shot: read and print last 64KB
    const content = svc_mgr.readLogs(allocator, mdl.project_id, service_name.?, 65536) orelse {
        s.print(stderr, "Cannot read logs for service: {s}\n", .{service_name.?});
        return .{ .exit_code = 1 };
    };

    stdout.writeAll(content) catch {};
    if (content.len > 0 and content[content.len - 1] != '\n') {
        stdout.writeAll("\n") catch {};
    }
    return .{};
}

/// Follow a log file (tail -f behavior). Blocks until Ctrl+C.
fn followLogs(log_path: []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    const file = std.fs.openFileAbsolute(log_path, .{}) catch {
        stderr.writeAll("Cannot open log file\n") catch {};
        return .{ .exit_code = 1 };
    };
    defer file.close();

    // Print existing content first (last 16KB)
    const stat = file.stat() catch {
        stderr.writeAll("Cannot stat log file\n") catch {};
        return .{ .exit_code = 1 };
    };
    if (stat.size > 16384) {
        file.seekTo(stat.size - 16384) catch {};
        // Skip to next newline to avoid partial line
        var skip_buf: [1]u8 = undefined;
        while (true) {
            const n = file.read(&skip_buf) catch break;
            if (n == 0) break;
            if (skip_buf[0] == '\n') break;
        }
    }

    // Read loop: print new content, sleep when nothing new
    const term_mod = @import("../term.zig");
    term_mod.suspendRawMode();
    defer term_mod.resumeRawMode();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n > 0) {
            stdout.writeAll(buf[0..n]) catch break;
        } else {
            // Poll for SIGINT via checking if read would block
            // Sleep 100ms between polls
            std.posix.nanosleep(0, 100_000_000);
        }
    }

    return .{};
}

// =============================================================================
// Helpers
// =============================================================================

fn printOpResult(stdout: std.fs.File, r: *const svc_mgr.ServiceOpResult) void {
    if (r.success) {
        s.printPass(stdout, r.service_name, r.message);
    } else {
        s.printFail(stdout, r.service_name, r.message);
    }
}
