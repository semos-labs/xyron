// project/doctor.zig — Project diagnostics engine.
//
// Validates the active project by inspecting real system state:
// ProjectModel (Phase 1), ResolvedContext (Phase 2), ServiceStore (Phase 5),
// and git info. Does NOT re-parse manifests, re-merge env, or duplicate
// any subsystem logic — doctor is policy over existing state.

const std = @import("std");
const model = @import("model.zig");
const ctx = @import("context.zig");
const service_store = @import("service_store.zig");
const resolver = @import("resolver.zig");
const loader = @import("loader.zig");
const git_info_mod = @import("../git_info.zig");

// =============================================================================
// Report model
// =============================================================================

pub const CheckStatus = enum {
    pass,
    warn,
    fail,

    pub fn label(self: CheckStatus) []const u8 {
        return switch (self) {
            .pass => "PASS",
            .warn => "WARN",
            .fail => "FAIL",
        };
    }
};

pub const CheckCategory = enum {
    project,
    context,
    env,
    secrets,
    commands,
    services,
    git,
    runtime,
};

pub const DoctorCheck = struct {
    category: CheckCategory,
    name: []const u8,
    status: CheckStatus,
    message: []const u8,
    suggestion: ?[]const u8 = null,
};

pub const ReportStatus = enum { healthy, warn, fail };

pub const DoctorReport = struct {
    project_id: []const u8 = "",
    project_root: []const u8 = "",
    status: ReportStatus = .healthy,
    checks: []const DoctorCheck = &.{},
    total: usize = 0,
    passed: usize = 0,
    warnings: usize = 0,
    failed: usize = 0,
};

// =============================================================================
// Runner
// =============================================================================

/// Run all doctor checks for the current working directory.
pub fn runDoctor(allocator: std.mem.Allocator) DoctorReport {
    var checks: std.ArrayListUnmanaged(DoctorCheck) = .{};

    // Step 1: Load project
    const load_result = loader.loadFromCwd(allocator);

    if (load_result.status == .not_found) {
        checks.append(allocator, .{
            .category = .project,
            .name = "project detected",
            .status = .fail,
            .message = "not in a xyron project",
            .suggestion = "create xyron.toml in your project root",
        }) catch {};
        return finalize(allocator, "", "", &checks);
    }

    const project_root = load_result.resolution.project_root orelse "";
    const project_id = load_result.resolution.project_id orelse "";

    if (load_result.status == .invalid) {
        checks.append(allocator, .{
            .category = .project,
            .name = "config valid",
            .status = .fail,
            .message = if (load_result.errors.len > 0) load_result.errors[0] else "invalid project config",
            .suggestion = "fix xyron.toml syntax errors",
        }) catch {};
        return finalize(allocator, project_id, project_root, &checks);
    }

    // Project is valid
    checks.append(allocator, .{
        .category = .project,
        .name = "project detected",
        .status = .pass,
        .message = project_root,
    }) catch {};

    const mdl = load_result.model.?;

    checks.append(allocator, .{
        .category = .project,
        .name = "config valid",
        .status = .pass,
        .message = "xyron.toml loaded successfully",
    }) catch {};

    // Step 2: Resolve context
    const sys_env = buildSystemEnv(allocator);
    const empty_ovr = resolver.EnvSource{ .keys = &.{}, .values = &.{} };
    const resolved = resolver.resolveContext(allocator, &mdl, &sys_env, &empty_ovr);

    checkContext(allocator, &resolved, &checks);
    checkSecrets(allocator, &mdl, &resolved, &checks);
    checkCommands(allocator, &mdl, &checks);
    checkServices(allocator, &mdl, &resolved, &checks);
    checkGit(&checks, allocator);

    return finalize(allocator, project_id, project_root, &checks);
}

// =============================================================================
// Individual check functions
// =============================================================================

fn checkContext(allocator: std.mem.Allocator, resolved: *const ctx.ResolvedContext, checks: *std.ArrayListUnmanaged(DoctorCheck)) void {
    // Check env source loading
    for (resolved.env_sources) |src| {
        if (src.source_kind == .system) continue;
        switch (src.status) {
            .loaded => {
                checks.append(allocator, .{
                    .category = .env,
                    .name = src.source_name,
                    .status = .pass,
                    .message = std.fmt.allocPrint(allocator, "loaded ({d} keys)", .{src.loaded_keys.len}) catch "loaded",
                }) catch {};
            },
            .file_not_found => {
                checks.append(allocator, .{
                    .category = .env,
                    .name = src.source_name,
                    .status = .warn,
                    .message = "file not found",
                    .suggestion = std.fmt.allocPrint(allocator, "create {s} or remove from env.sources", .{src.source_name}) catch null,
                }) catch {};
            },
            .read_error => {
                checks.append(allocator, .{
                    .category = .env,
                    .name = src.source_name,
                    .status = .fail,
                    .message = "cannot read file",
                    .suggestion = "check file permissions",
                }) catch {};
            },
            .parse_error => {
                checks.append(allocator, .{
                    .category = .env,
                    .name = src.source_name,
                    .status = .fail,
                    .message = "parse error",
                    .suggestion = "fix syntax in env file",
                }) catch {};
            },
        }
    }

    // Check context warnings
    for (resolved.warnings) |warn| {
        checks.append(allocator, .{
            .category = .context,
            .name = "context warning",
            .status = .warn,
            .message = warn,
        }) catch {};
    }
}

