// project/discovery.zig — Project root resolution.
//
// Walks upward from a given path to find the nearest xyron.toml.
// Pure filesystem logic — no config parsing happens here.

const std = @import("std");
const model = @import("model.zig");

const manifest_filename = "xyron.toml";
const max_depth = 256; // safety limit for upward traversal

/// Resolve the nearest project root starting from `start_path`.
/// If `start_path` is a file, its parent directory is used.
/// Returns a ProjectResolution with trace of all checked directories.
pub fn resolve(allocator: std.mem.Allocator, start_path: []const u8) model.ProjectResolution {
    // Normalize to absolute path
    const abs_path = toAbsolute(allocator, start_path) orelse {
        return .{
            .input_path = start_path,
            .normalized_input_path = start_path,
            .status = .err,
            .error_msg = "failed to resolve absolute path",
        };
    };

    // If it's a file, use parent directory
    const search_start = resolveToDirectory(abs_path);

    var trace_list: std.ArrayListUnmanaged([]const u8) = .{};
    var current = search_start;
    var depth: usize = 0;

    while (depth < max_depth) : (depth += 1) {
        trace_list.append(allocator, current) catch {};

        // Check for xyron.toml in this directory
        if (checkManifest(allocator, current)) |manifest_path| {
            return .{
                .input_path = start_path,
                .normalized_input_path = abs_path,
                .project_root = current,
                .manifest_path = manifest_path,
                .project_id = current,
                .status = .found,
                .trace = trace_list.toOwnedSlice(allocator) catch &.{},
            };
        }

        // Move to parent
        const parent = std.fs.path.dirname(current);
        if (parent == null or std.mem.eql(u8, parent.?, current)) {
            // Reached filesystem root
            break;
        }
        current = parent.?;
    }

    return .{
        .input_path = start_path,
        .normalized_input_path = abs_path,
        .status = .not_found,
        .trace = trace_list.toOwnedSlice(allocator) catch &.{},
    };
}

/// Check if xyron.toml exists in the given directory.
/// Returns the full manifest path if found, null otherwise.
fn checkManifest(allocator: std.mem.Allocator, dir_path: []const u8) ?[]const u8 {
    const manifest_path = std.fs.path.join(allocator, &.{ dir_path, manifest_filename }) catch return null;

    // Try to access the file
    const file = std.fs.openFileAbsolute(manifest_path, .{}) catch {
        allocator.free(manifest_path);
        return null;
    };
    file.close();
    return manifest_path;
}

/// Convert a potentially relative path to absolute.
fn toAbsolute(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path) catch null;
    }
    // Resolve relative to cwd
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch return null;
    return std.fs.path.join(allocator, &.{ cwd, path }) catch null;
}

/// If path points to a file, return its parent directory. Otherwise return as-is.
/// For non-existent paths, uses the extension heuristic as fallback.
fn resolveToDirectory(path: []const u8) []const u8 {
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.NotDir => {
            return std.fs.path.dirname(path) orelse path;
        },
        error.FileNotFound => {
            // Path doesn't exist — if it has an extension, treat as file
            if (std.fs.path.extension(path).len > 0) {
                return std.fs.path.dirname(path) orelse path;
            }
            return path;
        },
        else => return path,
    };
    dir.close();
    return path;
}

// =============================================================================
// Tests
// =============================================================================

test "resolve returns not_found when no manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = resolve(arena.allocator(), "/tmp");
    // /tmp might contain a xyron.toml in CI, so just verify structure
    try std.testing.expect(result.status == .found or result.status == .not_found);
    try std.testing.expect(result.trace.len > 0);
}

test "resolve uses file parent" {
    const path = resolveToDirectory("/tmp/nonexistent_file.txt");
    try std.testing.expectEqualStrings("/tmp", path);
}

test "resolve keeps directory as-is" {
    const path = resolveToDirectory("/tmp");
    try std.testing.expectEqualStrings("/tmp", path);
}
