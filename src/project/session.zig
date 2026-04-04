// project/session.zig — Session context management.
//
// Manages the active context for a shell session, detects transitions
// between project states, and computes diffs between resolved contexts.

const std = @import("std");
const ctx = @import("context.zig");
const types = @import("../types.zig");

/// Build an ActiveContext from a resolved project state.
///
/// - If resolved is non-null, the project has a valid context.
/// - If resolved is null but project_id is set, the project exists but context is invalid.
/// - If project_id is null, we're outside any project.
pub fn buildActiveContext(
    session_id: u64,
    generation: u64,
    project_id: ?[]const u8,
    project_root: ?[]const u8,
    resolved: ?ctx.ResolvedContext,
    errs: []const []const u8,
    warns: []const []const u8,
) ctx.ActiveContext {
    const status: ctx.ProjectStatus = if (resolved != null)
        .valid_context
    else if (project_id != null)
        .invalid_context
    else
        .no_project;

    return .{
        .session_id = session_id,
        .resolved = resolved,
        .project_status = status,
        .project_id = project_id,
        .project_root = project_root,
        .activated_at = types.timestampMs(),
        .generation = generation,
        .warnings = warns,
        .errors = errs,
    };
}

/// Detect the kind of transition between two active context states.
pub fn detectTransition(
    allocator: std.mem.Allocator,
    prev: *const ctx.ActiveContext,
    next: *const ctx.ActiveContext,
) ctx.ContextTransition {
    const prev_has_project = prev.project_id != null;
    const next_has_project = next.project_id != null;

    // No project -> no project
    if (!prev_has_project and !next_has_project) {
        return .{ .kind = .stay_outside_project };
    }

    // No project -> project
    if (!prev_has_project and next_has_project) {
        return .{
            .kind = .enter_project,
            .next_project_id = next.project_id,
            .diff = computeDiff(allocator, prev, next),
        };
    }

    // Project -> no project
    if (prev_has_project and !next_has_project) {
        return .{
            .kind = .leave_project,
            .prev_project_id = prev.project_id,
            .diff = computeDiff(allocator, prev, next),
        };
    }

    // Both have projects
    const same_project = std.mem.eql(u8, prev.project_id.?, next.project_id.?);

    if (!same_project) {
        return .{
            .kind = .switch_project,
            .prev_project_id = prev.project_id,
            .next_project_id = next.project_id,
            .diff = computeDiff(allocator, prev, next),
        };
    }

    // Same project — check if context changed
    const prev_fp = if (prev.resolved) |r| r.fingerprint else 0;
    const next_fp = if (next.resolved) |r| r.fingerprint else 0;

    if (prev_fp == next_fp) {
        return .{
            .kind = .stay_in_project,
            .prev_project_id = prev.project_id,
            .next_project_id = next.project_id,
        };
    }

    return .{
        .kind = .reload_project,
        .prev_project_id = prev.project_id,
        .next_project_id = next.project_id,
        .diff = computeDiff(allocator, prev, next),
    };
}

/// Compute a diff between two active contexts' resolved values.
fn computeDiff(
    allocator: std.mem.Allocator,
    prev: *const ctx.ActiveContext,
    next: *const ctx.ActiveContext,
) ctx.ContextDiff {
    const prev_values = if (prev.resolved) |r| &r.values else null;
    const next_values = if (next.resolved) |r| &r.values else null;

    return diffValues(allocator, prev_values, next_values);
}

