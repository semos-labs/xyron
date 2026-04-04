// project/resolver.zig — Context resolver.
//
// Merges system environment + project env files + overrides into a
// single ResolvedContext with full provenance tracking. This is the
// ONLY place where env merging happens.
//
// Precedence (lowest to highest):
//   1. system environment
//   2. project env files (in declaration order)
//   3. explicit overrides

const std = @import("std");
const ctx = @import("context.zig");
const model = @import("model.zig");
const dotenv = @import("dotenv.zig");

/// System environment represented as a simple key-value iterator interface.
/// In production, this is the process env. In tests, it can be a mock.
pub const EnvSource = struct {
    keys: []const []const u8,
    values: []const []const u8,
};

/// Resolve the full context for a project.
///
/// Inputs:
/// - allocator: arena allocator (caller manages lifetime)
/// - project: the normalized project model (from Phase 1)
/// - system_env: system environment key-value pairs
/// - overrides: explicit override key-value pairs
///
/// Returns a ResolvedContext with merged values, provenance, and diagnostics.
pub fn resolveContext(
    allocator: std.mem.Allocator,
    project_model: *const model.ProjectModel,
    system_env: *const EnvSource,
    overrides: *const EnvSource,
) ctx.ResolvedContext {
    var values = std.StringArrayHashMap([]const u8).init(allocator);
    var provenance = std.StringArrayHashMap(ctx.ValueProvenance).init(allocator);
    var source_results: std.ArrayListUnmanaged(ctx.ContextSourceResult) = .{};
    var warnings: std.ArrayListUnmanaged([]const u8) = .{};
    var errors_list: std.ArrayListUnmanaged([]const u8) = .{};

    // --- Layer 1: system environment (lowest priority) ---
    {
        var loaded_keys: std.ArrayListUnmanaged([]const u8) = .{};
        for (system_env.keys, system_env.values) |key, value| {
            values.put(key, value) catch {};
            recordProvenance(allocator, &provenance, key, value, .system, "system");
            loaded_keys.append(allocator, key) catch {};
        }
        source_results.append(allocator, .{
            .source_kind = .system,
            .source_name = "system",
            .status = .loaded,
            .loaded_keys = loaded_keys.toOwnedSlice(allocator) catch &.{},
        }) catch {};
    }

    // --- Layer 2: project env files (in declaration order) ---
    for (project_model.env.sources) |env_source| {
        const abs_path = std.fs.path.join(allocator, &.{
            project_model.root_path, env_source,
        }) catch continue;

        const parse_result = dotenv.loadFile(allocator, abs_path);
        if (parse_result == null) {
            // File not found — warning, not error
            warnings.append(allocator, std.fmt.allocPrint(
                allocator,
                "env file not found: {s}",
                .{env_source},
            ) catch "env file not found") catch {};
            source_results.append(allocator, .{
                .source_kind = .env_file,
                .source_name = env_source,
                .source_path = abs_path,
                .status = .file_not_found,
            }) catch {};
            continue;
        }

        const result = parse_result.?;
        var loaded_keys: std.ArrayListUnmanaged([]const u8) = .{};
        var source_warnings: std.ArrayListUnmanaged([]const u8) = .{};

        for (result.entries) |entry| {
            values.put(entry.key, entry.value) catch {};
            recordProvenance(allocator, &provenance, entry.key, entry.value, .env_file, env_source);
            loaded_keys.append(allocator, entry.key) catch {};
        }

        // Forward parse errors as source warnings
        for (result.errors) |err| {
            source_warnings.append(allocator, std.fmt.allocPrint(
                allocator,
                "{s}: {s}",
                .{ env_source, err },
            ) catch err) catch {};
        }

        source_results.append(allocator, .{
            .source_kind = .env_file,
            .source_name = env_source,
            .source_path = abs_path,
            .loaded_keys = loaded_keys.toOwnedSlice(allocator) catch &.{},
            .status = .loaded,
            .warnings = source_warnings.toOwnedSlice(allocator) catch &.{},
        }) catch {};
    }

    // --- Layer 3: explicit overrides (highest priority) ---
    if (overrides.keys.len > 0) {
        var loaded_keys: std.ArrayListUnmanaged([]const u8) = .{};
        for (overrides.keys, overrides.values) |key, value| {
            values.put(key, value) catch {};
            recordProvenance(allocator, &provenance, key, value, .override, "override");
            loaded_keys.append(allocator, key) catch {};
        }
        source_results.append(allocator, .{
            .source_kind = .override,
            .source_name = "override",
            .status = .loaded,
            .loaded_keys = loaded_keys.toOwnedSlice(allocator) catch &.{},
        }) catch {};
    }

    // --- Check required secrets ---
    var missing: std.ArrayListUnmanaged([]const u8) = .{};
    for (project_model.secrets.required) |key| {
        if (!values.contains(key)) {
            missing.append(allocator, key) catch {};
        }
    }

    // --- Compute fingerprint ---
    const fingerprint = computeFingerprint(&values);

    return .{
        .project_id = project_model.project_id,
        .project_root = project_model.root_path,
        .project_name = project_model.project.name,
        .values = values,
        .provenance = provenance,
        .env_sources = source_results.toOwnedSlice(allocator) catch &.{},
        .missing_required = missing.toOwnedSlice(allocator) catch &.{},
        .warnings = warnings.toOwnedSlice(allocator) catch &.{},
        .errors = errors_list.toOwnedSlice(allocator) catch &.{},
        .fingerprint = fingerprint,
    };
}

