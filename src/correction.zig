// correction.zig — "Did you mean?" command correction.
//
// When a command exits 127 (not found), suggests the closest matching
// command from PATH and builtins using Levenshtein distance.

const std = @import("std");
const builtins = @import("builtins.zig");
const environ_mod = @import("environ.zig");

const MAX_DISTANCE: usize = 3; // max edit distance to suggest

const MAX_CANDIDATES = 64;

const Candidate = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    score: i32 = -1,
};

/// Check if a command name has a close match. Returns the suggestion or null.
pub fn suggest(cmd: []const u8, env: *const environ_mod.Environ) ?[]const u8 {
    if (cmd.len < 2) return null;

    var candidates: [MAX_CANDIDATES]Candidate = undefined;
    var count: usize = 0;

    // Builtins
    const builtin_names = [_][]const u8{
        "cd", "pwd", "exit", "export", "unset", "env", "which", "type",
        "history", "jobs", "fg", "bg", "alias", "exec", "ls", "ps",
        "json", "query", "select", "where", "sort", "csv", "fz",
        "migrate", "popup", "inspect", "jump", "j", "clear", "xyron",
    };
    for (builtin_names) |name| {
        const sc = matchScore(cmd, name);
        if (sc > 0) addCandidate(&candidates, &count, name, sc);
    }

    // Scan entire PATH
    const path_val = env.get("PATH") orelse "";
    var path_iter = std.mem.splitScalar(u8, path_val, ':');

    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;
        if (!std.fs.path.isAbsolute(dir)) continue;

        var d = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch continue;
        defer d.close();

        var iter = d.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.name.len > cmd.len + MAX_DISTANCE or
                entry.name.len + MAX_DISTANCE < cmd.len) continue;

            const sc = matchScore(cmd, entry.name);
            if (sc > 0) addCandidate(&candidates, &count, entry.name, sc);
        }
    }

    // Pick the best candidate
    if (count == 0) return null;

    var best_idx: usize = 0;
    for (1..count) |i| {
        if (candidates[i].score > candidates[best_idx].score) best_idx = i;
    }

    const winner = &candidates[best_idx];
    @memcpy(suggestion_buf[0..winner.name_len], winner.name[0..winner.name_len]);
    suggestion_len = winner.name_len;
    return suggestion_buf[0..suggestion_len];
}

fn addCandidate(candidates: *[MAX_CANDIDATES]Candidate, count: *usize, name: []const u8, score: i32) void {
    // Deduplicate: if name already exists, keep higher score
    for (candidates[0..count.*]) |*c| {
        if (c.name_len == name.len and std.mem.eql(u8, c.name[0..c.name_len], name)) {
            if (score > c.score) c.score = score;
            return;
        }
    }
    if (count.* >= MAX_CANDIDATES) {
        // Replace the lowest-scoring candidate
        var min_idx: usize = 0;
        for (1..count.*) |i| {
            if (candidates[i].score < candidates[min_idx].score) min_idx = i;
        }
        if (score > candidates[min_idx].score) {
            const len = @min(name.len, 64);
            @memcpy(candidates[min_idx].name[0..len], name[0..len]);
            candidates[min_idx].name_len = len;
            candidates[min_idx].score = score;
        }
        return;
    }
    const len = @min(name.len, 64);
    @memcpy(candidates[count.*].name[0..len], name[0..len]);
    candidates[count.*].name_len = len;
    candidates[count.*].score = score;
    count.* += 1;
}

/// Score a candidate match. Higher is better. Returns -1 for no match.
fn matchScore(cmd: []const u8, candidate: []const u8) i32 {
    const dist = levenshtein(cmd, candidate);
    if (dist > MAX_DISTANCE) return -1;

    // Base: inverse of distance (×4 to make it dominant)
    var score: i32 = (@as(i32, @intCast(MAX_DISTANCE + 1)) - @as(i32, @intCast(dist))) * 4;

    // Shared characters: count how many chars from cmd appear in candidate
    // "gti" vs "git" = 3 shared, "gti" vs "gpg" = 1 shared
    var cmd_used = [_]bool{false} ** 64;
    var cand_used = [_]bool{false} ** 64;
    const cl = @min(cmd.len, 64);
    const nl = @min(candidate.len, 64);
    for (0..cl) |i| {
        for (0..nl) |j| {
            if (!cand_used[j] and !cmd_used[i] and toLower(cmd[i]) == toLower(candidate[j])) {
                cmd_used[i] = true;
                cand_used[j] = true;
                score += 2;
                break;
            }
        }
    }

    // First character matches
    if (cmd.len > 0 and candidate.len > 0 and toLower(cmd[0]) == toLower(candidate[0]))
        score += 3;

    // Same length bonus / length difference penalty
    if (cmd.len == candidate.len) {
        score += 3;
    } else {
        const diff: i32 = @intCast(if (cmd.len > candidate.len) cmd.len - candidate.len else candidate.len - cmd.len);
        score -= diff;
    }

    return score;
}

// Static buffer for the suggestion (avoids allocation)
var suggestion_buf: [256]u8 = undefined;
var suggestion_len: usize = 0;

/// Damerau-Levenshtein distance (supports transpositions as single edits).
/// Case-insensitive. Bounded: returns MAX_DISTANCE + 1 if too far.
fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    const len_diff = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (len_diff > MAX_DISTANCE) return MAX_DISTANCE + 1;
    if (b.len >= 63) return MAX_DISTANCE + 1;

    // Two-row DP for Damerau-Levenshtein
    var prev_prev: [64]usize = undefined; // row i-2
    var prev_row: [64]usize = undefined; // row i-1
    var curr: [64]usize = undefined; // row i

    for (0..b.len + 1) |j| { prev_row[j] = j; prev_prev[j] = j; }

    for (a, 0..) |ca, i| {
        curr[0] = i + 1;

        for (b, 0..) |cb, j| {
            const cost: usize = if (toLower(ca) == toLower(cb)) 0 else 1;
            curr[j + 1] = @min(@min(
                curr[j] + 1, // insert
                prev_row[j + 1] + 1, // delete
            ), prev_row[j] + cost); // substitute

            // Transposition: swap adjacent characters
            if (i > 0 and j > 0 and
                toLower(ca) == toLower(b[j - 1]) and
                toLower(a[i - 1]) == toLower(cb))
            {
                curr[j + 1] = @min(curr[j + 1], prev_prev[j - 1] + 1);
            }
        }

        @memcpy(prev_prev[0..b.len + 1], prev_row[0..b.len + 1]);
        @memcpy(prev_row[0..b.len + 1], curr[0..b.len + 1]);
    }

    return if (curr[b.len] > MAX_DISTANCE) MAX_DISTANCE + 1 else curr[b.len];
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
