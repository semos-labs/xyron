// correction.zig — "Did you mean?" command correction.
//
// When a command exits 127 (not found), suggests the closest matching
// command from PATH and builtins using Levenshtein distance.

const std = @import("std");
const builtins = @import("builtins.zig");
const environ_mod = @import("environ.zig");

const MAX_DISTANCE: usize = 3; // max edit distance to suggest

/// Check if a command name has a close match. Returns the suggestion or null.
pub fn suggest(cmd: []const u8, env: *const environ_mod.Environ) ?[]const u8 {
    if (cmd.len < 2) return null;

    var best_dist: usize = MAX_DISTANCE + 1;

    // Check builtins first
    const builtin_names = [_][]const u8{
        "cd", "pwd", "exit", "export", "unset", "env", "which", "type",
        "history", "jobs", "fg", "bg", "alias", "exec", "ls", "ps",
        "json", "query", "select", "where", "sort", "csv", "fz",
        "migrate", "popup", "inspect", "jump", "j", "clear",
    };
    for (builtin_names) |name| {
        const d = levenshtein(cmd, name);
        if (d < best_dist) {
            best_dist = d;
            @memcpy(suggestion_buf[0..name.len], name);
            suggestion_len = name.len;
        }
    }

    // Scan PATH for close matches
    const path_val = env.get("PATH") orelse "";
    var path_iter = std.mem.splitScalar(u8, path_val, ':');
    var dirs_checked: usize = 0;

    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;
        dirs_checked += 1;
        if (dirs_checked > 50) break; // limit scan

        var d = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch continue;
        defer d.close();

        var iter = d.iterate();
        var entries_checked: usize = 0;
        while (iter.next() catch null) |entry| {
            entries_checked += 1;
            if (entries_checked > 200) break; // limit per dir

            // Quick filter: names with wildly different lengths can't match
            if (entry.name.len > cmd.len + MAX_DISTANCE or
                entry.name.len + MAX_DISTANCE < cmd.len) continue;

            const dist = levenshtein(cmd, entry.name);
            if (dist < best_dist) {
                best_dist = dist;
                const len = @min(entry.name.len, suggestion_buf.len);
                @memcpy(suggestion_buf[0..len], entry.name[0..len]);
                suggestion_len = len;
            }
        }
    }

    if (best_dist <= MAX_DISTANCE and suggestion_len > 0) {
        return suggestion_buf[0..suggestion_len];
    }
    return null;
}

// Static buffer for the suggestion (avoids allocation)
var suggestion_buf: [256]u8 = undefined;
var suggestion_len: usize = 0;

/// Levenshtein edit distance between two strings.
/// Bounded: returns MAX_DISTANCE + 1 early if distance exceeds MAX_DISTANCE.
fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    // Early exit on length difference
    const len_diff = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (len_diff > MAX_DISTANCE) return MAX_DISTANCE + 1;

    // Single-row DP (only need previous row)
    var row: [64]usize = undefined;
    if (b.len >= 64) return MAX_DISTANCE + 1;

    for (0..b.len + 1) |j| row[j] = j;

    for (a, 0..) |ca, i| {
        var prev = i;
        row[0] = i + 1;
        var min_in_row: usize = row[0];

        for (b, 0..) |cb, j| {
            const cost: usize = if (toLower(ca) == toLower(cb)) 0 else 1;
            const ins = row[j + 1] + 1;
            const del = row[j] + 1;
            const sub = prev + cost;
            prev = row[j + 1];
            row[j + 1] = @min(ins, @min(del, sub));
            min_in_row = @min(min_in_row, row[j + 1]);
        }

        // If minimum in this row exceeds threshold, bail early
        if (min_in_row > MAX_DISTANCE) return MAX_DISTANCE + 1;
    }

    return row[b.len];
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "levenshtein identical" {
    try std.testing.expectEqual(@as(usize, 0), levenshtein("git", "git"));
}

test "levenshtein single edit" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("gti", "git"));
    try std.testing.expectEqual(@as(usize, 1), levenshtein("cta", "cat"));
}

test "levenshtein case insensitive" {
    try std.testing.expectEqual(@as(usize, 0), levenshtein("Git", "git"));
}

test "levenshtein too far" {
    try std.testing.expect(levenshtein("abcdef", "xyz") > MAX_DISTANCE);
}

test "suggest finds close builtin" {
    // Can't fully test without env, but levenshtein works
    try std.testing.expectEqual(@as(usize, 1), levenshtein("gti", "git"));
    try std.testing.expectEqual(@as(usize, 1), levenshtein("exti", "exit"));
}
