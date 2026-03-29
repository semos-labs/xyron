/// Fuzzy matching and scoring.
/// Ported from Attyx (~/Projects/attyx/src/finder/fuzzy_match.zig).
/// Pure, no allocations, no dependencies beyond std.
const std = @import("std");

pub const max_positions = 64;

pub const Score = struct {
    value: i32,
    matched: bool,
    positions: [max_positions]u8,
    match_count: u8,
};

// Scoring constants (fzf-inspired)
const bonus_sequential: i32 = 16;
const bonus_separator: i32 = 24;
const bonus_first_char: i32 = 16;
const bonus_exact_basename: i32 = 100;
const bonus_basename_prefix: i32 = 50;
const penalty_gap: i32 = -3;
const penalty_leading: i32 = -1;
const penalty_trailing: i32 = -1;

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '-' or ch == '_' or ch == '.';
}

/// Full scoring with match positions.
pub fn score(candidate: []const u8, query: []const u8) Score {
    var result = Score{
        .value = 0,
        .matched = false,
        .positions = undefined,
        .match_count = 0,
    };

    if (query.len == 0) {
        result.matched = true;
        return result;
    }
    if (candidate.len == 0 or query.len > candidate.len) return result;
    if (query.len > max_positions) return result;

    var qi: usize = 0;
    var positions: [max_positions]u8 = undefined;

    for (candidate, 0..) |ch, ci| {
        if (qi < query.len and toLower(ch) == toLower(query[qi])) {
            if (ci <= std.math.maxInt(u8)) {
                positions[qi] = @intCast(ci);
            }
            qi += 1;
        }
    }

    if (qi < query.len) return result;

    result.matched = true;
    result.match_count = @intCast(query.len);
    @memcpy(result.positions[0..query.len], positions[0..query.len]);

    var s: i32 = 0;

    s += @as(i32, @intCast(positions[0])) * penalty_leading;

    for (0..query.len) |i| {
        const pos = positions[i];

        if (pos == 0) s += bonus_first_char;

        if (pos > 0 and isSeparator(candidate[pos - 1])) {
            s += bonus_separator;
        }

        if (i > 0) {
            const prev_pos = positions[i - 1];
            if (pos == prev_pos + 1) {
                s += bonus_sequential;
            } else {
                const gap: i32 = @as(i32, @intCast(pos)) - @as(i32, @intCast(prev_pos)) - 1;
                s += gap * penalty_gap;
            }
        }
    }

    const last_pos: i32 = @intCast(positions[query.len - 1]);
    const trailing: i32 = @as(i32, @intCast(candidate.len)) - last_pos - 1;
    s += trailing * penalty_trailing;

    // Basename-aware bonuses
    const basename_start = if (std.mem.lastIndexOfScalar(u8, candidate, '/')) |sep| sep + 1 else 0;
    const basename_len = candidate.len - basename_start;

    if (basename_len == query.len) {
        var exact = true;
        for (0..query.len) |ei| {
            if (toLower(candidate[basename_start + ei]) != toLower(query[ei])) {
                exact = false;
                break;
            }
        }
        if (exact) s += bonus_exact_basename;
    } else if (basename_len > query.len) {
        var prefix = true;
        for (0..query.len) |ei| {
            if (toLower(candidate[basename_start + ei]) != toLower(query[ei])) {
                prefix = false;
                break;
            }
        }
        if (prefix) s += bonus_basename_prefix;
    }

    result.value = s;
    return result;
}

/// Simplified scoring: returns just the score or null if no match.
pub fn matchScore(candidate: []const u8, query: []const u8) ?i32 {
    const result = score(candidate, query);
    if (!result.matched) return null;
    return result.value;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "empty query matches everything" {
    const result = score("anything", "");
    try std.testing.expect(result.matched);
}

test "exact match scores high" {
    const result = score("hello", "hello");
    try std.testing.expect(result.matched);
    try std.testing.expect(result.value > 0);
}

test "prefix beats gap" {
    const prefix = score("project", "pro");
    const gap = score("parador", "pro");
    try std.testing.expect(prefix.value > gap.value);
}

test "separator bonus" {
    const boundary = score("src/finder", "finder");
    const middle = score("pathfinder", "finder");
    try std.testing.expect(boundary.value > middle.value);
}

test "no match" {
    const result = score("hello", "xyz");
    try std.testing.expect(!result.matched);
}

test "case insensitive" {
    const result = score("HelloWorld", "helloworld");
    try std.testing.expect(result.matched);
}

test "matchScore convenience" {
    try std.testing.expect(matchScore("hello", "hel") != null);
    try std.testing.expect(matchScore("hello", "xyz") == null);
}
