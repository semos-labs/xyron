// FuzzyList.zig — Input + ScrollList with fuzzy filtering.
//
// Combines a text input with a scrollable list, filtering items
// using fuzzy.zig scoring as the user types. Items are sorted by
// match quality. The caller provides a buffer for filtered results
// to avoid heap allocation.

const std = @import("std");
const core = @import("core.zig");
const style = @import("../style.zig");
const keys = @import("../keys.zig");
const fuzzy = @import("../fuzzy.zig");
const Input = @import("Input.zig");

const Rect = core.Rect;
const Element = core.Element;
const Action = core.Action;
const Key = keys.Key;

// ---------------------------------------------------------------------------
// FuzzyList component
// ---------------------------------------------------------------------------

pub const FilteredItem = struct {
    index: u32, // original index in all_items
    score: i32,
};

input: Input = .{},
all_items: []const []const u8 = &.{},
/// Caller-provided buffer for filtered results.
filtered: []FilteredItem,
filtered_len: usize = 0,
selected: usize = 0,
scroll_offset: usize = 0,
show_scrollbar: bool = true,
focused: bool = true,
prompt: []const u8 = "> ",
prompt_color: ?style.Color = null,
/// Tracks the list height from the last render call.
last_visible_height: u16 = 0,

const Self = @This();

/// Initialize with items and a pre-allocated filter buffer.
/// Buffer size determines max filterable items (use items.len or larger).
pub fn init(items: []const []const u8, filtered_buf: []FilteredItem) Self {
    var self = Self{
        .all_items = items,
        .filtered = filtered_buf,
        .input = .{},
    };
    self.input.prompt = self.prompt;
    self.input.prompt_color = self.prompt_color;
    self.input.focused = true;
    self.refilter();
    return self;
}

/// Get the currently selected item text, or null if empty.
pub fn selectedItem(self: *const Self) ?[]const u8 {
    if (self.filtered_len == 0) return null;
    const fi = self.filtered[self.selected];
    return self.all_items[fi.index];
}

/// Get the original index of the selected item, or null.
pub fn selectedIndex(self: *const Self) ?usize {
    if (self.filtered_len == 0) return null;
    return self.filtered[self.selected].index;
}

/// Update the source items and refilter.
pub fn setItems(self: *Self, items: []const []const u8) void {
    self.all_items = items;
    self.refilter();
}

// ---------------------------------------------------------------------------
// Rendering — input on first row, list below
// ---------------------------------------------------------------------------

pub fn render(self: *const Self, buf: []u8, rect: Rect) usize {
    if (rect.w == 0 or rect.h == 0) return 0;

    var pos: usize = 0;

    // Input row
    const input_rect = rect.row(0);
    pos += self.input.render(buf[pos..], input_rect);

    // List area
    if (rect.h <= 1) return pos;
    const list_rect = Rect{
        .x = rect.x,
        .y = rect.y + 1,
        .w = rect.w,
        .h = rect.h - 1,
    };

    const visible = list_rect.h;
    const has_scrollbar = self.show_scrollbar and self.filtered_len > visible;
    const content_w: u16 = if (has_scrollbar) list_rect.w -| 1 else list_rect.w;

    // Render filtered items
    var row: u16 = 0;
    while (row < visible) : (row += 1) {
        const idx = self.scroll_offset + row;
        pos += style.moveTo(buf[pos..], list_rect.y + row, list_rect.x);

        if (idx < self.filtered_len) {
            const fi = self.filtered[idx];
            const text = self.all_items[fi.index];
            const is_selected = idx == self.selected;

            if (is_selected and self.focused) {
                pos += style.inverse(buf[pos..]);
                pos += style.bold(buf[pos..]);
            } else if (is_selected) {
                pos += style.inverse(buf[pos..]);
            }

            // Render text with match highlighting
            const query = self.input.value();
            if (query.len > 0 and !is_selected) {
                pos += renderHighlighted(buf[pos..], text, query, content_w);
            } else {
                const tw: u16 = @intCast(@min(text.len, content_w));
                pos += core.clipText(buf[pos..], text, tw);
                pos += core.pad(buf[pos..], content_w -| tw);
            }

            if (is_selected) pos += style.reset(buf[pos..]);
        } else {
            pos += core.pad(buf[pos..], content_w);
        }
    }

    // Scrollbar
    if (has_scrollbar) {
        pos += core.renderScrollbar(buf[pos..], list_rect.y, list_rect.x + list_rect.w - 1, visible, self.filtered_len, self.scroll_offset);
    }

    return pos;
}