fn checkSecrets(allocator: std.mem.Allocator, mdl: *const model.ProjectModel, resolved: *const ctx.ResolvedContext, checks: *std.ArrayListUnmanaged(DoctorCheck)) void {
    // Check each required secret
    for (mdl.secrets.required) |key| {
        if (resolved.values.contains(key)) {
            checks.append(allocator, .{
                .category = .secrets,
                .name = key,
                .status = .pass,
                .message = "present",
            }) catch {};
        } else {
            checks.append(allocator, .{
                .category = .secrets,
                .name = key,
                .status = .fail,
                .message = "missing",
                .suggestion = std.fmt.allocPrint(allocator, "add {s} to .env or run: xyron secrets add {s} <value>", .{ key, key }) catch "add to .env or xyron secrets",
            }) catch {};
        }
    }
}

fn checkCommands(allocator: std.mem.Allocator, mdl: *const model.ProjectModel, checks: *std.ArrayListUnmanaged(DoctorCheck)) void {
    for (mdl.commands) |cmd| {
        // Validate cwd exists
        const abs_cwd = if (std.fs.path.isAbsolute(cmd.cwd))
            cmd.cwd
        else
            std.fs.path.join(allocator, &.{ mdl.root_path, cmd.cwd }) catch cmd.cwd;

        var dir = std.fs.openDirAbsolute(abs_cwd, .{}) catch {
            checks.append(allocator, .{
                .category = .commands,
                .name = cmd.name,
                .status = .fail,
                .message = std.fmt.allocPrint(allocator, "cwd does not exist: {s}", .{abs_cwd}) catch "cwd missing",
                .suggestion = "fix cwd in xyron.toml or create the directory",
            }) catch {};
            continue;
        };
        dir.close();

        checks.append(allocator, .{
            .category = .commands,
            .name = cmd.name,
            .status = .pass,
            .message = "ready",
        }) catch {};
    }
}

fn checkServices(allocator: std.mem.Allocator, mdl: *const model.ProjectModel, resolved: *const ctx.ResolvedContext, checks: *std.ArrayListUnmanaged(DoctorCheck)) void {
    if (mdl.services.len == 0) return;

    const store = service_store.getStore();
    store.refreshStates();

    for (mdl.services) |svc| {
        // Check cwd
        const abs_cwd = if (std.fs.path.isAbsolute(svc.cwd))
            svc.cwd
        else
            std.fs.path.join(allocator, &.{ mdl.root_path, svc.cwd }) catch svc.cwd;

        {
            var dir = std.fs.openDirAbsolute(abs_cwd, .{}) catch {
                checks.append(allocator, .{
                    .category = .services,
                    .name = svc.name,
                    .status = .fail,
                    .message = "cwd does not exist",
                    .suggestion = "fix service cwd in xyron.toml",
                }) catch {};
                continue;
            };
            dir.close();
        }

        // Check state in store
        const inst = store.find(mdl.project_id, svc.name);
        if (inst == null) {
            checks.append(allocator, .{
                .category = .services,
                .name = svc.name,
                .status = .pass,
                .message = "defined (not started)",
            }) catch {};
            continue;
        }

        const i = inst.?;
        switch (i.state) {
            .running => {
                // Check staleness
                if (i.context_fingerprint != 0 and resolved.fingerprint != i.context_fingerprint) {
                    checks.append(allocator, .{
                        .category = .services,
                        .name = svc.name,
                        .status = .warn,
                        .message = "running but stale (context changed since launch)",
                        .suggestion = std.fmt.allocPrint(allocator, "xyron restart {s}", .{svc.name}) catch "restart service",
                    }) catch {};
                } else {
                    checks.append(allocator, .{
                        .category = .services,
                        .name = svc.name,
                        .status = .pass,
                        .message = std.fmt.allocPrint(allocator, "running (pid {d})", .{i.pid}) catch "running",
                    }) catch {};
                }
            },
            .failed => {
                checks.append(allocator, .{
                    .category = .services,
                    .name = svc.name,
                    .status = .fail,
                    .message = "failed",
                    .suggestion = std.fmt.allocPrint(allocator, "check logs: xyron logs {s}", .{svc.name}) catch "check logs",
                }) catch {};
            },
            .stopped => {
                checks.append(allocator, .{
                    .category = .services,
                    .name = svc.name,
                    .status = .pass,
                    .message = "stopped",
                }) catch {};
            },
            .starting => {
                checks.append(allocator, .{
                    .category = .services,
                    .name = svc.name,
                    .status = .warn,
                    .message = "still starting",
                }) catch {};
            },
        }
    }
}

