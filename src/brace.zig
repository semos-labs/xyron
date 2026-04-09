// brace.zig — Brace expansion for shell input.
//
// Expands patterns like {a,b,c} and {1..10} into multiple words.
// Preserves prefix and suffix: pre{A,B}suf → preAsuf preBsuf.
// Supports zero-padded ranges: {01..03} → 01 02 03.

const std = @import("std");

/// Check if a word contains brace expansion patterns.
/// Must have both { and } with either a comma or .. between them.
pub fn containsBrace(word: []const u8) bool {
    const open = std.mem.indexOf(u8, word, "{") orelse return false;
    const close = std.mem.lastIndexOf(u8, word, "}") orelse return false;
    if (close <= open) return false;
    const inner = word[open + 1 .. close];
    return std.mem.indexOf(u8, inner, ",") != null or std.mem.indexOf(u8, inner, "..") != null;
}

/// Expand brace patterns in a single word.
/// Returns multiple words, or a single-element slice if no expansion.
/// Caller owns the returned slice and its contents.
pub fn expand(allocator: std.mem.Allocator, word: []const u8) std.mem.Allocator.Error![]const []const u8 {
    // Find the outermost brace pair (respecting nesting)
    const open = findOuterOpen(word) orelse {
        var result: std.ArrayList([]const u8) = .{};
        try result.append(allocator, try allocator.dupe(u8, word));
        return result.toOwnedSlice(allocator);
    };
    const close = findMatchingClose(word, open) orelse {
        var result: std.ArrayList([]const u8) = .{};
        try result.append(allocator, try allocator.dupe(u8, word));
        return result.toOwnedSlice(allocator);
    };

    const prefix = word[0..open];
    const inner = word[open + 1 .. close];
    const suffix = word[close + 1 ..];

    // Try range expansion first: {N..M}
    if (parseRange(inner)) |range| {
        return expandRange(allocator, prefix, suffix, range);
    }

    // Comma-separated expansion: {a,b,c}
    return expandComma(allocator, prefix, inner, suffix);
}

// ---------------------------------------------------------------------------
// Range expansion: {1..10}, {01..05}, {a..z}
// ---------------------------------------------------------------------------

const Range = struct {
    start: i32,
    end: i32,
    pad_width: usize, // 0 = no padding
    is_char: bool, // true for {a..z}
};

fn parseRange(inner: []const u8) ?Range {
    const sep = std.mem.indexOf(u8, inner, "..") orelse return null;
    const left = inner[0..sep];
    const right = inner[sep + 2 ..];
    if (left.len == 0 or right.len == 0) return null;

    // Character range: {a..z}
    if (left.len == 1 and right.len == 1 and isAlpha(left[0]) and isAlpha(right[0])) {
        return .{
            .start = @intCast(left[0]),
            .end = @intCast(right[0]),
            .pad_width = 0,
            .is_char = true,
        };
    }

    // Numeric range: {1..10}, {01..05}
    const start = std.fmt.parseInt(i32, left, 10) catch return null;
    const end = std.fmt.parseInt(i32, right, 10) catch return null;

    // Zero padding: max of left/right string width
    const pad = @max(left.len, right.len);
    // Only pad if one side has leading zeros
    const do_pad = (left.len > 1 and left[0] == '0') or (right.len > 1 and right[0] == '0');

    return .{
        .start = start,
        .end = end,
        .pad_width = if (do_pad) pad else 0,
        .is_char = false,
    };
}

fn expandRange(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    suffix: []const u8,
    range: Range,
) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .{};
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    const step: i32 = if (range.start <= range.end) 1 else -1;
    var val = range.start;
    while (true) {
        var word: std.ArrayList(u8) = .{};
        errdefer word.deinit(allocator);

        try word.appendSlice(allocator, prefix);
        if (range.is_char) {
            try word.append(allocator, @intCast(@as(u32, @intCast(val))));
        } else if (range.pad_width > 0) {
            var buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "";
            // Pad with leading zeros
            const num_len = s.len;
            if (num_len < range.pad_width) {
                const zeros = range.pad_width - num_len;
                for (0..zeros) |_| try word.append(allocator, '0');
            }
            try word.appendSlice(allocator, s);
        } else {
            var buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "";
            try word.appendSlice(allocator, s);
        }
        try word.appendSlice(allocator, suffix);

        try results.append(allocator, try word.toOwnedSlice(allocator));

        if (val == range.end) break;
        val += step;
    }

    return results.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Comma expansion: {a,b,c}
