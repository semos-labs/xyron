// history.zig — In-memory history buffer for interactive navigation.
//
// Maintains a ring buffer of recent command strings for up/down arrow
// navigation. Synchronized with the SQLite database on each command
// completion. Preserves the user's unsent input during navigation.

const std = @import("std");

/// Maximum number of entries in the in-memory buffer.
const MAX_ENTRIES: usize = 1000;
/// Maximum length of a single history entry.
const MAX_ENTRY_LEN: usize = 4096;

pub const History = struct {
    /// Circular buffer of history entries.
    entries: [MAX_ENTRIES][MAX_ENTRY_LEN]u8 = undefined,
    lengths: [MAX_ENTRIES]usize = [_]usize{0} ** MAX_ENTRIES,
    /// Number of entries stored (0..MAX_ENTRIES).
    count: usize = 0,
    /// Write position in the circular buffer.
    write_pos: usize = 0,

    /// Navigation state (reset on each new prompt).
    nav_index: usize = 0,
    nav_active: bool = false,
    /// Saved input before user started navigating.
    saved_input: [MAX_ENTRY_LEN]u8 = undefined,
    saved_len: usize = 0,

    /// Add a command to history.
    pub fn push(self: *History, line: []const u8) void {
        if (line.len == 0 or line.len > MAX_ENTRY_LEN) return;

        // Don't add consecutive duplicates
        if (self.count > 0) {
            const last_idx = if (self.write_pos == 0) MAX_ENTRIES - 1 else self.write_pos - 1;
            const last = self.entries[last_idx][0..self.lengths[last_idx]];
            if (std.mem.eql(u8, last, line)) return;
        }

        @memcpy(self.entries[self.write_pos][0..line.len], line);
        self.lengths[self.write_pos] = line.len;
        self.write_pos = (self.write_pos + 1) % MAX_ENTRIES;
        if (self.count < MAX_ENTRIES) self.count += 1;
    }

    /// Start a new navigation session. Saves current editor content.
    pub fn beginNavigation(self: *History, current_input: []const u8) void {
        self.nav_index = 0;
        self.nav_active = false;
        if (current_input.len <= MAX_ENTRY_LEN) {
            @memcpy(self.saved_input[0..current_input.len], current_input);
            self.saved_len = current_input.len;
        }
    }

    /// Navigate up (older). Returns the entry to display, or null if at end.
    pub fn navigateUp(self: *History) ?[]const u8 {
        if (self.count == 0) return null;

        if (!self.nav_active) {
            self.nav_active = true;
            self.nav_index = 0;
        } else {
            if (self.nav_index + 1 >= self.count) return null;
            self.nav_index += 1;
        }

        return self.entryAt(self.nav_index);
    }

    /// Navigate down (newer). Returns the entry, or the saved input at bottom.
    pub fn navigateDown(self: *History) ?[]const u8 {
        if (!self.nav_active) return null;

        if (self.nav_index == 0) {
            // Return to saved input
            self.nav_active = false;
            return self.saved_input[0..self.saved_len];
        }

        self.nav_index -= 1;
        return self.entryAt(self.nav_index);
    }

    /// Reset navigation state (call when a command is submitted).
    pub fn resetNavigation(self: *History) void {
        self.nav_index = 0;
        self.nav_active = false;
    }

    /// Get the entry at a given reverse index (0 = most recent).
    fn entryAt(self: *const History, rev_idx: usize) ?[]const u8 {
        if (rev_idx >= self.count) return null;
        // write_pos points past the last written entry
        const offset = rev_idx + 1;
        const actual = if (self.write_pos >= offset)
            self.write_pos - offset
        else
            MAX_ENTRIES - (offset - self.write_pos);
        return self.entries[actual][0..self.lengths[actual]];
    }

    /// Find the best ghost text suggestion from history.
    /// Must start with the typed input (prefix match) so it renders
    /// correctly as a continuation. Uses fuzzy scoring + recency to
    /// rank among prefix matches.
    pub fn findGhost(self: *const History, query: []const u8) ?[]const u8 {
        if (query.len == 0 or self.count == 0) return null;
        const fuzzy_mod = @import("fuzzy.zig");

        var best_score: i32 = std.math.minInt(i32);
        var best_entry: ?[]const u8 = null;

        for (0..self.count) |rev_idx| {
            const entry = self.entryAt(rev_idx) orelse continue;
            if (entry.len <= query.len) continue;

            // Must be a prefix match for ghost text to make visual sense
            if (!std.mem.startsWith(u8, entry, query)) continue;

            // Use fuzzy score + recency for ranking
            const result = fuzzy_mod.score(entry, query);
            const recency: i32 = @intCast(@min(self.count - rev_idx, 50));
            const total = if (result.matched) result.value + recency else recency;

            if (total > best_score) {
                best_score = total;
                best_entry = entry;
            }
        }

        return best_entry;
    }

    /// Load initial entries from database query results.
    pub fn loadFromDb(self: *History, raw_inputs: []const []const u8) void {
        // DB returns newest-first; we push oldest-first to maintain order
        var i = raw_inputs.len;
        while (i > 0) {
            i -= 1;
            self.push(raw_inputs[i]);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "push and navigate" {
    var h = History{};
    h.push("first");
    h.push("second");
    h.push("third");

    h.beginNavigation("current");

    try std.testing.expectEqualStrings("third", h.navigateUp().?);
    try std.testing.expectEqualStrings("second", h.navigateUp().?);
    try std.testing.expectEqualStrings("first", h.navigateUp().?);
    try std.testing.expectEqual(@as(?[]const u8, null), h.navigateUp());
}

test "navigate down returns to saved input" {
    var h = History{};
    h.push("first");
    h.push("second");

    h.beginNavigation("partial");

    _ = h.navigateUp(); // second
    _ = h.navigateUp(); // first
    try std.testing.expectEqualStrings("second", h.navigateDown().?);
    try std.testing.expectEqualStrings("partial", h.navigateDown().?);
}

test "no consecutive duplicates" {
    var h = History{};
    h.push("same");
    h.push("same");
    h.push("same");

    try std.testing.expectEqual(@as(usize, 1), h.count);
}

test "empty history returns null" {
    var h = History{};
    h.beginNavigation("");
    try std.testing.expectEqual(@as(?[]const u8, null), h.navigateUp());
}