/// Diff two value maps. Either or both may be null (no context).
pub fn diffValues(
    allocator: std.mem.Allocator,
    prev: ?*const std.StringArrayHashMap([]const u8),
    next: ?*const std.StringArrayHashMap([]const u8),
) ctx.ContextDiff {
    var added: std.ArrayListUnmanaged([]const u8) = .{};
    var removed: std.ArrayListUnmanaged([]const u8) = .{};
    var changed: std.ArrayListUnmanaged([]const u8) = .{};

    if (next) |n| {
        for (n.keys(), n.values()) |key, val| {
            if (prev) |p| {
                if (p.get(key)) |prev_val| {
                    if (!std.mem.eql(u8, prev_val, val)) {
                        changed.append(allocator, key) catch {};
                    }
                } else {
                    added.append(allocator, key) catch {};
                }
            } else {
                // No previous context — everything is added
                added.append(allocator, key) catch {};
            }
        }
    }

    if (prev) |p| {
        for (p.keys()) |key| {
            if (next) |n| {
                if (!n.contains(key)) {
                    removed.append(allocator, key) catch {};
                }
            } else {
                // No next context — everything is removed
                removed.append(allocator, key) catch {};
            }
        }
    }

    return .{
        .added = added.toOwnedSlice(allocator) catch &.{},
        .removed = removed.toOwnedSlice(allocator) catch &.{},
        .changed = changed.toOwnedSlice(allocator) catch &.{},
    };
}

// =============================================================================
// Tests
// =============================================================================

test "buildActiveContext with no project" {
    const ac = buildActiveContext(1, 0, null, null, null, &.{}, &.{});
    try std.testing.expectEqual(ctx.ProjectStatus.no_project, ac.project_status);
    try std.testing.expect(ac.resolved == null);
}

test "buildActiveContext with valid context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resolved = ctx.ResolvedContext{
        .project_id = "/tmp/test",
        .project_root = "/tmp/test",
        .values = std.StringArrayHashMap([]const u8).init(a),
        .provenance = std.StringArrayHashMap(ctx.ValueProvenance).init(a),
    };

    const ac = buildActiveContext(1, 1, "/tmp/test", "/tmp/test", resolved, &.{}, &.{});
    try std.testing.expectEqual(ctx.ProjectStatus.valid_context, ac.project_status);
    try std.testing.expect(ac.resolved != null);
    try std.testing.expect(ac.activated_at > 0);
}

test "buildActiveContext with invalid context" {
    const ac = buildActiveContext(1, 1, "/tmp/test", "/tmp/test", null, &.{"parse error"}, &.{});
    try std.testing.expectEqual(ctx.ProjectStatus.invalid_context, ac.project_status);
    try std.testing.expectEqual(@as(usize, 1), ac.errors.len);
}

test "transition: stay outside project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prev = ctx.ActiveContext{ .session_id = 1 };
    const next = ctx.ActiveContext{ .session_id = 1 };

    const t = detectTransition(arena.allocator(), &prev, &next);
    try std.testing.expectEqual(ctx.TransitionKind.stay_outside_project, t.kind);
}

test "transition: enter project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prev = ctx.ActiveContext{ .session_id = 1 };
    const next = ctx.ActiveContext{
        .session_id = 1,
        .project_id = "/tmp/proj",
        .project_status = .valid_context,
    };

    const t = detectTransition(arena.allocator(), &prev, &next);
    try std.testing.expectEqual(ctx.TransitionKind.enter_project, t.kind);
}

test "transition: leave project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prev = ctx.ActiveContext{
        .session_id = 1,
        .project_id = "/tmp/proj",
        .project_status = .valid_context,
    };
    const next = ctx.ActiveContext{ .session_id = 1 };

    const t = detectTransition(arena.allocator(), &prev, &next);
    try std.testing.expectEqual(ctx.TransitionKind.leave_project, t.kind);
}

test "transition: switch project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prev = ctx.ActiveContext{
        .session_id = 1,
        .project_id = "/tmp/proj-a",
        .project_status = .valid_context,
    };
    const next = ctx.ActiveContext{
        .session_id = 1,
        .project_id = "/tmp/proj-b",
        .project_status = .valid_context,
    };

    const t = detectTransition(arena.allocator(), &prev, &next);
    try std.testing.expectEqual(ctx.TransitionKind.switch_project, t.kind);
}

