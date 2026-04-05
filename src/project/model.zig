// project/model.zig — Normalized project model types.
//
// These types are the ONLY representation of project configuration
// used outside the manifest parser. No raw TOML leaks past this layer.

const std = @import("std");

// =============================================================================
// Resolution — result of finding a project root
// =============================================================================

pub const ResolutionStatus = enum {
    found,
    not_found,
    err,
};

pub const ProjectResolution = struct {
    input_path: []const u8,
    normalized_input_path: []const u8,
    project_root: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    status: ResolutionStatus,
    trace: []const []const u8 = &.{},
    error_msg: ?[]const u8 = null,
};

// =============================================================================
// Manifest — result of reading and parsing xyron.toml
// =============================================================================

pub const ManifestStatus = enum {
    ok,
    read_error,
    parse_error,
};

pub const ManifestLoadResult = struct {
    manifest_path: []const u8,
    raw_content: ?[]const u8 = null,
    status: ManifestStatus,
    error_msg: ?[]const u8 = null,
    error_line: usize = 0,
};

// =============================================================================
// Project model — normalized config
// =============================================================================

pub const Command = struct {
    name: []const u8,
    command: []const u8,
    cwd: []const u8, // defaults to project root
};

pub const Service = struct {
    name: []const u8,
    command: []const u8,
    cwd: []const u8, // defaults to project root
};

pub const ProjectInfo = struct {
    name: ?[]const u8 = null,
};

pub const EnvValue = struct {
    key: []const u8,
    raw_value: []const u8, // may contain ${secret:NAME} patterns
};

pub const EnvConfig = struct {
    sources: []const []const u8 = &.{},
    values: []const EnvValue = &.{},
};

pub const SecretsConfig = struct {
    required: []const []const u8 = &.{},
};

pub const ProjectModel = struct {
    root_path: []const u8,
    project_id: []const u8,
    project: ProjectInfo = .{},
    commands: []const Command = &.{},
    env: EnvConfig = .{},
    secrets: SecretsConfig = .{},
    services: []const Service = &.{},
};

// =============================================================================
// Unified load result
// =============================================================================

pub const LoadStatus = enum {
    valid,
    invalid,
    not_found,
};

pub const ProjectModelLoadResult = struct {
    resolution: ProjectResolution,
    manifest: ?ManifestLoadResult = null,
    model: ?ProjectModel = null,
    status: LoadStatus,
    errors: []const []const u8 = &.{},
    warnings: []const []const u8 = &.{},
};

// =============================================================================
// Tests
// =============================================================================

test "default model has empty collections" {
    const model = ProjectModel{
        .root_path = "/tmp/test",
        .project_id = "/tmp/test",
    };
    try std.testing.expectEqual(@as(usize, 0), model.commands.len);
    try std.testing.expectEqual(@as(usize, 0), model.services.len);
    try std.testing.expectEqual(@as(usize, 0), model.env.sources.len);
    try std.testing.expectEqual(@as(usize, 0), model.secrets.required.len);
    try std.testing.expect(model.project.name == null);
}

test "resolution status values" {
    const r = ProjectResolution{
        .input_path = ".",
        .normalized_input_path = "/tmp",
        .status = .not_found,
    };
    try std.testing.expectEqual(ResolutionStatus.not_found, r.status);
}