// ---------------------------------------------------------------------------

fn expandComma(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    inner: []const u8,
    suffix: []const u8,
) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .{};
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    // Split on commas, respecting nested braces
    var parts: std.ArrayList([]const u8) = .{};
    defer parts.deinit(allocator);

    var start: usize = 0;
    var depth: u32 = 0;
    for (inner, 0..) |c, i| {
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            if (depth > 0) depth -= 1;
        } else if (c == ',' and depth == 0) {
            try parts.append(allocator, inner[start..i]);
            start = i + 1;
        }
    }
    try parts.append(allocator, inner[start..]);

    // Build prefix + part + suffix for each, recursively expanding
    for (parts.items) |part| {
        var word: std.ArrayList(u8) = .{};
        try word.appendSlice(allocator, prefix);
        try word.appendSlice(allocator, part);
        try word.appendSlice(allocator, suffix);
        const combined = try word.toOwnedSlice(allocator);

        // Recurse for nested braces
        if (containsBrace(combined)) {
            const sub_results = try expand(allocator, combined);
            defer allocator.free(sub_results);
            allocator.free(combined);
            for (sub_results) |sub| {
                try results.append(allocator, sub);
            }
        } else {
            try results.append(allocator, combined);
        }
    }

    return results.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Find the first '{' that is part of a valid brace expression (has matching '}').
fn findOuterOpen(word: []const u8) ?usize {
    for (word, 0..) |c, i| {
        if (c == '{') {
            if (findMatchingClose(word, i) != null) return i;
        }
    }
    return null;
}

/// Find the matching '}' for a '{' at position `open`, respecting nesting.
fn findMatchingClose(word: []const u8, open: usize) ?usize {
    var depth: u32 = 0;
    var i = open;
    while (i < word.len) {
        if (word[i] == '{') {
            depth += 1;
        } else if (word[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "containsBrace detects patterns" {
    try std.testing.expect(containsBrace("{a,b,c}"));
    try std.testing.expect(containsBrace("file{1..3}.txt"));
    try std.testing.expect(containsBrace("pre{x,y}suf"));
    try std.testing.expect(!containsBrace("plain"));
    try std.testing.expect(!containsBrace("{nocomma}"));
    try std.testing.expect(!containsBrace("just{one}"));
}

test "comma expansion" {
    const results = try expand(std.testing.allocator, "{a,b,c}");
    defer {
        for (results) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("a", results[0]);
    try std.testing.expectEqualStrings("b", results[1]);
    try std.testing.expectEqualStrings("c", results[2]);
}

test "comma expansion with prefix and suffix" {
    const results = try expand(std.testing.allocator, "pre{A,B}suf");
    defer {
        for (results) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("preAsuf", results[0]);
    try std.testing.expectEqualStrings("preBsuf", results[1]);
}

test "numeric range" {
    const results = try expand(std.testing.allocator, "{1..5}");
    defer {
        for (results) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("1", results[0]);
    try std.testing.expectEqualStrings("5", results[4]);
}

test "numeric range with prefix/suffix" {
    const results = try expand(std.testing.allocator, "file{1..3}.txt");
    defer {
        for (results) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("file1.txt", results[0]);
    try std.testing.expectEqualStrings("file2.txt", results[1]);
    try std.testing.expectEqualStrings("file3.txt", results[2]);
}

test "zero-padded range" {
    const results = try expand(std.testing.allocator, "{01..03}");
    defer {
        for (results) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("01", results[0]);
    try std.testing.expectEqualStrings("02", results[1]);
    try std.testing.expectEqualStrings("03", results[2]);
}

test "reverse range" {
    const results = try expand(std.testing.allocator, "{3..1}");
    defer {
        for (results) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("3", results[0]);
    try std.testing.expectEqualStrings("2", results[1]);
    try std.testing.expectEqualStrings("1", results[2]);
}

test "character range" {
    const results = try expand(std.testing.allocator, "{a..d}");
    defer {
        for (results) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("a", results[0]);
    try std.testing.expectEqualStrings("d", results[3]);
}

test "no expansion returns original" {
    const results = try expand(std.testing.allocator, "plain");
    defer {
        for (results) |r| std.testing.allocator.free(r);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("plain", results[0]);
}