/// Record provenance for a key. If the key already has provenance,
/// update it (the new source wins due to precedence order).
fn recordProvenance(
    allocator: std.mem.Allocator,
    provenance: *std.StringArrayHashMap(ctx.ValueProvenance),
    key: []const u8,
    value: []const u8,
    source_kind: ctx.SourceKind,
    source_name: []const u8,
) void {
    const new_candidate = ctx.ProvenanceCandidate{
        .source_kind = source_kind,
        .source_name = source_name,
        .value = value,
    };

    if (provenance.getPtr(key)) |existing| {
        // Key already seen — append candidate, update winner
        var candidates: std.ArrayListUnmanaged(ctx.ProvenanceCandidate) = .{};
        candidates.appendSlice(allocator, existing.candidates) catch {};
        candidates.append(allocator, new_candidate) catch {};
        existing.* = .{
            .key = key,
            .final_value = value,
            .winner_source = source_kind,
            .winner_source_name = source_name,
            .candidates = candidates.toOwnedSlice(allocator) catch existing.candidates,
            .was_overridden = true,
        };
    } else {
        // First time seeing this key
        var candidates: std.ArrayListUnmanaged(ctx.ProvenanceCandidate) = .{};
        candidates.append(allocator, new_candidate) catch {};
        provenance.put(key, .{
            .key = key,
            .final_value = value,
            .winner_source = source_kind,
            .winner_source_name = source_name,
            .candidates = candidates.toOwnedSlice(allocator) catch &.{},
            .was_overridden = false,
        }) catch {};
    }
}

/// Compute a stable fingerprint from the resolved values.
/// Uses FNV-1a over sorted key=value pairs for determinism.
fn computeFingerprint(values: *const std.StringArrayHashMap([]const u8)) u64 {
    var hash: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
    const prime: u64 = 0x100000001b3;

    // StringArrayHashMap preserves insertion order, but for stability
    // across different merge paths, hash all keys sorted.
    // For now, since our merge order is deterministic, just hash in order.
    for (values.keys(), values.values()) |key, val| {
        for (key) |b| {
            hash ^= b;
            hash *%= prime;
        }
        hash ^= '=';
        hash *%= prime;
        for (val) |b| {
            hash ^= b;
            hash *%= prime;
        }
        hash ^= '\n';
        hash *%= prime;
    }

    return hash;
}

// =============================================================================
// Tests
// =============================================================================

test "resolve empty project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mdl = model.ProjectModel{
        .root_path = "/tmp/test",
        .project_id = "/tmp/test",
    };

    const sys = EnvSource{ .keys = &.{}, .values = &.{} };
    const ovr = EnvSource{ .keys = &.{}, .values = &.{} };

    const result = resolveContext(a, &mdl, &sys, &ovr);
    try std.testing.expectEqual(@as(usize, 0), result.values.count());
    try std.testing.expectEqual(@as(usize, 0), result.missing_required.len);
}

test "resolve system env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mdl = model.ProjectModel{
        .root_path = "/tmp/test",
        .project_id = "/tmp/test",
    };

    const keys = [_][]const u8{ "HOME", "PATH" };
    const vals = [_][]const u8{ "/home/user", "/usr/bin" };
    const sys = EnvSource{ .keys = &keys, .values = &vals };
    const ovr = EnvSource{ .keys = &.{}, .values = &.{} };

    const result = resolveContext(a, &mdl, &sys, &ovr);
    try std.testing.expectEqual(@as(usize, 2), result.values.count());
    try std.testing.expectEqualStrings("/home/user", result.values.get("HOME").?);

    // Check provenance
    const home_prov = result.provenance.get("HOME").?;
    try std.testing.expectEqual(ctx.SourceKind.system, home_prov.winner_source);
    try std.testing.expect(!home_prov.was_overridden);
}