/// Render text with matched characters highlighted in bold.
fn renderHighlighted(buf: []u8, text: []const u8, query: []const u8, max_w: u16) usize {
    const result = fuzzy.score(text, query);
    if (!result.matched) {
        // No match — render plain
        var pos: usize = 0;
        const tw: u16 = @intCast(@min(text.len, max_w));
        pos += core.clipText(buf[pos..], text, tw);
        pos += core.pad(buf[pos..], max_w -| tw);
        return pos;
    }

    var pos: usize = 0;
    var vis: u16 = 0;
    const positions = result.positions[0..result.match_count];

    for (text, 0..) |ch, ci| {
        if (vis >= max_w) break;
        const is_match = for (positions) |mp| {
            if (mp == ci) break true;
        } else false;

        if (is_match) pos += style.bold(buf[pos..]);
        if (pos < buf.len) {
            buf[pos] = ch;
            pos += 1;
        }
        vis += 1;
        if (is_match) pos += style.unbold(buf[pos..]);
    }

    pos += core.pad(buf[pos..], max_w -| vis);
    return pos;
}

pub fn element(self: *const Self) Element {
    return Element.from(self);
}

// ---------------------------------------------------------------------------
// Key handling — input gets chars, list gets navigation
// ---------------------------------------------------------------------------

