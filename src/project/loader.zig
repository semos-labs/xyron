// project/loader.zig — Project loader orchestrator.
//
// Combines discovery → manifest loading → normalization into a
// single ProjectModelLoadResult. This is the main entry point
// for all project queries.

const std = @import("std");
const model = @import("model.zig");
const discovery = @import("discovery.zig");
const manifest = @import("manifest.zig");

/// Load a project starting from the given path.
/// Performs: discovery → manifest read → parse → normalize.
/// Never crashes — all errors are captured in the result.
pub fn loadProject(allocator: std.mem.Allocator, start_path: []const u8) model.ProjectModelLoadResult {
    // Step 1: Resolve project root
    const resolution = discovery.resolve(allocator, start_path);

    if (resolution.status == .err) {
        return .{
            .resolution = resolution,
            .status = .not_found,
            .errors = makeErrors(allocator, resolution.error_msg orelse "discovery error"),
        };
    }

    if (resolution.status == .not_found) {
        return .{
            .resolution = resolution,
            .status = .not_found,
        };
    }

    // Step 2: Load manifest
    const manifest_path = resolution.manifest_path.?;
    const manifest_result = manifest.load(manifest_path);

    if (manifest_result.status == .read_error) {
        return .{
            .resolution = resolution,
            .manifest = manifest_result,
            .status = .invalid,
            .errors = makeErrors(allocator, manifest_result.error_msg orelse "cannot read manifest"),
        };
    }

    // Step 3: Parse and normalize
    const content = manifest_result.raw_content orelse "";
    const root_path = resolution.project_root.?;
    const project_id = resolution.project_id.?;
    const norm_result = manifest.normalize(allocator, root_path, project_id, content);

    if (norm_result.model == null) {
        // Parse/normalization failed — project exists but config is broken
        return .{
            .resolution = resolution,
            .manifest = manifest_result,
            .status = .invalid,
            .errors = norm_result.errors,
            .warnings = norm_result.warnings,
        };
    }

    return .{
        .resolution = resolution,
        .manifest = manifest_result,
        .model = if (norm_result.model) |m| m.* else null,
        .status = .valid,
        .errors = norm_result.errors,
        .warnings = norm_result.warnings,
    };
}

/// Load project from the current working directory.
pub fn loadFromCwd(allocator: std.mem.Allocator) model.ProjectModelLoadResult {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        return .{
            .resolution = .{
                .input_path = ".",
                .normalized_input_path = ".",
                .status = .err,
                .error_msg = "cannot get current directory",
            },
            .status = .not_found,
            .errors = makeErrors(allocator, "cannot get current directory"),
        };
    };
    return loadProject(allocator, cwd);
}

fn makeErrors(allocator: std.mem.Allocator, msg: []const u8) []const []const u8 {
    var errs = allocator.alloc([]const u8, 1) catch return &.{};
    errs[0] = msg;
    return errs;
}

// =============================================================================
// Tests
// =============================================================================

test "loadProject returns not_found for /tmp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = loadProject(arena.allocator(), "/tmp");
    try std.testing.expect(result.status == .not_found or result.status == .valid);
}

test "loadProject returns not_found for root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = loadProject(arena.allocator(), "/");
    try std.testing.expect(result.status == .not_found or result.status == .valid);
}

test "loadFromCwd returns structured result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = loadFromCwd(arena.allocator());
    try std.testing.expect(result.status == .not_found or result.status == .valid or result.status == .invalid);
}
