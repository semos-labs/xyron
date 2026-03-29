// environ.zig — Shell environment state.
//
// Wraps std.process.EnvMap with shell-specific behavior. The environment
// is initialized from the process environment on startup. Builtins like
// export and unset mutate it, and child processes inherit it via toEnvp().

const std = @import("std");
const attyx_mod = @import("attyx.zig");

pub const Environ = struct {
    map: std.process.EnvMap,
    allocator: std.mem.Allocator,
    attyx: ?*const attyx_mod.Attyx,
    /// Set when PATH is modified, cleared by the shell after cache invalidation.
    path_dirty: bool = false,

    /// Initialize from the current process environment.
    pub fn init(allocator: std.mem.Allocator, attyx: ?*const attyx_mod.Attyx) !Environ {
        const map = try std.process.getEnvMap(allocator);
        return .{ .map = map, .allocator = allocator, .attyx = attyx };
    }

    pub fn deinit(self: *Environ) void {
        self.map.deinit();
    }

    /// Get an environment variable.
    pub fn get(self: *const Environ, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    /// Set an environment variable. Emits Attyx env_changed event.
    pub fn set(self: *Environ, key: []const u8, value: []const u8) !void {
        if (self.attyx) |ax| ax.envChanged("set", key, value);
        try self.map.put(key, value);
        if (std.mem.eql(u8, key, "PATH")) self.path_dirty = true;
    }

    /// Remove an environment variable. Emits Attyx env_changed event.
    pub fn unset(self: *Environ, key: []const u8) void {
        if (self.attyx) |ax| ax.envChanged("unset", key, "");
        self.map.remove(key);
        if (std.mem.eql(u8, key, "PATH")) self.path_dirty = true;
    }

    /// Convenience: get HOME.
    pub fn home(self: *const Environ) ?[]const u8 {
        return self.get("HOME");
    }

    /// Build a null-terminated envp array for execvpe.
    /// Caller owns the returned memory (allocated with the provided allocator).
    pub fn toEnvp(self: *const Environ, allocator: std.mem.Allocator) !EnvpResult {
        // Count entries
        var count: usize = 0;
        {
            var iter = self.map.iterator();
            while (iter.next()) |_| count += 1;
        }

        // Allocate pointer array with null sentinel slot
        const ptrs = try allocator.alloc(?[*:0]const u8, count + 1);
        errdefer allocator.free(ptrs);

        // Fill entries as "KEY=VALUE\0"
        var idx: usize = 0;
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            const total = key.len + 1 + val.len;
            const buf = try allocator.allocSentinel(u8, total, 0);
            @memcpy(buf[0..key.len], key);
            buf[key.len] = '=';
            @memcpy(buf[key.len + 1 ..][0..val.len], val);
            ptrs[idx] = @ptrCast(buf.ptr);
            idx += 1;
        }
        ptrs[count] = null; // null sentinel

        return .{ .ptrs = ptrs, .allocator = allocator };
    }

    /// Create a clone with overrides applied (for inline FOO=bar command).
    pub fn cloneWithOverrides(self: *const Environ, allocator: std.mem.Allocator, overrides: []const EnvOverride) !Environ {
        // Copy the whole map
        var new_map = std.process.EnvMap.init(allocator);
        errdefer new_map.deinit();

        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            try new_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Apply overrides
        for (overrides) |ov| {
            try new_map.put(ov.key, ov.value);
        }

        return .{ .map = new_map, .allocator = allocator, .attyx = null };
    }
};

/// Inline environment override (FOO=bar before a command).
pub const EnvOverride = struct {
    key: []const u8,
    value: []const u8,
};

/// Result from toEnvp — owns the allocated strings and pointer array.
pub const EnvpResult = struct {
    ptrs: []?[*:0]const u8,
    allocator: std.mem.Allocator,

    pub fn envp(self: *const EnvpResult) [*:null]const ?[*:0]const u8 {
        return @ptrCast(self.ptrs.ptr);
    }

    pub fn deinit(self: *EnvpResult) void {
        for (self.ptrs) |p| {
            if (p) |ptr| {
                self.allocator.free(std.mem.span(ptr));
            }
        }
        self.allocator.free(self.ptrs);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "get and set" {
    var env = Environ{
        .map = std.process.EnvMap.init(std.testing.allocator),
        .allocator = std.testing.allocator,
        .attyx = null,
    };
    defer env.deinit();

    try env.set("FOO", "bar");
    try std.testing.expectEqualStrings("bar", env.get("FOO").?);
}

test "unset removes variable" {
    var env = Environ{
        .map = std.process.EnvMap.init(std.testing.allocator),
        .allocator = std.testing.allocator,
        .attyx = null,
    };
    defer env.deinit();

    try env.set("FOO", "bar");
    env.unset("FOO");
    try std.testing.expectEqual(@as(?[]const u8, null), env.get("FOO"));
}

test "toEnvp produces valid array" {
    var env = Environ{
        .map = std.process.EnvMap.init(std.testing.allocator),
        .allocator = std.testing.allocator,
        .attyx = null,
    };
    defer env.deinit();

    try env.set("A", "1");
    try env.set("B", "2");

    var result = try env.toEnvp(std.testing.allocator);
    defer result.deinit();

    // Should have at least 2 entries + null sentinel
    try std.testing.expect(result.ptrs.len >= 3);
}

test "cloneWithOverrides applies overrides" {
    var env = Environ{
        .map = std.process.EnvMap.init(std.testing.allocator),
        .allocator = std.testing.allocator,
        .attyx = null,
    };
    defer env.deinit();

    try env.set("FOO", "original");

    const overrides = [_]EnvOverride{.{ .key = "FOO", .value = "overridden" }};
    var cloned = try env.cloneWithOverrides(std.testing.allocator, &overrides);
    defer cloned.deinit();

    // Clone should have the override
    try std.testing.expectEqualStrings("overridden", cloned.get("FOO").?);
    // Original should be unchanged
    try std.testing.expectEqualStrings("original", env.get("FOO").?);
}
