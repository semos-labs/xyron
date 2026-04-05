// project/context.zig — Context engine types.
//
// Defines the resolved context model, provenance tracking, session state,
// transitions, and diffing. This is the type foundation for the context
// engine — the resolver and session logic import these types.

const std = @import("std");

// =============================================================================
// Source tracking
// =============================================================================

pub const SourceKind = enum {
    system,
    env_file,
    manifest, // [env.values] in xyron.toml
    override,
};

pub const SourceStatus = enum {
    loaded,
    file_not_found,
    read_error,
    parse_error,
};

/// Result of loading a single context source (env file, system, override layer).
pub const ContextSourceResult = struct {
    source_kind: SourceKind,
    source_name: []const u8,
    source_path: ?[]const u8 = null,
    loaded_keys: []const []const u8 = &.{},
    status: SourceStatus,
    warnings: []const []const u8 = &.{},
    errors: []const []const u8 = &.{},
};

// =============================================================================
// Provenance — where each env value came from
// =============================================================================

/// A single candidate value from one source.
pub const ProvenanceCandidate = struct {
    source_kind: SourceKind,
    source_name: []const u8,
    value: []const u8,
};

/// Full provenance for a single env key.
pub const ValueProvenance = struct {
    key: []const u8,
    final_value: []const u8,
    winner_source: SourceKind,
    winner_source_name: []const u8,
    candidates: []const ProvenanceCandidate = &.{},
    was_overridden: bool = false,
};

// =============================================================================
// Resolved context — the merged result
// =============================================================================

pub const ResolvedContext = struct {
    project_id: []const u8,
    project_root: []const u8,
    project_name: ?[]const u8 = null,

    /// Final merged values (key -> value).
    values: std.StringArrayHashMap([]const u8),

    /// Provenance for each key (key -> provenance).
    provenance: std.StringArrayHashMap(ValueProvenance),

    /// Results from loading each source.
    env_sources: []const ContextSourceResult = &.{},

    /// Required secret keys that are missing from final values.
    missing_required: []const []const u8 = &.{},

    warnings: []const []const u8 = &.{},
    errors: []const []const u8 = &.{},

    /// Stable fingerprint of the resolved context. Changes when values change.
    fingerprint: u64 = 0,
};

// =============================================================================
// Active context — session-scoped state
// =============================================================================

pub const ProjectStatus = enum {
    no_project,
    valid_context,
    invalid_context,
};

pub const ActiveContext = struct {
    session_id: u64,
    resolved: ?ResolvedContext = null,
    project_status: ProjectStatus = .no_project,
    project_id: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
    activated_at: i64 = 0,
    generation: u64 = 0,
    warnings: []const []const u8 = &.{},
    errors: []const []const u8 = &.{},
};

// =============================================================================
// Context transitions
// =============================================================================

pub const TransitionKind = enum {
    enter_project,
    leave_project,
    switch_project,
    stay_in_project,
    reload_project,
    stay_outside_project,
};

pub const ContextTransition = struct {
    kind: TransitionKind,
    prev_project_id: ?[]const u8 = null,
    next_project_id: ?[]const u8 = null,
    diff: ?ContextDiff = null,
};

// =============================================================================
// Context diffing
// =============================================================================

pub const ContextDiff = struct {
    added: []const []const u8 = &.{},
    removed: []const []const u8 = &.{},
    changed: []const []const u8 = &.{},
};

// =============================================================================
// Tests
// =============================================================================

test "ProjectStatus values" {
    try std.testing.expectEqual(ProjectStatus.no_project, ProjectStatus.no_project);
    try std.testing.expectEqual(ProjectStatus.valid_context, ProjectStatus.valid_context);
}

test "TransitionKind values" {
    const t = ContextTransition{ .kind = .enter_project };
    try std.testing.expectEqual(TransitionKind.enter_project, t.kind);
}

test "ContextDiff default empty" {
    const d = ContextDiff{};
    try std.testing.expectEqual(@as(usize, 0), d.added.len);
    try std.testing.expectEqual(@as(usize, 0), d.removed.len);
    try std.testing.expectEqual(@as(usize, 0), d.changed.len);
}

test "ActiveContext default state" {
    const ac = ActiveContext{ .session_id = 1 };
    try std.testing.expectEqual(ProjectStatus.no_project, ac.project_status);
    try std.testing.expect(ac.resolved == null);
    try std.testing.expect(ac.project_id == null);
}
