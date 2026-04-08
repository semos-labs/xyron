// ScrollList.zig — Scrollable list with keyboard navigation and scrollbar.
//
// Renders a vertical list of text items with a selected item highlight.
// Supports up/down/pgup/pgdown/home/end navigation and a scrollbar
// on the right edge when content exceeds visible height.

const std = @import("std");
const core = @import("core.zig");
const style = @import("../style.zig");
const keys = @import("../keys.zig");

const Rect = core.Rect;
const Element = core.Element;
const Action = core.Action;
const Key = keys.Key;

// ---------------------------------------------------------------------------
// ScrollList component
// ---------------------------------------------------------------------------

items: []const []const u8 = &.{},
selected: usize = 0,
scroll_offset: usize = 0,
focused: bool = true,
show_scrollbar: bool = true,
highlight_color: ?style.Color = null,
dim_when_unfocused: bool = true,

const Self = @This();

/// Get the currently selected item, or null if empty.
pub fn selectedItem(self: *const Self) ?[]const u8 {
    if (self.items.len == 0) return null;
    return self.items[self.selected];
}

/// Replace the item list. Clamps selection and scroll.
pub fn setItems(self: *Self, items: []const []const u8) void {
    self.items = items;
    if (items.len == 0) {
        self.selected = 0;
        self.scroll_offset = 0;
    } else {
        if (self.selected >= items.len) self.selected = items.len - 1;
        // scroll will be adjusted on next render
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

pub fn render(self: *const Self, buf: []u8, rect: Rect) usize {
    if (rect.w == 0 or rect.h == 0) return 0;

    var pos: usize = 0;
    const visible = rect.h;
    const has_scrollbar = self.show_scrollbar and self.items.len > visible;
    const content_w: u16 = if (has_scrollbar) rect.w -| 1 else rect.w;

    // Render visible items
    var row: u16 = 0;
    while (row < visible) : (row += 1) {
        const idx = self.scroll_offset + row;
        pos += style.moveTo(buf[pos..], rect.y + row, rect.x);

        if (idx < self.items.len) {
            const is_selected = idx == self.selected;

            // Apply selection style
            if (is_selected and self.focused) {
                pos += style.inverse(buf[pos..]);
                pos += style.bold(buf[pos..]);
            } else if (is_selected and !self.focused and self.dim_when_unfocused) {
                pos += style.inverse(buf[pos..]);
                pos += style.dim(buf[pos..]);
            } else if (is_selected) {
                pos += style.inverse(buf[pos..]);
            }

            if (!is_selected and self.highlight_color != null) {
                pos += style.fg(buf[pos..], self.highlight_color.?);
            }

            // Item text
            const text = self.items[idx];
            const tw: u16 = @intCast(@min(text.len, content_w));
            pos += core.clipText(buf[pos..], text, tw);

            // Pad to content width
            pos += core.pad(buf[pos..], content_w -| tw);

            if (is_selected or self.highlight_color != null) {
                pos += style.reset(buf[pos..]);
            }
        } else {
            // Empty row
            pos += core.pad(buf[pos..], content_w);
        }
    }

    // Scrollbar
    if (has_scrollbar) {
        pos += core.renderScrollbar(buf[pos..], rect.y, rect.x + rect.w - 1, visible, self.items.len, self.scroll_offset);
    }

    return pos;
}

pub fn element(self: *const Self) Element {
    return Element.from(self);
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

pub fn handleKey(self: *Self, key: Key) Action {
    if (self.items.len == 0) {
        return switch (key) {
            .enter => .submit,
            .escape => .cancel,
            else => .ignored,
        };
    }
    switch (key) {
        .up, .ctrl_p => {
            self.selectPrev();
            return .changed;
        },
        .down, .ctrl_n => {
            self.selectNext();
            return .changed;
        },
        .home => {
            self.selectFirst();
            return .changed;
        },
        .end_key => {
            self.selectLast();
            return .changed;
        },
        .enter => return .submit,
        .escape => return .cancel,
        else => return .ignored,
    }
}

/// Handle key with visible height for page up/down support.
pub fn handleKeyWithHeight(self: *Self, key: Key, visible_height: u16) Action {
    switch (key) {
        .ctrl_d => { // Page down (half page)
            self.pageDown(visible_height);
            return .changed;
        },
        .ctrl_u => { // Page up (half page)
            self.pageUp(visible_height);
            return .changed;
        },
        else => return self.handleKey(key),
    }
}

pub fn selectPrev(self: *Self) void {
    if (self.selected > 0) self.selected -= 1;
}

pub fn selectNext(self: *Self) void {
    if (self.items.len > 0 and self.selected < self.items.len - 1)
        self.selected += 1;
}

pub fn selectFirst(self: *Self) void {
    self.selected = 0;
}

pub fn selectLast(self: *Self) void {
    if (self.items.len > 0) self.selected = self.items.len - 1;
}

pub fn pageUp(self: *Self, visible: u16) void {
    const half = @max(1, visible / 2);
    if (self.selected >= half) {
        self.selected -= half;
    } else {
        self.selected = 0;
    }
}

pub fn pageDown(self: *Self, visible: u16) void {
    const half = @max(1, visible / 2);
    self.selected = @min(self.selected + half, if (self.items.len > 0) self.items.len - 1 else 0);
}

/// Ensure selected item is visible. Call before render if selection changed.
pub fn ensureVisible(self: *Self, visible_height: u16) void {
    if (visible_height == 0) return;
    if (self.selected < self.scroll_offset) {
        self.scroll_offset = self.selected;
    } else if (self.selected >= self.scroll_offset + visible_height) {
        self.scroll_offset = self.selected - visible_height + 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "selectNext and selectPrev" {
    var list: Self = .{
        .items = &.{ "one", "two", "three" },
    };
    try testing.expectEqual(@as(usize, 0), list.selected);
    list.selectNext();
    try testing.expectEqual(@as(usize, 1), list.selected);
    list.selectNext();
    try testing.expectEqual(@as(usize, 2), list.selected);
    list.selectNext(); // should clamp
    try testing.expectEqual(@as(usize, 2), list.selected);
    list.selectPrev();
    try testing.expectEqual(@as(usize, 1), list.selected);
}

test "selectFirst and selectLast" {
    var list: Self = .{
        .items = &.{ "a", "b", "c", "d" },
    };
    list.selectLast();
    try testing.expectEqual(@as(usize, 3), list.selected);
    list.selectFirst();
    try testing.expectEqual(@as(usize, 0), list.selected);
}

test "pageUp and pageDown" {
    var list: Self = .{
        .items = &.{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" },
    };
    list.pageDown(4); // half = 2
    try testing.expectEqual(@as(usize, 2), list.selected);
    list.pageDown(4);
    try testing.expectEqual(@as(usize, 4), list.selected);
    list.pageUp(4);
    try testing.expectEqual(@as(usize, 2), list.selected);
    list.pageUp(4);
    try testing.expectEqual(@as(usize, 0), list.selected);
}

test "ensureVisible scrolls down" {
    var list: Self = .{
        .items = &.{ "0", "1", "2", "3", "4" },
        .selected = 4,
    };
    list.ensureVisible(3);
    try testing.expectEqual(@as(usize, 2), list.scroll_offset);
}

test "ensureVisible scrolls up" {
    var list: Self = .{
        .items = &.{ "0", "1", "2", "3", "4" },
        .selected = 1,
        .scroll_offset = 3,
    };
    list.ensureVisible(3);
    try testing.expectEqual(@as(usize, 1), list.scroll_offset);
}

test "setItems clamps selection" {
    var list: Self = .{
        .items = &.{ "a", "b", "c" },
        .selected = 2,
    };
    const new_items: []const []const u8 = &.{ "x", "y" };
    list.setItems(new_items);
    try testing.expectEqual(@as(usize, 1), list.selected);
}

test "selectedItem" {
    const list: Self = .{
        .items = &.{ "first", "second" },
        .selected = 1,
    };
    try testing.expectEqualStrings("second", list.selectedItem().?);
}

test "selectedItem empty" {
    const list: Self = .{};
    try testing.expectEqual(@as(?[]const u8, null), list.selectedItem());
}

test "handleKey navigation" {
    var list: Self = .{
        .items = &.{ "a", "b", "c" },
    };
    try testing.expectEqual(Action.changed, list.handleKey(.down));
    try testing.expectEqual(@as(usize, 1), list.selected);
    try testing.expectEqual(Action.changed, list.handleKey(.up));
    try testing.expectEqual(@as(usize, 0), list.selected);
    try testing.expectEqual(Action.submit, list.handleKey(.enter));
    try testing.expectEqual(Action.cancel, list.handleKey(.escape));
}

test "render produces output" {
    const list: Self = .{
        .items = &.{ "hello", "world" },
    };
    var buf: [1024]u8 = undefined;
    const n = list.render(&buf, Rect{ .x = 1, .y = 1, .w = 20, .h = 5 });
    try testing.expect(n > 0);
    const output = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, output, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, output, "world") != null);
}

test "render zero rect" {
    const list: Self = .{ .items = &.{"test"} };
    var buf: [256]u8 = undefined;
    const n = list.render(&buf, Rect{ .x = 1, .y = 1, .w = 0, .h = 0 });
    try testing.expectEqual(@as(usize, 0), n);
}

test "render with scrollbar" {
    // More items than visible height to trigger scrollbar
    const list: Self = .{
        .items = &.{ "a", "b", "c", "d", "e" },
        .show_scrollbar = true,
    };
    var buf: [2048]u8 = undefined;
    const n = list.render(&buf, Rect{ .x = 1, .y = 1, .w = 20, .h = 3 });
    try testing.expect(n > 0);
    const output = buf[0..n];
    // Should contain scrollbar chars
    try testing.expect(std.mem.indexOf(u8, output, style.box.scrollbar_thumb) != null);
}
