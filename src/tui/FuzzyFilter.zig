// FuzzyFilter.zig — Reusable fuzzy filter/score/sort engine.
//
// Scores text items against a query using fuzzy.zig, produces sorted
// results with match positions for highlighting. Zero allocations.
//
// Usage:
//
//   var filter = FuzzyFilter(500).init();
//   filter.run("query", &.{ "apple", "banana", "cherry" });
//
//   for (filter.results()) |r| {
//       // r.index = original index, r.score, r.positions, r.match_count
//   }

const std = @import("std");
const fuzzy = @import("../fuzzy.zig");

pub const max_positions = fuzzy.max_positions;

/// A single scored result.
pub const Result = struct {
    index: u32, // original item index
    score: i32, // match quality (higher = better)
    positions: [max_positions]u8, // matched character positions
    match_count: u8, // number of matched characters
};

/// Fuzzy filter with a compile-time maximum capacity.
pub fn FuzzyFilter(comptime max_items: usize) type {
    return struct {
        buf: [max_items]Result = undefined,
        count: usize = 0,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        /// Filter and sort items by fuzzy match.
        /// When query is empty, all items pass in original order.
        pub fn run(self: *Self, query: []const u8, texts: []const []const u8) void {
            self.count = 0;
            for (texts, 0..) |text, i| {
                if (self.count >= max_items) break;
                self.scoreOne(query, text, @intCast(i));
            }
        }

        /// Score a single item against the query and insert if matched.
        /// Call this in a loop for items that need pre-filtering or
        /// non-contiguous text sources.
        pub fn push(self: *Self, query: []const u8, text: []const u8, index: u32) void {
            if (self.count >= max_items) return;
            self.scoreOne(query, text, index);
        }

        /// Push an item with no scoring (for exact match mode).
        pub fn pushExact(self: *Self, index: u32) void {
            if (self.count >= max_items) return;
            self.buf[self.count] = .{
                .index = index,
                .score = 0,
                .positions = [_]u8{0} ** max_positions,
                .match_count = 0,
            };
            self.count += 1;
        }

        /// Reset results. Call before a series of push() calls.
        pub fn reset(self: *Self) void {
            self.count = 0;
        }

        /// Get the filtered results slice (sorted by score descending).
        pub fn results(self: *const Self) []const Result {
            return self.buf[0..self.count];
        }

        /// Get result at index, or null.
        pub fn get(self: *const Self, idx: usize) ?Result {
            if (idx >= self.count) return null;
            return self.buf[idx];
        }

        /// Get the original item index for a result position.
        pub fn originalIndex(self: *const Self, result_idx: usize) ?usize {
            if (result_idx >= self.count) return null;
            return self.buf[result_idx].index;
        }

        // ---------------------------------------------------------------

        fn scoreOne(self: *Self, query: []const u8, text: []const u8, index: u32) void {
            if (query.len == 0) {
                // No query — pass through, preserve order
                self.buf[self.count] = .{
                    .index = index,
                    .score = 0,
                    .positions = undefined,
                    .match_count = 0,
                };
                self.count += 1;
                return;
            }

            const s = fuzzy.score(text, query);
            if (!s.matched) return;

            // Insertion sort by score descending
            var pos = self.count;
            while (pos > 0 and self.buf[pos - 1].score < s.value) {
                self.buf[pos] = self.buf[pos - 1];
                pos -= 1;
            }
            self.buf[pos] = .{
                .index = index,
                .score = s.value,
                .positions = s.positions,
                .match_count = s.match_count,
            };
            self.count += 1;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "empty query returns all items" {
    var f = FuzzyFilter(16).init();
    f.run("", &.{ "apple", "banana", "cherry" });
    try std.testing.expectEqual(@as(usize, 3), f.count);
    try std.testing.expectEqual(@as(u32, 0), f.buf[0].index);
    try std.testing.expectEqual(@as(u32, 1), f.buf[1].index);
    try std.testing.expectEqual(@as(u32, 2), f.buf[2].index);
}

test "query filters items" {
    var f = FuzzyFilter(16).init();
    f.run("an", &.{ "apple", "banana", "orange" });
    // "an" should match "banana" and "orange"
    try std.testing.expect(f.count >= 1);
    for (f.results()) |r| {
        try std.testing.expect(r.match_count > 0);
    }
}

test "results sorted by score" {
    var f = FuzzyFilter(16).init();
    f.run("ab", &.{ "xyzab", "ab", "axxb" });
    try std.testing.expect(f.count >= 2);
    try std.testing.expectEqual(@as(u32, 1), f.buf[0].index); // "ab" best match
}

test "push with pre-filtering" {
    var f = FuzzyFilter(16).init();
    f.reset();
    // Only push even-indexed items
    const items = [_][]const u8{ "a", "b", "c", "d" };
    for (items, 0..) |text, i| {
        if (i % 2 == 0) f.push("", text, @intCast(i));
    }
    try std.testing.expectEqual(@as(usize, 2), f.count);
    try std.testing.expectEqual(@as(u32, 0), f.buf[0].index);
    try std.testing.expectEqual(@as(u32, 2), f.buf[1].index);
}

test "match positions tracked" {
    var f = FuzzyFilter(16).init();
    f.run("ab", &.{"ab"});
    try std.testing.expectEqual(@as(usize, 1), f.count);
    try std.testing.expectEqual(@as(u8, 2), f.buf[0].match_count);
    try std.testing.expectEqual(@as(u8, 0), f.buf[0].positions[0]);
    try std.testing.expectEqual(@as(u8, 1), f.buf[0].positions[1]);
}

test "capacity limit" {
    var f = FuzzyFilter(2).init();
    f.run("", &.{ "a", "b", "c", "d", "e" });
    try std.testing.expectEqual(@as(usize, 2), f.count);
}
