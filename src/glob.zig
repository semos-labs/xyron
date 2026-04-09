// glob.zig — Filesystem glob expansion.
//
// Expands patterns containing *, ?, and ** into matching filesystem paths.
// Used by expand.zig after variable/tilde expansion. Patterns without
// metacharacters are never passed here (fast path in expand.zig).

const std = @import("std");
const posix = std.posix;

/// Check if a word contains glob metacharacters (* or ?).
pub fn containsGlob(word: []const u8) bool {
    for (word) |ch| {
        if (ch == '*' or ch == '?') return true;
    }
    return false;
}

/// Expand a glob pattern into matching filesystem paths.
/// Returns sorted matches, or a single-element slice containing the
/// original pattern if nothing matched (no-match = keep literal).
pub fn expand(allocator: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .{};
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    // Split pattern into segments on '/'
    const is_absolute = pattern.len > 0 and pattern[0] == '/';
    var segments: std.ArrayList([]const u8) = .{};
    defer segments.deinit(allocator);

    const start_pat = if (is_absolute) pattern[1..] else pattern;
    var iter = std.mem.splitScalar(u8, start_pat, '/');
    while (iter.next()) |seg| {
        if (seg.len > 0) try segments.append(allocator, seg);
    }

    if (segments.items.len == 0) {
        try results.append(allocator, try allocator.dupe(u8, pattern));
        return results.toOwnedSlice(allocator);
    }

    // Seed: start directory
    const seed: []const u8 = if (is_absolute) "/" else ".";
    var paths: std.ArrayList([]const u8) = .{};
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try paths.append(allocator, try allocator.dupe(u8, seed));

    // Process each pattern segment, expanding the path set
    for (segments.items) |segment| {
        var next_paths: std.ArrayList([]const u8) = .{};
        errdefer {
            for (next_paths.items) |p| allocator.free(p);
            next_paths.deinit(allocator);
        }

        const is_globstar = std.mem.eql(u8, segment, "**");

        for (paths.items) |base| {
            if (is_globstar) {
                // ** matches zero or more directories
                // Zero match: pass base itself through
                try next_paths.append(allocator, try allocator.dupe(u8, base));
                // Recursive match: collect all subdirectories
                try collectRecursiveDirs(allocator, base, &next_paths);
            } else {
                // Normal segment with possible * or ? chars
                try matchSegment(allocator, base, segment, &next_paths);
            }
        }

        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
        paths = next_paths;
    }

    for (paths.items) |path| {
        const display = normalise(path, is_absolute);
        try results.append(allocator, try allocator.dupe(u8, display));
    }

    // No matches → return original pattern as literal
    if (results.items.len == 0) {
        try results.append(allocator, try allocator.dupe(u8, pattern));
        return results.toOwnedSlice(allocator);
    }

    // Sort for deterministic output
    std.mem.sort([]const u8, results.items, {}, lessThanStr);

    return results.toOwnedSlice(allocator);
}

/// Match a single pattern segment against directory entries.
fn matchSegment(
    allocator: std.mem.Allocator,
    base: []const u8,
    segment: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = std.fs.cwd().openDir(base, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        // Hidden files only matched if pattern starts with '.'
        if (entry.name.len > 0 and entry.name[0] == '.' and
            (segment.len == 0 or segment[0] != '.'))
        {
            continue;
        }
        if (matchPattern(segment, entry.name)) {
            try out.append(allocator, try joinPath(allocator, base, entry.name));
        }
    }
}

/// Recursively collect all subdirectories under base (for ** expansion).
fn collectRecursiveDirs(
    allocator: std.mem.Allocator,
    base: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = std.fs.cwd().openDir(base, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        // Skip hidden entries in recursive expansion
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (entry.kind == .directory) {
            const sub = try joinPath(allocator, base, entry.name);
            try out.append(allocator, sub);
            // Recurse — but cap depth to avoid runaway expansion
            const depth = std.mem.count(u8, sub, "/");
            if (depth < 32) {
                try collectRecursiveDirs(allocator, sub, out);
            }
        }
    }
}

/// Pattern matching: supports * (any sequence) and ? (single char).
pub fn matchPattern(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    // Backtracking positions for * matching
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name.len or pi < pattern.len) {
        if (pi < pattern.len) {
            if (pattern[pi] == '*') {
                // Record backtrack point
                star_pi = pi;
                star_ni = ni;
                pi += 1;
                continue;
            }
            if (ni < name.len) {
                if (pattern[pi] == '?' or pattern[pi] == name[ni]) {
                    pi += 1;
                    ni += 1;
                    continue;
                }
            }
        }
        // Mismatch — backtrack to last * if possible
        if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
            if (ni > name.len) return false;
            continue;
        }
        return false;
    }
    return true;
}

/// Join base path with a name. Avoids double slashes.
fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, base, ".")) {
        return allocator.dupe(u8, name);
    }
    if (std.mem.eql(u8, base, "/")) {
        const result = try allocator.alloc(u8, 1 + name.len);
        result[0] = '/';
        @memcpy(result[1..], name);
        return result;
    }
    const result = try allocator.alloc(u8, base.len + 1 + name.len);
    @memcpy(result[0..base.len], base);
    result[base.len] = '/';
    @memcpy(result[base.len + 1 ..], name);
    return result;
}

/// Strip leading "./" for display.
fn normalise(path: []const u8, is_absolute: bool) []const u8 {
    if (is_absolute) return path;
    if (path.len > 2 and path[0] == '.' and path[1] == '/') return path[2..];
    return path;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "containsGlob detects metacharacters" {
    try std.testing.expect(containsGlob("*.txt"));
    try std.testing.expect(containsGlob("file?.log"));
    try std.testing.expect(containsGlob("src/**/*.zig"));
    try std.testing.expect(!containsGlob("plain.txt"));
    try std.testing.expect(!containsGlob("no-meta"));
}

test "matchPattern basic wildcards" {
    try std.testing.expect(matchPattern("*.txt", "hello.txt"));
    try std.testing.expect(matchPattern("*.txt", ".txt"));
    try std.testing.expect(!matchPattern("*.txt", "hello.log"));
    try std.testing.expect(matchPattern("file?.txt", "file1.txt"));
    try std.testing.expect(!matchPattern("file?.txt", "file12.txt"));
    try std.testing.expect(matchPattern("*", "anything"));
    try std.testing.expect(matchPattern("a*b", "ab"));
    try std.testing.expect(matchPattern("a*b", "aXXXb"));
    try std.testing.expect(!matchPattern("a*b", "aXXXc"));
}

test "matchPattern exact" {
    try std.testing.expect(matchPattern("hello", "hello"));
    try std.testing.expect(!matchPattern("hello", "world"));
}

test "matchPattern multiple stars" {
    try std.testing.expect(matchPattern("*.*", "foo.bar"));
    try std.testing.expect(matchPattern("a*b*c", "aXbYc"));
    try std.testing.expect(!matchPattern("a*b*c", "aXbY"));
}