pub fn handleKey(self: *Self, key: Key) Action {
    // Navigation keys go to list
    switch (key) {
        .up, .ctrl_p => {
            if (self.selected > 0) self.selected -= 1;
            self.ensureVisible();
            return .changed;
        },
        .down, .ctrl_n => {
            if (self.filtered_len > 0 and self.selected < self.filtered_len - 1)
                self.selected += 1;
            self.ensureVisible();
            return .changed;
        },
        .enter => return .submit,
        .escape => return .cancel,
        else => {},
    }

    // Everything else goes to input
    const result = self.input.handleKey(key);
    if (result == .changed) {
        self.refilter();
        return .changed;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Filtering
// ---------------------------------------------------------------------------

fn refilter(self: *Self) void {
    const query = self.input.value();

    if (query.len == 0) {
        // Show all items, no scoring needed
        const n = @min(self.all_items.len, self.filtered.len);
        for (0..n) |i| {
            self.filtered[i] = .{ .index = @intCast(i), .score = 0 };
        }
        self.filtered_len = n;
    } else {
        // Score and filter
        var count: usize = 0;
        for (self.all_items, 0..) |item, i| {
            if (count >= self.filtered.len) break;
            const result = fuzzy.score(item, query);
            if (result.matched) {
                self.filtered[count] = .{
                    .index = @intCast(i),
                    .score = result.value,
                };
                count += 1;
            }
        }
        self.filtered_len = count;

        // Sort by score descending
        if (count > 1) {
            std.mem.sort(FilteredItem, self.filtered[0..count], {}, struct {
                fn f(_: void, a: FilteredItem, b: FilteredItem) bool {
                    return a.score > b.score;
                }
            }.f);
        }
    }

    // Reset selection
    self.selected = 0;
    self.scroll_offset = 0;
}

/// Adjust scroll so the selected item is visible.
/// Uses the height from the last `ensureVisibleWithHeight` call,
/// or falls back to a conservative default.
fn ensureVisible(self: *Self) void {
    const visible = if (self.last_visible_height > 0) self.last_visible_height else 10;
    self.ensureVisibleWithHeight(visible);
}

/// Adjust scroll for a known visible height. Call before render to
/// record the actual list height for subsequent key-driven scrolling.
pub fn ensureVisibleWithHeight(self: *Self, visible: u16) void {
    if (visible == 0) return;
    self.last_visible_height = visible;
    if (self.selected < self.scroll_offset) {
        self.scroll_offset = self.selected;
    } else if (self.selected >= self.scroll_offset + visible) {
        self.scroll_offset = self.selected - visible + 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "init shows all items" {
    var buf: [8]FilteredItem = undefined;
    const items: []const []const u8 = &.{ "apple", "banana", "cherry" };
    const fz = Self.init(items, &buf);
    try testing.expectEqual(@as(usize, 3), fz.filtered_len);
}

test "filter narrows results" {
    var buf: [8]FilteredItem = undefined;
    const items: []const []const u8 = &.{ "apple", "banana", "cherry" };
    var fz = Self.init(items, &buf);
    fz.input.setValue("an");
    fz.refilter();
    // "an" matches "banana" (has a then n). apple/cherry have no 'n'.
    try testing.expectEqual(@as(usize, 1), fz.filtered_len);
}

test "selectedItem returns correct item" {
    var buf: [8]FilteredItem = undefined;
    const items: []const []const u8 = &.{ "alpha", "beta", "gamma" };
    var fz = Self.init(items, &buf);
    fz.selected = 1;
    try testing.expectEqualStrings("beta", fz.selectedItem().?);
}

test "selectedItem empty returns null" {
    var buf: [8]FilteredItem = undefined;
    const items: []const []const u8 = &.{};
    const fz = Self.init(items, &buf);
    try testing.expectEqual(@as(?[]const u8, null), fz.selectedItem());
}

test "handleKey down navigates" {
    var buf: [8]FilteredItem = undefined;
    const items: []const []const u8 = &.{ "one", "two", "three" };
    var fz = Self.init(items, &buf);
    try testing.expectEqual(Action.changed, fz.handleKey(.down));
    try testing.expectEqual(@as(usize, 1), fz.selected);
}

test "handleKey typing refilters" {
    var buf: [8]FilteredItem = undefined;
    const items: []const []const u8 = &.{ "foo", "bar", "baz" };
    var fz = Self.init(items, &buf);
    try testing.expectEqual(Action.changed, fz.handleKey(.{ .char = 'b' }));
    // Should filter to bar, baz
    try testing.expectEqual(@as(usize, 2), fz.filtered_len);
}

test "handleKey enter and escape" {
    var buf: [8]FilteredItem = undefined;
    const items: []const []const u8 = &.{"test"};
    var fz = Self.init(items, &buf);
    try testing.expectEqual(Action.submit, fz.handleKey(.enter));
    try testing.expectEqual(Action.cancel, fz.handleKey(.escape));
}

test "render produces output" {
    var buf: [8]FilteredItem = undefined;
    const items: []const []const u8 = &.{ "hello", "world" };
    const fz = Self.init(items, &buf);
    var render_buf: [2048]u8 = undefined;
    const n = fz.render(&render_buf, Rect{ .x = 1, .y = 1, .w = 30, .h = 5 });
    try testing.expect(n > 0);
}

test "filter sorted by score" {
    var buf: [8]FilteredItem = undefined;
    const items: []const []const u8 = &.{ "xyzab", "ab", "axxb" };
    var fz = Self.init(items, &buf);
    fz.input.setValue("ab");
    fz.refilter();
    // "ab" should score highest (exact match), then "axxb", then "xyzab"
    try testing.expect(fz.filtered_len >= 2);
    // First result should be "ab" (index 1)
    try testing.expectEqual(@as(u32, 1), fz.filtered[0].index);
}
