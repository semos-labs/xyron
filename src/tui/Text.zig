// Text.zig — Styled text rendering component.
//
// Renders a single line of text with optional color, bold, dim, italic,
// and alignment (left/center/right). Text is truncated with ellipsis
// if it exceeds the rect width.

const std = @import("std");
const core = @import("core.zig");
const style = @import("../style.zig");

const Rect = core.Rect;
const Element = core.Element;

pub const Alignment = enum { left, center, right };

// ---------------------------------------------------------------------------
// Text component
// ---------------------------------------------------------------------------

content: []const u8 = "",
color: ?style.Color = null,
bg_color: ?style.Color = null,
is_bold: bool = false,
is_dim: bool = false,
is_italic: bool = false,
is_inverse: bool = false,
alignment: Alignment = .left,

const Self = @This();

pub fn render(self: *const Self, buf: []u8, rect: Rect) usize {
    if (rect.w == 0 or rect.h == 0) return 0;

    var pos: usize = 0;
    pos += style.moveTo(buf[pos..], rect.y, rect.x);

    // Apply styling
    const styled = self.is_bold or self.is_dim or self.is_italic or
        self.is_inverse or self.color != null or self.bg_color != null;
    if (self.is_bold) pos += style.bold(buf[pos..]);
    if (self.is_dim) pos += style.dim(buf[pos..]);
    if (self.is_italic) pos += style.italic(buf[pos..]);
    if (self.is_inverse) pos += style.inverse(buf[pos..]);
    if (self.color) |c| pos += style.fg(buf[pos..], c);
    if (self.bg_color) |c| pos += style.bg(buf[pos..], c);

    const max_w: usize = rect.w;
    const text = self.content;
    const text_w = @min(text.len, max_w);
    const needs_ellipsis = text.len > max_w and max_w >= 1;
    const display_w = if (needs_ellipsis) max_w -| 1 else text_w;

    // Alignment left-padding
    const content_w: u16 = @intCast(if (needs_ellipsis) max_w else text_w);
    const left_pad: u16 = switch (self.alignment) {
        .left => 0,
        .center => (rect.w -| content_w) / 2,
        .right => rect.w -| content_w,
    };
    pos += core.pad(buf[pos..], left_pad);

    // Text content
    pos += core.clipText(buf[pos..], text, @intCast(display_w));
    if (needs_ellipsis) pos += style.cp(buf[pos..], style.box.ellipsis);

    // Right padding
    const right_pad = rect.w -| left_pad -| content_w;
    pos += core.pad(buf[pos..], right_pad);

    if (styled) pos += style.reset(buf[pos..]);

    return pos;
}

pub fn element(self: *const Self) Element {
    return Element.from(self);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "render plain text" {
    const text = Self{ .content = "hello" };
    var buf: [256]u8 = undefined;
    const rect = Rect{ .x = 1, .y = 1, .w = 10, .h = 1 };
    const n = text.render(&buf, rect);
    // Should contain moveTo + "hello" + 5 spaces
    const output = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
}

test "render truncated text" {
    const text = Self{ .content = "hello world" };
    var buf: [256]u8 = undefined;
    const rect = Rect{ .x = 1, .y = 1, .w = 5, .h = 1 };
    const n = text.render(&buf, rect);
    const output = buf[0..n];
    // Should have 4 chars + ellipsis
    try std.testing.expect(std.mem.indexOf(u8, output, "hell") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, style.box.ellipsis) != null);
}

test "render with center alignment" {
    const text = Self{ .content = "hi", .alignment = .center };
    var buf: [256]u8 = undefined;
    const rect = Rect{ .x = 1, .y = 1, .w = 10, .h = 1 };
    const n = text.render(&buf, rect);
    try std.testing.expect(n > 0);
}

test "render with right alignment" {
    const text = Self{ .content = "hi", .alignment = .right };
    var buf: [256]u8 = undefined;
    const rect = Rect{ .x = 1, .y = 1, .w = 10, .h = 1 };
    const n = text.render(&buf, rect);
    try std.testing.expect(n > 0);
}

test "render styled text includes reset" {
    const text = Self{ .content = "err", .color = .red, .is_bold = true };
    var buf: [256]u8 = undefined;
    const rect = Rect{ .x = 1, .y = 1, .w = 10, .h = 1 };
    const n = text.render(&buf, rect);
    const output = buf[0..n];
    // Should contain bold, red, text, and reset
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null);
}

test "render zero-size rect" {
    const text = Self{ .content = "hello" };
    var buf: [256]u8 = undefined;
    const n = text.render(&buf, Rect{ .x = 1, .y = 1, .w = 0, .h = 0 });
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "element type erasure" {
    const text = Self{ .content = "test" };
    const elem = text.element();
    var buf: [256]u8 = undefined;
    const n = elem.render(&buf, Rect{ .x = 1, .y = 1, .w = 10, .h = 1 });
    try std.testing.expect(n > 0);
}
