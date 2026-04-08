// Popup.zig — Modal popup overlay with border and relative sizing.
//
// Renders a centered popup over the terminal screen with a bordered
// frame. Size can be fixed (columns/rows) or percentage of screen.
// Use contentRect() to get the inner area for child components.

const std = @import("std");
const core = @import("core.zig");
const style = @import("../style.zig");
const BoxComponent = @import("Box.zig");
const Screen = @import("Screen.zig");

const Rect = core.Rect;
const Element = core.Element;

// ---------------------------------------------------------------------------
// Popup component
// ---------------------------------------------------------------------------

pub const PopupSize = union(enum) {
    fixed: u16,
    percent: u8,
};

title: []const u8 = "",
width: PopupSize = .{ .percent = 60 },
height: PopupSize = .{ .percent = 80 },
border_color: ?style.Color = null,
title_color: ?style.Color = null,
clear_background: bool = true,

const Self = @This();

/// Calculate the popup rect centered in the screen.
pub fn rect(self: *const Self, screen: Rect) Rect {
    const w = resolveSize(self.width, screen.w);
    const h = resolveSize(self.height, screen.h);
    return screen.centered(w, h);
}

/// Get content rect (inside the border).
pub fn contentRect(self: *const Self, screen: Rect) Rect {
    return self.rect(screen).inner(1);
}

/// Render the popup frame (border + cleared interior).
/// Does NOT render children — caller places them in contentRect().
pub fn render(self: *const Self, buf: []u8, screen: Rect) usize {
    const popup_rect = self.rect(screen);
    if (popup_rect.w < 2 or popup_rect.h < 2) return 0;

    var pos: usize = 0;

    // Clear area behind popup (optional dim background effect)
    if (self.clear_background) {
        pos += clearRect(buf[pos..], popup_rect);
    }

    // Render box border
    const box = BoxComponent.Box{
        .title = self.title,
        .border_color = self.border_color,
        .title_color = self.title_color,
        .fill = true,
    };
    pos += box.render(buf[pos..], popup_rect);

    return pos;
}

/// Draw the popup frame to a Screen (double-buffered).
pub fn draw(self: *const Self, scr: *Screen, screen: Rect) void {
    const popup_rect = self.rect(screen);
    if (popup_rect.w < 2 or popup_rect.h < 2) return;

    // Clear popup area
    if (self.clear_background) {
        scr.fill(popup_rect, .{});
    }

    // Draw box border
    const box = BoxComponent.Box{
        .title = self.title,
        .border_color = self.border_color,
        .title_color = self.title_color,
        .fill = true,
    };
    box.draw(scr, popup_rect);
}

pub fn element(self: *const Self) Element {
    return Element.from(self);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn resolveSize(s: PopupSize, parent: u16) u16 {
    return switch (s) {
        .fixed => |n| @min(n, parent),
        .percent => |p| @intCast(@min(@as(u32, parent), (@as(u32, parent) * p) / 100)),
    };
}

/// Clear a rectangular area with spaces.
fn clearRect(buf: []u8, r: Rect) usize {
    var pos: usize = 0;
    var row: u16 = 0;
    while (row < r.h) : (row += 1) {
        pos += style.moveTo(buf[pos..], r.y + row, r.x);
        pos += core.pad(buf[pos..], r.w);
    }
    return pos;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "rect with percent size" {
    const popup: Self = .{
        .width = .{ .percent = 50 },
        .height = .{ .percent = 50 },
    };
    const screen = Rect.fromSize(80, 24);
    const r = popup.rect(screen);
    try testing.expectEqual(@as(u16, 40), r.w);
    try testing.expectEqual(@as(u16, 12), r.h);
    // Centered
    try testing.expectEqual(@as(u16, 21), r.x);
    try testing.expectEqual(@as(u16, 7), r.y);
}

test "rect with fixed size" {
    const popup: Self = .{
        .width = .{ .fixed = 30 },
        .height = .{ .fixed = 10 },
    };
    const screen = Rect.fromSize(80, 24);
    const r = popup.rect(screen);
    try testing.expectEqual(@as(u16, 30), r.w);
    try testing.expectEqual(@as(u16, 10), r.h);
}

test "rect clamps to screen" {
    const popup: Self = .{
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 100 },
    };
    const screen = Rect.fromSize(80, 24);
    const r = popup.rect(screen);
    try testing.expectEqual(@as(u16, 80), r.w);
    try testing.expectEqual(@as(u16, 24), r.h);
}

test "contentRect inside border" {
    const popup: Self = .{
        .width = .{ .fixed = 20 },
        .height = .{ .fixed = 10 },
    };
    const screen = Rect.fromSize(80, 24);
    const inner = popup.contentRect(screen);
    const outer = popup.rect(screen);
    try testing.expectEqual(outer.x + 1, inner.x);
    try testing.expectEqual(outer.y + 1, inner.y);
    try testing.expectEqual(outer.w - 2, inner.w);
    try testing.expectEqual(outer.h - 2, inner.h);
}

test "render produces output" {
    const popup: Self = .{
        .title = "Test Popup",
        .width = .{ .fixed = 30 },
        .height = .{ .fixed = 10 },
    };
    var buf: [4096]u8 = undefined;
    const n = popup.render(&buf, Rect.fromSize(80, 24));
    try testing.expect(n > 0);
    const output = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, output, "Test Popup") != null);
    try testing.expect(std.mem.indexOf(u8, output, style.box.top_left) != null);
}

test "render tiny screen" {
    const popup: Self = .{
        .width = .{ .percent = 80 },
        .height = .{ .percent = 80 },
    };
    var buf: [256]u8 = undefined;
    // Very small screen — popup should handle gracefully
    const n = popup.render(&buf, Rect.fromSize(3, 3));
    // Might render or not depending on size, but shouldn't crash
    _ = n;
}