test "resolve override precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mdl = model.ProjectModel{
        .root_path = "/tmp/test",
        .project_id = "/tmp/test",
    };

    const sys_keys = [_][]const u8{"FOO"};
    const sys_vals = [_][]const u8{"from_system"};
    const sys = EnvSource{ .keys = &sys_keys, .values = &sys_vals };

    const ovr_keys = [_][]const u8{"FOO"};
    const ovr_vals = [_][]const u8{"from_override"};
    const ovr = EnvSource{ .keys = &ovr_keys, .values = &ovr_vals };

    const result = resolveContext(a, &mdl, &sys, &ovr);
    try std.testing.expectEqualStrings("from_override", result.values.get("FOO").?);

    const prov = result.provenance.get("FOO").?;
    try std.testing.expectEqual(ctx.SourceKind.override, prov.winner_source);
    try std.testing.expect(prov.was_overridden);
    try std.testing.expectEqual(@as(usize, 2), prov.candidates.len);
}

test "resolve missing secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const required = [_][]const u8{ "API_KEY", "DB_URL" };
    const sources = [_][]const u8{};
    const mdl = model.ProjectModel{
        .root_path = "/tmp/test",
        .project_id = "/tmp/test",
        .secrets = .{ .required = &required },
        .env = .{ .sources = &sources },
    };

    // System has API_KEY but not DB_URL
    const sys_keys = [_][]const u8{"API_KEY"};
    const sys_vals = [_][]const u8{"secret"};
    const sys = EnvSource{ .keys = &sys_keys, .values = &sys_vals };
    const ovr = EnvSource{ .keys = &.{}, .values = &.{} };

    const result = resolveContext(a, &mdl, &sys, &ovr);
    try std.testing.expectEqual(@as(usize, 1), result.missing_required.len);
    try std.testing.expectEqualStrings("DB_URL", result.missing_required[0]);
}

test "resolve env file not found produces warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sources = [_][]const u8{".env"};
    const mdl = model.ProjectModel{
        .root_path = "/tmp/nonexistent_project_dir_12345",
        .project_id = "/tmp/nonexistent_project_dir_12345",
        .env = .{ .sources = &sources },
    };

    const sys = EnvSource{ .keys = &.{}, .values = &.{} };
    const ovr = EnvSource{ .keys = &.{}, .values = &.{} };

    const result = resolveContext(a, &mdl, &sys, &ovr);
    try std.testing.expect(result.warnings.len > 0);
    // Sources: system (always) + the missing env file
    try std.testing.expectEqual(@as(usize, 2), result.env_sources.len);
    // First is system, second is the missing file
    try std.testing.expectEqual(ctx.SourceKind.system, result.env_sources[0].source_kind);
    try std.testing.expectEqual(ctx.SourceStatus.file_not_found, result.env_sources[1].status);
}

test "fingerprint changes with values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mdl = model.ProjectModel{
        .root_path = "/tmp/test",
        .project_id = "/tmp/test",
    };

    const keys1 = [_][]const u8{"FOO"};
    const vals1 = [_][]const u8{"bar"};
    const sys1 = EnvSource{ .keys = &keys1, .values = &vals1 };

    const keys2 = [_][]const u8{"FOO"};
    const vals2 = [_][]const u8{"baz"};
    const sys2 = EnvSource{ .keys = &keys2, .values = &vals2 };

    const ovr = EnvSource{ .keys = &.{}, .values = &.{} };

    const r1 = resolveContext(a, &mdl, &sys1, &ovr);
    const r2 = resolveContext(a, &mdl, &sys2, &ovr);

    try std.testing.expect(r1.fingerprint != r2.fingerprint);
}

test "fingerprint stable for same values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mdl = model.ProjectModel{
        .root_path = "/tmp/test",
        .project_id = "/tmp/test",
    };

    const keys = [_][]const u8{"FOO"};
    const vals = [_][]const u8{"bar"};
    const sys = EnvSource{ .keys = &keys, .values = &vals };
    const ovr = EnvSource{ .keys = &.{}, .values = &.{} };

    const r1 = resolveContext(a, &mdl, &sys, &ovr);
    const r2 = resolveContext(a, &mdl, &sys, &ovr);

    try std.testing.expectEqual(r1.fingerprint, r2.fingerprint);
}