fn checkGit(checks: *std.ArrayListUnmanaged(DoctorCheck), allocator: std.mem.Allocator) void {
    const git = git_info_mod.read();

    if (git.branch.len == 0) {
        // No git repo or cannot read
        checks.append(allocator, .{
            .category = .git,
            .name = "repository",
            .status = .warn,
            .message = "no git repository detected",
        }) catch {};
        return;
    }

    checks.append(allocator, .{
        .category = .git,
        .name = "repository",
        .status = .pass,
        .message = std.fmt.allocPrint(allocator, "branch: {s}", .{git.branch}) catch "ok",
    }) catch {};

    if (git.is_detached) {
        checks.append(allocator, .{
            .category = .git,
            .name = "HEAD state",
            .status = .warn,
            .message = "detached HEAD",
            .suggestion = "checkout a branch if unintended",
        }) catch {};
    }

    if (git.is_rebasing) {
        checks.append(allocator, .{
            .category = .git,
            .name = "rebase",
            .status = .warn,
            .message = "rebase in progress",
            .suggestion = "finish or abort rebase before running services",
        }) catch {};
    } else if (git.is_merging) {
        checks.append(allocator, .{
            .category = .git,
            .name = "merge",
            .status = .warn,
            .message = "merge in progress",
            .suggestion = "resolve merge conflicts",
        }) catch {};
    } else if (git.is_cherry_picking) {
        checks.append(allocator, .{
            .category = .git,
            .name = "cherry-pick",
            .status = .warn,
            .message = "cherry-pick in progress",
        }) catch {};
    }

    if (git.conflicts > 0) {
        checks.append(allocator, .{
            .category = .git,
            .name = "conflicts",
            .status = .warn,
            .message = std.fmt.allocPrint(allocator, "{d} unresolved conflict(s)", .{git.conflicts}) catch "conflicts",
            .suggestion = "resolve merge conflicts",
        }) catch {};
    }
}

// =============================================================================
// Helpers
// =============================================================================

fn finalize(allocator: std.mem.Allocator, project_id: []const u8, project_root: []const u8, checks: *std.ArrayListUnmanaged(DoctorCheck)) DoctorReport {
    var passed: usize = 0;
    var warnings: usize = 0;
    var failed: usize = 0;

    for (checks.items) |chk| {
        switch (chk.status) {
            .pass => passed += 1,
            .warn => warnings += 1,
            .fail => failed += 1,
        }
    }

    const status: ReportStatus = if (failed > 0) .fail else if (warnings > 0) .warn else .healthy;

    return .{
        .project_id = project_id,
        .project_root = project_root,
        .status = status,
        .checks = checks.toOwnedSlice(allocator) catch &.{},
        .total = passed + warnings + failed,
        .passed = passed,
        .warnings = warnings,
        .failed = failed,
    };
}

fn buildSystemEnv(allocator: std.mem.Allocator) resolver.EnvSource {
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
// Tests
// =============================================================================

test "finalize computes summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var checks: std.ArrayListUnmanaged(DoctorCheck) = .{};
    checks.append(a, .{ .category = .project, .name = "a", .status = .pass, .message = "ok" }) catch {};
    checks.append(a, .{ .category = .env, .name = "b", .status = .warn, .message = "missing" }) catch {};
    checks.append(a, .{ .category = .secrets, .name = "c", .status = .fail, .message = "bad" }) catch {};

    const report = finalize(a, "/tmp", "/tmp", &checks);
    try std.testing.expectEqual(@as(usize, 3), report.total);
    try std.testing.expectEqual(@as(usize, 1), report.passed);
    try std.testing.expectEqual(@as(usize, 1), report.warnings);
    try std.testing.expectEqual(@as(usize, 1), report.failed);
    try std.testing.expectEqual(ReportStatus.fail, report.status);
}

test "finalize healthy when all pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var checks: std.ArrayListUnmanaged(DoctorCheck) = .{};
    checks.append(a, .{ .category = .project, .name = "a", .status = .pass, .message = "ok" }) catch {};

    const report = finalize(a, "/tmp", "/tmp", &checks);
    try std.testing.expectEqual(ReportStatus.healthy, report.status);
}
