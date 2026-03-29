// path_search.zig — PATH-based command resolution.
//
// Searches the directories listed in $PATH for an executable matching
// a given name. Used by the `which` and `type` builtins.

const std = @import("std");
const environ_mod = @import("environ.zig");

/// Search PATH for a command. Returns the full path if found, null otherwise.
/// Caller owns the returned string.
pub fn findInPath(
    allocator: std.mem.Allocator,
    command: []const u8,
    env: *const environ_mod.Environ,
) !?[]const u8 {
    const path_val = env.get("PATH") orelse return null;

    var iter = std.mem.splitScalar(u8, path_val, ':');
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;

        // Build full path: dir/command
        const full_len = dir.len + 1 + command.len;
        const buf = try allocator.alloc(u8, full_len);
        errdefer allocator.free(buf);

        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = '/';
        @memcpy(buf[dir.len + 1 ..][0..command.len], command);

        // Check if file exists and is executable
        const path_z = try allocator.dupeZ(u8, buf);
        defer allocator.free(path_z);

        const stat_result = std.posix.fstatat(
            std.posix.AT.FDCWD,
            path_z,
            0,
        );

        if (stat_result) |stat| {
            // Check if it's a regular file and has execute permission
            const mode = stat.mode;
            const is_regular = (mode & std.posix.S.IFREG) != 0;
            const is_exec = (mode & std.posix.S.IXUSR) != 0 or
                (mode & std.posix.S.IXGRP) != 0 or
                (mode & std.posix.S.IXOTH) != 0;
            if (is_regular and is_exec) return buf;
        } else |_| {}

        allocator.free(buf);
    }

    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "findInPath finds ls" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/usr/bin:/bin");
    var env = environ_mod.Environ{
        .map = env_map,
        .allocator = std.testing.allocator,
        .attyx = null,
    };

    const result = try findInPath(std.testing.allocator, "ls", &env);
    if (result) |path| {
        defer std.testing.allocator.free(path);
        try std.testing.expect(std.mem.endsWith(u8, path, "/ls"));
    }
}

test "findInPath returns null for nonexistent command" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/usr/bin:/bin");
    var env = environ_mod.Environ{
        .map = env_map,
        .allocator = std.testing.allocator,
        .attyx = null,
    };

    const result = try findInPath(std.testing.allocator, "__xyron_nonexistent__", &env);
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}