test "transition: stay in project (same fingerprint)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resolved = ctx.ResolvedContext{
        .project_id = "/tmp/proj",
        .project_root = "/tmp/proj",
        .values = std.StringArrayHashMap([]const u8).init(a),
        .provenance = std.StringArrayHashMap(ctx.ValueProvenance).init(a),
        .fingerprint = 12345,
    };

    const prev = ctx.ActiveContext{
        .session_id = 1,
        .project_id = "/tmp/proj",
        .resolved = resolved,
        .project_status = .valid_context,
    };
    const next = ctx.ActiveContext{
        .session_id = 1,
        .project_id = "/tmp/proj",
        .resolved = resolved,
        .project_status = .valid_context,
    };

    const t = detectTransition(a, &prev, &next);
    try std.testing.expectEqual(ctx.TransitionKind.stay_in_project, t.kind);
}

test "transition: reload project (changed fingerprint)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r1 = ctx.ResolvedContext{
        .project_id = "/tmp/proj",
        .project_root = "/tmp/proj",
        .values = std.StringArrayHashMap([]const u8).init(a),
        .provenance = std.StringArrayHashMap(ctx.ValueProvenance).init(a),
        .fingerprint = 111,
    };
    _ = &r1;

    var r2 = ctx.ResolvedContext{
        .project_id = "/tmp/proj",
        .project_root = "/tmp/proj",
        .values = std.StringArrayHashMap([]const u8).init(a),
        .provenance = std.StringArrayHashMap(ctx.ValueProvenance).init(a),
        .fingerprint = 222,
    };
    _ = &r2;

    const prev = ctx.ActiveContext{
        .session_id = 1,
        .project_id = "/tmp/proj",
        .resolved = r1,
        .project_status = .valid_context,
    };
    const next = ctx.ActiveContext{
        .session_id = 1,
        .project_id = "/tmp/proj",
        .resolved = r2,
        .project_status = .valid_context,
    };

    const t = detectTransition(a, &prev, &next);
    try std.testing.expectEqual(ctx.TransitionKind.reload_project, t.kind);
}

test "diff: added keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var next_vals = std.StringArrayHashMap([]const u8).init(a);
    next_vals.put("NEW_KEY", "value") catch {};

    const diff = diffValues(a, null, &next_vals);
    try std.testing.expectEqual(@as(usize, 1), diff.added.len);
    try std.testing.expectEqualStrings("NEW_KEY", diff.added[0]);
}

test "diff: removed keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prev_vals = std.StringArrayHashMap([]const u8).init(a);
    prev_vals.put("OLD_KEY", "value") catch {};

    const diff = diffValues(a, &prev_vals, null);
    try std.testing.expectEqual(@as(usize, 1), diff.removed.len);
    try std.testing.expectEqualStrings("OLD_KEY", diff.removed[0]);
}

test "diff: changed keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prev_vals = std.StringArrayHashMap([]const u8).init(a);
    prev_vals.put("KEY", "old") catch {};

    var next_vals = std.StringArrayHashMap([]const u8).init(a);
    next_vals.put("KEY", "new") catch {};

    const diff = diffValues(a, &prev_vals, &next_vals);
    try std.testing.expectEqual(@as(usize, 0), diff.added.len);
    try std.testing.expectEqual(@as(usize, 0), diff.removed.len);
    try std.testing.expectEqual(@as(usize, 1), diff.changed.len);
    try std.testing.expectEqualStrings("KEY", diff.changed[0]);
}

test "diff: mixed add/remove/change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prev_vals = std.StringArrayHashMap([]const u8).init(a);
    prev_vals.put("SAME", "val") catch {};
    prev_vals.put("CHANGED", "old") catch {};
    prev_vals.put("REMOVED", "gone") catch {};

    var next_vals = std.StringArrayHashMap([]const u8).init(a);
    next_vals.put("SAME", "val") catch {};
    next_vals.put("CHANGED", "new") catch {};
    next_vals.put("ADDED", "fresh") catch {};

    const diff = diffValues(a, &prev_vals, &next_vals);
    try std.testing.expectEqual(@as(usize, 1), diff.added.len);
    try std.testing.expectEqual(@as(usize, 1), diff.removed.len);
    try std.testing.expectEqual(@as(usize, 1), diff.changed.len);
}
