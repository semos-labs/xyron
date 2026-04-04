// project/explain.zig — Context introspection engine.
//
// Consumes real provenance from the context engine to explain
// where values come from, what was overridden, and what is missing.
// Does NOT re-merge env or re-parse manifests.

const std = @import("std");
const ctx = @import("context.zig");
const model = @import("model.zig");
const resolver = @import("resolver.zig");
const loader = @import("loader.zig");

// =============================================================================
// Result types
// =============================================================================

pub const ExplainMode = enum { summary, key };

pub const SourceSummary = struct {
    kind: ctx.SourceKind,
    name: []const u8,
    status: ctx.SourceStatus,
    key_count: usize,
};

pub const SummaryResult = struct {
    project_name: ?[]const u8,
    project_root: []const u8,
    context_status: enum { valid, invalid, no_project },
    sources: []const SourceSummary = &.{},
    total_values: usize = 0,
    project_values: usize = 0,
    missing_required: []const []const u8 = &.{},
    warnings: []const []const u8 = &.{},
    fingerprint: u64 = 0,
};

pub const KeyResult = struct {
    key: []const u8,
    present: bool,
    required: bool,
    display_value: []const u8,
    redacted: bool = false,
    winner_source: ?ctx.SourceKind = null,
    winner_source_name: []const u8 = "",
    was_overridden: bool = false,
    candidates: []const ctx.ProvenanceCandidate = &.{},
    project_name: ?[]const u8 = null,
    project_root: []const u8 = "",
};

// =============================================================================
// Sensitive key detection
// =============================================================================

const sensitive_patterns = [_][]const u8{
    "SECRET", "TOKEN", "KEY", "PASSWORD", "PASSWD", "PWD",
    "CREDENTIAL", "AUTH", "PRIVATE",
};

fn isSensitiveKey(key: []const u8) bool {
    // Convert to uppercase mental model — check if key contains sensitive patterns
    for (sensitive_patterns) |pattern| {
        if (containsIgnoreCase(key, pattern)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            const hu = if (hc >= 'a' and hc <= 'z') hc - 32 else hc;
            const nu = if (nc >= 'a' and nc <= 'z') nc - 32 else nc;
            if (hu != nu) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn redactValue(allocator: std.mem.Allocator, value: []const u8) []const u8 {
    if (value.len == 0) return "";
    if (value.len <= 4) return "****";
    // Show first 2 and last 2 chars
    return std.fmt.allocPrint(allocator, "{s}****{s}", .{
        value[0..2],
        value[value.len - 2 ..],
    }) catch "****";
}

// =============================================================================
// Explain functions
// =============================================================================

/// Build a summary explanation of the active context.
pub fn explainSummary(allocator: std.mem.Allocator) SummaryResult {
    const load_result = loader.loadFromCwd(allocator);

    if (load_result.status == .not_found) {
        return .{
            .project_name = null,
            .project_root = "",
            .context_status = .no_project,
        };
    }

    if (load_result.status == .invalid) {
        return .{
            .project_name = null,
            .project_root = load_result.resolution.project_root orelse "",
            .context_status = .invalid,
            .warnings = load_result.errors,
        };
    }

    const mdl = load_result.model.?;
    const sys_env = buildSystemEnv(allocator);
    const empty_ovr = resolver.EnvSource{ .keys = &.{}, .values = &.{} };
    const resolved = resolver.resolveContext(allocator, &mdl, &sys_env, &empty_ovr);

    // Build source summaries
    var sources: std.ArrayListUnmanaged(SourceSummary) = .{};
    for (resolved.env_sources) |src| {
        sources.append(allocator, .{
            .kind = src.source_kind,
            .name = src.source_name,
            .status = src.status,
            .key_count = src.loaded_keys.len,
        }) catch {};
    }

    // Count project-specific values
    var project_values: usize = 0;
    for (resolved.provenance.values()) |prov| {
        if (prov.winner_source != .system) project_values += 1;
    }

    return .{
        .project_name = resolved.project_name,
        .project_root = resolved.project_root,
        .context_status = .valid,
        .sources = sources.toOwnedSlice(allocator) catch &.{},
        .total_values = resolved.values.count(),
        .project_values = project_values,
        .missing_required = resolved.missing_required,
        .warnings = resolved.warnings,
        .fingerprint = resolved.fingerprint,
    };
}

/// Explain a single key in the active context.
pub fn explainKey(allocator: std.mem.Allocator, key: []const u8) KeyResult {
    const load_result = loader.loadFromCwd(allocator);

    if (load_result.status != .valid) {
        return .{
            .key = key,
            .present = false,
            .required = false,
            .display_value = "",
            .project_root = load_result.resolution.project_root orelse "",
        };
    }

    const mdl = load_result.model.?;
    const sys_env = buildSystemEnv(allocator);
    const empty_ovr = resolver.EnvSource{ .keys = &.{}, .values = &.{} };
    const resolved = resolver.resolveContext(allocator, &mdl, &sys_env, &empty_ovr);

    // Check if key is required
    var required = false;
    for (mdl.secrets.required) |req| {
        if (std.mem.eql(u8, req, key)) {
            required = true;
            break;
        }
    }

    // Look up provenance
    if (resolved.provenance.get(key)) |prov| {
        const sensitive = isSensitiveKey(key);
        const display = if (sensitive)
            redactValue(allocator, prov.final_value)
        else
            prov.final_value;

        return .{
            .key = key,
            .present = true,
            .required = required,
            .display_value = display,
            .redacted = sensitive,
            .winner_source = prov.winner_source,
            .winner_source_name = prov.winner_source_name,
            .was_overridden = prov.was_overridden,
            .candidates = prov.candidates,
            .project_name = resolved.project_name,
            .project_root = resolved.project_root,
        };
    }

    // Key not found
    return .{
        .key = key,
        .present = false,
        .required = required,
        .display_value = "",
        .project_name = resolved.project_name,
        .project_root = resolved.project_root,
    };
}

// =============================================================================
// Helpers
// =============================================================================

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

test "isSensitiveKey detects patterns" {
    try std.testing.expect(isSensitiveKey("API_KEY"));
    try std.testing.expect(isSensitiveKey("jwt_secret"));
    try std.testing.expect(isSensitiveKey("DB_PASSWORD"));
    try std.testing.expect(isSensitiveKey("AUTH_TOKEN"));
    try std.testing.expect(!isSensitiveKey("PORT"));
    try std.testing.expect(!isSensitiveKey("DATABASE_URL"));
    try std.testing.expect(!isSensitiveKey("APP_NAME"));
}

test "redactValue short" {
    const r = redactValue(std.testing.allocator, "ab");
    try std.testing.expectEqualStrings("****", r);
}

test "redactValue long" {
    const r = redactValue(std.testing.allocator, "mysecretvalue");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.startsWith(u8, r, "my"));
    try std.testing.expect(std.mem.endsWith(u8, r, "ue"));
    try std.testing.expect(std.mem.indexOf(u8, r, "****") != null);
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("API_KEY", "KEY"));
    try std.testing.expect(containsIgnoreCase("api_key", "KEY"));
    try std.testing.expect(containsIgnoreCase("MY_SECRET_VAR", "SECRET"));
    try std.testing.expect(!containsIgnoreCase("PORT", "KEY"));
}
