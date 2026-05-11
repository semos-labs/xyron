// source_stack — LIFO stack of env snapshots for `source` / `deactivate`.
//
// When `source <file>` runs, it snapshots every env var the sourced script
// is about to change, then applies the diff. `deactivate` pops the top
// snapshot and restores the pre-source values (re-setting changed vars,
// unsetting vars that were created by the source).

const std = @import("std");
const environ_mod = @import("../environ.zig");

pub const MAX_SNAPSHOTS = 8;
pub const MAX_VARS_PER_SNAPSHOT = 64;

pub const VarSnapshot = struct {
    key: []u8,
    /// null means the var did not exist before source — deactivate should unset it.
    value: ?[]u8,
};

pub const Snapshot = struct {
    label: []u8,
    vars: []VarSnapshot,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Snapshot) void {
        for (self.vars) |v| {
            self.allocator.free(v.key);
            if (v.value) |val| self.allocator.free(val);
        }
        self.allocator.free(self.vars);
        self.allocator.free(self.label);
    }
};

/// Global stack. Shell-wide state — only one active interactive shell.
var stack: [MAX_SNAPSHOTS]Snapshot = undefined;
var depth: usize = 0;

pub fn push(snap: Snapshot) bool {
    if (depth >= MAX_SNAPSHOTS) return false;
    stack[depth] = snap;
    depth += 1;
    return true;
}

pub fn pop() ?Snapshot {
    if (depth == 0) return null;
    depth -= 1;
    return stack[depth];
}

pub fn count() usize {
    return depth;
}

pub fn peek() ?*const Snapshot {
    if (depth == 0) return null;
    return &stack[depth - 1];
}

/// Build a snapshot from the current env for the given keys.
/// The snapshot copies both keys and current values (if present).
pub fn capture(
    allocator: std.mem.Allocator,
    env: *const environ_mod.Environ,
    keys: []const []const u8,
    label: []const u8,
) !Snapshot {
    const vars = try allocator.alloc(VarSnapshot, keys.len);
    errdefer allocator.free(vars);
    var filled: usize = 0;
    errdefer {
        for (vars[0..filled]) |v| {
            allocator.free(v.key);
            if (v.value) |val| allocator.free(val);
        }
    }

    for (keys) |k| {
        const key_copy = try allocator.dupe(u8, k);
        const val_copy: ?[]u8 = if (env.get(k)) |v| try allocator.dupe(u8, v) else null;
        vars[filled] = .{ .key = key_copy, .value = val_copy };
        filled += 1;
    }

    const label_copy = try allocator.dupe(u8, label);
    return .{
        .label = label_copy,
        .vars = vars,
        .allocator = allocator,
    };
}

/// Restore a snapshot to the given environment.
pub fn restore(snap: *const Snapshot, env: *environ_mod.Environ) void {
    for (snap.vars) |v| {
        if (v.value) |val| {
            env.set(v.key, val) catch {};
        } else {
            env.unset(v.key);
        }
    }
}
