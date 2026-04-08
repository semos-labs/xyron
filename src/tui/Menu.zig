// Menu.zig — Selectable menu with items, separators, and keyboard navigation.
//
// Unlike ScrollList which renders plain text items, Menu supports
// separators between groups, disabled entries, and right-aligned hints.

const std = @import("std");
const core = @import("core.zig");
const style = @import("../style.zig");
const keys = @import("../keys.zig");

const Rect = core.Rect;
const Element = core.Element;
const Action = core.Action;
const Key = keys.Key;

// ---------------------------------------------------------------------------
// Menu component
// ---------------------------------------------------------------------------

pub const Item = union(enum) {
    entry: Entry,
    separator,

    pub const Entry = struct {
        label: []const u8,
        hint: []const u8 = "", // right-aligned hint text (e.g. shortcut)
        disabled: bool = false,
    };
};

items: []const Item = &.{},
selected: usize = 0,
focused: bool = true,

const Self = @This();

/// Get the label of the selected entry, or null if on a separator.
pub fn selectedLabel(self: *const Self) ?[]const u8 {
    if (self.items.len == 0) return null;
    const item = self.items[self.selected];
    return switch (item) {
        .entry => |e| e.label,
        .separator => null,
    };
}

/// Get the selected item index (original index including separators).
pub fn selectedIndex(self: *const Self) usize {
    return self.selected;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

pub fn render(self: *const Self, buf: []u8, rect: Rect) usize {
    if (rect.w == 0 or rect.h == 0) return 0;

    var pos: usize = 0;
    var row: u16 = 0;

    for (self.items, 0..) |item, idx| {
        if (row >= rect.h) break;

        pos += style.moveTo(buf[pos..], rect.y + row, rect.x);

        switch (item) {
            .separator => {
                pos += style.dim(buf[pos..]);
                var col: u16 = 0;
                while (col < rect.w) : (col += 1) {
                    pos += style.cp(buf[pos..], style.box.horizontal);
                }
                pos += style.reset(buf[pos..]);
            },
            .entry => |entry| {
                const is_selected = idx == self.selected;

                if (entry.disabled) {
                    pos += style.dim(buf[pos..]);
                } else if (is_selected and self.focused) {
                    pos += style.inverse(buf[pos..]);
                    pos += style.bold(buf[pos..]);
                } else if (is_selected) {
                    pos += style.inverse(buf[pos..]);
                }

                // Label
                const hint_w: u16 = @intCast(@min(entry.hint.len, rect.w / 3));
                const label_max: u16 = rect.w -| hint_w -| (if (hint_w > 0) @as(u16, 1) else 0);
                const label_w: u16 = @intCast(@min(entry.label.len, label_max));
                pos += core.clipText(buf[pos..], entry.label, label_w);

                // Gap between label and hint
                const gap = rect.w -| label_w -| hint_w;
                pos += core.pad(buf[pos..], gap);

                // Hint (right-aligned, dim when not selected)
                if (hint_w > 0) {
                    if (!is_selected and !entry.disabled) pos += style.dim(buf[pos..]);
                    pos += core.clipText(buf[pos..], entry.hint, hint_w);
                    if (!is_selected and !entry.disabled) pos += style.undim(buf[pos..]);
                }

                if (entry.disabled or is_selected) pos += style.reset(buf[pos..]);
            },
        }

        row += 1;
    }

    // Clear remaining rows
    while (row < rect.h) : (row += 1) {
        pos += style.moveTo(buf[pos..], rect.y + row, rect.x);
        pos += core.pad(buf[pos..], rect.w);
    }

    return pos;
}

pub fn element(self: *const Self) Element {
    return Element.from(self);
}

// ---------------------------------------------------------------------------
// Navigation — skips separators and disabled items
// ---------------------------------------------------------------------------

pub fn handleKey(self: *Self, key: Key) Action {
    if (self.items.len == 0) {
        return switch (key) {
            .escape => .cancel,
            else => .ignored,
        };
    }
    switch (key) {
        .up, .ctrl_p => {
            self.movePrev();
            return .changed;
        },
        .down, .ctrl_n => {
            self.moveNext();
            return .changed;
        },
        .home => {
            self.moveFirst();
            return .changed;
        },
        .end_key => {
            self.moveLast();
            return .changed;
        },
        .enter => {
            // Only submit on selectable entries
            if (self.selectedLabel() != null) {
                const entry = self.items[self.selected].entry;
                if (!entry.disabled) return .submit;
            }
            return .none;
        },
        .escape => return .cancel,
        else => return .ignored,
    }
}

fn movePrev(self: *Self) void {
    var i = self.selected;
    while (i > 0) {
        i -= 1;
        if (self.isSelectable(i)) {
            self.selected = i;
            return;
        }
    }
}

fn moveNext(self: *Self) void {
    var i = self.selected;
    while (i + 1 < self.items.len) {
        i += 1;
        if (self.isSelectable(i)) {
            self.selected = i;
            return;
        }
    }
}

fn moveFirst(self: *Self) void {
    for (0..self.items.len) |i| {
        if (self.isSelectable(i)) {
            self.selected = i;
            return;
        }
    }
}

fn moveLast(self: *Self) void {
    var i = self.items.len;
    while (i > 0) {
        i -= 1;
        if (self.isSelectable(i)) {
            self.selected = i;
            return;
        }
    }
}

fn isSelectable(self: *const Self, idx: usize) bool {
    return switch (self.items[idx]) {
        .entry => |e| !e.disabled,
        .separator => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "moveNext skips separators" {
    var menu: Self = .{
        .items = &.{
            .{ .entry = .{ .label = "Cut" } },
            .separator,
            .{ .entry = .{ .label = "Paste" } },
        },
    };
    menu.moveNext();
    try testing.expectEqual(@as(usize, 2), menu.selected);
    try testing.expectEqualStrings("Paste", menu.selectedLabel().?);
}

test "movePrev skips separators" {
    var menu: Self = .{
        .items = &.{
            .{ .entry = .{ .label = "Cut" } },
            .separator,
            .{ .entry = .{ .label = "Paste" } },
        },
        .selected = 2,
    };
    menu.movePrev();
    try testing.expectEqual(@as(usize, 0), menu.selected);
}

test "moveNext skips disabled" {
    var menu: Self = .{
        .items = &.{
            .{ .entry = .{ .label = "A" } },
            .{ .entry = .{ .label = "B", .disabled = true } },
            .{ .entry = .{ .label = "C" } },
        },
    };
    menu.moveNext();
    try testing.expectEqual(@as(usize, 2), menu.selected);
}

test "selectedLabel on separator returns null" {
    const menu: Self = .{
        .items = &.{
            .separator,
            .{ .entry = .{ .label = "A" } },
        },
        .selected = 0,
    };
    try testing.expectEqual(@as(?[]const u8, null), menu.selectedLabel());
}

test "handleKey enter on disabled" {
    var menu: Self = .{
        .items = &.{
            .{ .entry = .{ .label = "A", .disabled = true } },
        },
    };
    try testing.expectEqual(Action.none, menu.handleKey(.enter));
}

test "handleKey enter on enabled" {
    var menu: Self = .{
        .items = &.{
            .{ .entry = .{ .label = "A" } },
        },
    };
    try testing.expectEqual(Action.submit, menu.handleKey(.enter));
}

test "render produces output" {
    const menu: Self = .{
        .items = &.{
            .{ .entry = .{ .label = "Open", .hint = "^O" } },
            .separator,
            .{ .entry = .{ .label = "Quit", .hint = "^Q" } },
        },
    };
    var buf: [1024]u8 = undefined;
    const n = menu.render(&buf, Rect{ .x = 1, .y = 1, .w = 20, .h = 5 });
    try testing.expect(n > 0);
    const output = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, output, "Open") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Quit") != null);
}

test "moveFirst and moveLast" {
    var menu: Self = .{
        .items = &.{
            .separator,
            .{ .entry = .{ .label = "A" } },
            .{ .entry = .{ .label = "B" } },
            .separator,
        },
    };
    menu.moveFirst();
    try testing.expectEqual(@as(usize, 1), menu.selected);
    menu.moveLast();
    try testing.expectEqual(@as(usize, 2), menu.selected);
}
