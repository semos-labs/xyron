// Box.zig — Bordered container, separator, and status bar components.
//
// Box renders a border with optional title. Use contentRect() to get the
// inner area for child components. Separator draws a horizontal line.
// StatusBar renders a bottom bar with key hints.

const std = @import("std");
const core = @import("core.zig");
const style = @import("../style.zig");

const Rect = core.Rect;
const Element = core.Element;

// ===========================================================================
// Box — bordered container
// ===========================================================================

pub const Box = struct {
    title: []const u8 = "",
    border_color: ?style.Color = null,
    title_color: ?style.Color = null,
    fill: bool = true, // clear interior with spaces

    /// Get the content area inside the border.
    pub fn contentRect(_: *const Box, rect: Rect) Rect {
        return rect.inner(1);
    }

    pub fn render(self: *const Box, buf: []u8, rect: Rect) usize {
        if (rect.w < 2 or rect.h < 2) return 0;

        var pos: usize = 0;
        const inner_w = rect.w - 2;

        // Border color
        if (self.border_color) |c| pos += style.fg(buf[pos..], c);

        // Top edge: ┌─ Title ─┐
        pos += style.moveTo(buf[pos..], rect.y, rect.x);
        pos += style.cp(buf[pos..], style.box.top_left);

        if (self.title.len > 0 and inner_w >= 4) {
            pos += style.cp(buf[pos..], style.box.horizontal);
            pos += style.cp(buf[pos..], " ");

            // Title (possibly different color)
            if (self.border_color) |_| pos += style.reset(buf[pos..]);
            if (self.title_color) |c| pos += style.boldFg(buf[pos..], c);
            const title_max = @min(self.title.len, inner_w -| 4);
            pos += core.clipText(buf[pos..], self.title, @intCast(title_max));
            if (self.title_color) |_| pos += style.reset(buf[pos..]);
            if (self.border_color) |c| pos += style.fg(buf[pos..], c);

            pos += style.cp(buf[pos..], " ");
            // Fill remaining with horizontal lines
            const used: u16 = @intCast(self.title.len + 4);
            const fill_w = inner_w -| @min(used, inner_w);
            pos += style.hline(buf[pos..], fill_w);
        } else {
            pos += style.hline(buf[pos..], inner_w);
        }
        pos += style.cp(buf[pos..], style.box.top_right);

        // Middle rows: │ content │
        var r: u16 = 1;
        while (r < rect.h -| 1) : (r += 1) {
            pos += style.moveTo(buf[pos..], rect.y + r, rect.x);
            pos += style.cp(buf[pos..], style.box.vertical);
            if (self.fill) {
                pos += core.pad(buf[pos..], inner_w);
            } else {
                // Just move cursor past interior
                pos += style.moveRight(buf[pos..], inner_w);
            }
            pos += style.cp(buf[pos..], style.box.vertical);
        }

        // Bottom edge: └───┘
        pos += style.moveTo(buf[pos..], rect.y + rect.h - 1, rect.x);
        pos += style.cp(buf[pos..], style.box.bottom_left);
        pos += style.hline(buf[pos..], inner_w);
        pos += style.cp(buf[pos..], style.box.bottom_right);

        if (self.border_color) |_| pos += style.reset(buf[pos..]);

        return pos;
    }

    pub fn element(self: *const Box) Element {
        return Element.from(self);
    }
};

// ===========================================================================
// Separator — horizontal line
// ===========================================================================

pub const Separator = struct {
    color: ?style.Color = null,
    is_dim: bool = true,
    char: []const u8 = style.box.horizontal,

    pub fn render(self: *const Separator, buf: []u8, rect: Rect) usize {
        if (rect.w == 0 or rect.h == 0) return 0;

        var pos: usize = 0;
        pos += style.moveTo(buf[pos..], rect.y, rect.x);
        if (self.is_dim) pos += style.dim(buf[pos..]);
        if (self.color) |c| pos += style.fg(buf[pos..], c);

        var col: u16 = 0;
        while (col < rect.w) : (col += 1) {
            pos += style.cp(buf[pos..], self.char);
        }

        if (self.is_dim or self.color != null) pos += style.reset(buf[pos..]);
        return pos;
    }

    pub fn element(self: *const Separator) Element {
        return Element.from(self);
    }
};

// ===========================================================================
// StatusBar — bottom bar with key hints
// ===========================================================================

pub const StatusBar = struct {
    pub const Item = struct {
        key: []const u8, // e.g. "Enter", "Esc", "^C"
        label: []const u8, // e.g. "select", "quit"
    };

    items: []const Item,
    bg_color: ?style.Color = null,

    pub fn render(self: *const StatusBar, buf: []u8, rect: Rect) usize {
        if (rect.w == 0 or rect.h == 0) return 0;

        var pos: usize = 0;
        pos += style.moveTo(buf[pos..], rect.y, rect.x);
        pos += style.inverse(buf[pos..]);

        var vis: u16 = 0;
        for (self.items) |item| {
            if (vis >= rect.w) break;

            // Space before item
            if (vis > 0 and vis + 1 < rect.w) {
                pos += style.cp(buf[pos..], "  ");
                vis += 2;
            }

            // Bold key
            pos += style.bold(buf[pos..]);
            const key_w = @min(item.key.len, rect.w -| vis);
            pos += core.clipText(buf[pos..], item.key, @intCast(key_w));
            vis += @intCast(key_w);
            pos += style.unbold(buf[pos..]);

            // Space + label
            if (vis < rect.w) {
                pos += style.cp(buf[pos..], " ");
                vis += 1;
            }
            const label_w = @min(item.label.len, rect.w -| vis);
            pos += core.clipText(buf[pos..], item.label, @intCast(label_w));
            vis += @intCast(label_w);
        }

        // Fill remaining width
        pos += core.pad(buf[pos..], rect.w -| vis);
        pos += style.reset(buf[pos..]);

        return pos;
    }

    pub fn element(self: *const StatusBar) Element {
        return Element.from(self);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Box renders border" {
    const box = Box{};
    var buf: [2048]u8 = undefined;
    const rect = Rect{ .x = 1, .y = 1, .w = 10, .h = 5 };
    const n = box.render(&buf, rect);
    const output = buf[0..n];
    // Should contain box drawing chars
    try std.testing.expect(std.mem.indexOf(u8, output, style.box.top_left) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, style.box.bottom_right) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, style.box.vertical) != null);
}

test "Box with title" {
    const box = Box{ .title = "Test" };
    var buf: [2048]u8 = undefined;
    const rect = Rect{ .x = 1, .y = 1, .w = 20, .h = 5 };
    const n = box.render(&buf, rect);
    const output = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, output, "Test") != null);
}

test "Box contentRect" {
    const box = Box{};
    const rect = Rect{ .x = 5, .y = 3, .w = 20, .h = 10 };
    const inner = box.contentRect(rect);
    try std.testing.expectEqual(@as(u16, 6), inner.x);
    try std.testing.expectEqual(@as(u16, 4), inner.y);
    try std.testing.expectEqual(@as(u16, 18), inner.w);
    try std.testing.expectEqual(@as(u16, 8), inner.h);
}

test "Box too small" {
    const box = Box{};
    var buf: [256]u8 = undefined;
    const n = box.render(&buf, Rect{ .x = 1, .y = 1, .w = 1, .h = 1 });
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "Separator renders" {
    const sep = Separator{};
    var buf: [512]u8 = undefined;
    const rect = Rect{ .x = 1, .y = 5, .w = 10, .h = 1 };
    const n = sep.render(&buf, rect);
    const output = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, output, style.box.horizontal) != null);
}

test "StatusBar renders items" {
    const bar = StatusBar{
        .items = &.{
            .{ .key = "Enter", .label = "select" },
            .{ .key = "Esc", .label = "quit" },
        },
    };
    var buf: [512]u8 = undefined;
    const rect = Rect{ .x = 1, .y = 24, .w = 40, .h = 1 };
    const n = bar.render(&buf, rect);
    const output = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, output, "Enter") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "select") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Esc") != null);
}

test "StatusBar zero width" {
    const bar = StatusBar{ .items = &.{} };
    var buf: [256]u8 = undefined;
    const n = bar.render(&buf, Rect{ .x = 1, .y = 1, .w = 0, .h = 0 });
    try std.testing.expectEqual(@as(usize, 0), n);
}
