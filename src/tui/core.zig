// core.zig — TUI layout primitives and type-erased component protocol.
//
// Every TUI component is a struct with a render(buf, rect) method.
// Element provides type-erasure so components can be composed in
// layout containers (VStack, HStack) without generics at the call site.

const std = @import("std");
const style = @import("../style.zig");

// ---------------------------------------------------------------------------
// Rect — screen region for positioned rendering
// ---------------------------------------------------------------------------

pub const Rect = struct {
    x: u16, // 1-based column
    y: u16, // 1-based row
    w: u16, // width in columns
    h: u16, // height in rows

    /// Full-screen rect from terminal dimensions.
    pub fn fromSize(cols: u16, rows: u16) Rect {
        return .{ .x = 1, .y = 1, .w = cols, .h = rows };
    }

    /// Shrink by uniform padding on all sides.
    pub fn inner(self: Rect, p: u16) Rect {
        const dx = @min(p, self.w / 2);
        const dy = @min(p, self.h / 2);
        return .{
            .x = self.x + dx,
            .y = self.y + dy,
            .w = self.w -| (dx * 2),
            .h = self.h -| (dy * 2),
        };
    }

    /// Shrink with per-side padding.
    pub fn padding(self: Rect, top: u16, right: u16, bottom: u16, left: u16) Rect {
        return .{
            .x = self.x + left,
            .y = self.y + top,
            .w = self.w -| (left + right),
            .h = self.h -| (top + bottom),
        };
    }

    /// Center a fixed-size rect within self.
    pub fn centered(self: Rect, cw: u16, ch: u16) Rect {
        const w = @min(cw, self.w);
        const h = @min(ch, self.h);
        return .{
            .x = self.x + (self.w -| w) / 2,
            .y = self.y + (self.h -| h) / 2,
            .w = w,
            .h = h,
        };
    }

    /// Center a rect sized by percentage (0-100) of self.
    pub fn centeredPercent(self: Rect, wp: u8, hp: u8) Rect {
        const w: u16 = @intCast(@min(@as(u32, self.w), (@as(u32, self.w) * wp) / 100));
        const h: u16 = @intCast(@min(@as(u32, self.h), (@as(u32, self.h) * hp) / 100));
        return self.centered(w, h);
    }

    /// Get a single row from this rect (0-indexed).
    pub fn row(self: Rect, idx: u16) Rect {
        return .{
            .x = self.x,
            .y = self.y + @min(idx, self.h -| 1),
            .w = self.w,
            .h = 1,
        };
    }

    /// Split vertically into rows. Writes into `out` and returns the used slice.
    pub fn splitRows(self: Rect, sizes: []const Size, out: []Rect) []const Rect {
        return splitAxis(self, sizes, out, .vertical);
    }

    /// Split horizontally into columns.
    pub fn splitCols(self: Rect, sizes: []const Size, out: []Rect) []const Rect {
        return splitAxis(self, sizes, out, .horizontal);
    }

    const Axis = enum { vertical, horizontal };

    fn splitAxis(self: Rect, sizes: []const Size, out: []Rect, axis: Axis) []const Rect {
        const total: u32 = if (axis == .vertical) self.h else self.w;

        // First pass: sum fixed + percent, and total flex weight
        var used: u32 = 0;
        var flex_total: u32 = 0;
        for (sizes) |s| switch (s) {
            .fixed => |n| used += n,
            .percent => |p| used += (total * p) / 100,
            .flex => |w| flex_total += w,
        };
        const remaining = total -| used;

        // Second pass: assign sizes and positions
        var pos: u16 = 0;
        // Track flex remainder for fair distribution
        var flex_assigned: u32 = 0;
        var flex_seen: u32 = 0;
        for (sizes, 0..) |s, i| {
            const sz: u16 = switch (s) {
                .fixed => |n| @intCast(@min(n, total -| pos)),
                .percent => |p| @intCast(@min(total -| pos, (total * p) / 100)),
                .flex => |w| blk: {
                    flex_seen += w;
                    // Calculate cumulative target to distribute remainder fairly
                    const target = (remaining * flex_seen) / flex_total;
                    const this = target - flex_assigned;
                    flex_assigned = target;
                    break :blk @intCast(@min(this, total -| pos));
                },
            };
            out[i] = if (axis == .vertical) .{
                .x = self.x,
                .y = self.y + pos,
                .w = self.w,
                .h = sz,
            } else .{
                .x = self.x + pos,
                .y = self.y,
                .w = sz,
                .h = self.h,
            };
            pos +|= sz;
        }
        return out[0..sizes.len];
    }
};

// ---------------------------------------------------------------------------
// Size — layout size specification
// ---------------------------------------------------------------------------

pub const Size = union(enum) {
    fixed: u32,
    flex: u32,
    percent: u32,
};

// ---------------------------------------------------------------------------
// Element — type-erased renderable component
// ---------------------------------------------------------------------------

pub const Element = struct {
    ctx: *const anyopaque,
    render_fn: *const fn (ctx: *const anyopaque, buf: []u8, rect: Rect) usize,

    pub fn render(self: Element, buf: []u8, rect: Rect) usize {
        return self.render_fn(self.ctx, buf, rect);
    }

    /// Wrap any pointer-to-component as an Element.
    /// The component must have: `fn render(*const T, []u8, Rect) usize`
    pub fn from(ptr: anytype) Element {
        const Ptr = @TypeOf(ptr);
        const Child = @typeInfo(Ptr).pointer.child;
        return .{
            .ctx = @ptrCast(ptr),
            .render_fn = &struct {
                fn f(ctx: *const anyopaque, buf: []u8, rect: Rect) usize {
                    const self: *const Child = @ptrCast(@alignCast(ctx));
                    return self.render(buf, rect);
                }
            }.f,
        };
    }
};

// ---------------------------------------------------------------------------
// Layout containers
// ---------------------------------------------------------------------------

pub const max_children = 16;

pub const VStack = struct {
    sizes: []const Size,
    children: []const Element,

    pub fn render(self: *const VStack, buf: []u8, rect: Rect) usize {
        var rects: [max_children]Rect = undefined;
        const splits = rect.splitRows(self.sizes, &rects);
        var pos: usize = 0;
        for (self.children, splits) |child, r| {
            pos += child.render(buf[pos..], r);
        }
        return pos;
    }

    pub fn element(self: *const VStack) Element {
        return Element.from(self);
    }
};

pub const HStack = struct {
    sizes: []const Size,
    children: []const Element,

    pub fn render(self: *const HStack, buf: []u8, rect: Rect) usize {
        var rects: [max_children]Rect = undefined;
        const splits = rect.splitCols(self.sizes, &rects);
        var pos: usize = 0;
        for (self.children, splits) |child, r| {
            pos += child.render(buf[pos..], r);
        }
        return pos;
    }

    pub fn element(self: *const HStack) Element {
        return Element.from(self);
    }
};

// ---------------------------------------------------------------------------
// Rendering helpers
// ---------------------------------------------------------------------------

/// Write n space characters.
pub fn pad(buf: []u8, n: u16) usize {
    const count = @min(@as(usize, n), buf.len);
    @memset(buf[0..count], ' ');
    return count;
}

/// Copy text into buf, limited to max_w characters.
/// Returns bytes written. Assumes ASCII width (1 byte = 1 column).
/// For text that may contain CJK or emoji, use clipTextUnicode instead.
pub fn clipText(buf: []u8, text: []const u8, max_w: u16) usize {
    const n = @min(text.len, @min(@as(usize, max_w), buf.len));
    @memcpy(buf[0..n], text[0..n]);
    return n;
}

pub const unicode = @import("unicode.zig");

/// Copy text into buf, limited to max_w display columns.
/// Handles CJK (width 2), combining marks (width 0), and emoji correctly.
/// Returns a ClipResult with bytes written and visible column count.
pub fn clipTextUnicode(buf: []u8, text: []const u8, max_w: u16) unicode.ClipResult {
    return unicode.clipText(buf, text, max_w);
}

/// Display width of a UTF-8 string in terminal columns.
pub fn displayWidth(text: []const u8) u16 {
    return unicode.displayWidth(text);
}

/// Render a line: moveTo + content + space-pad to fill width.
/// `content_len` is the visible character count of what was already written
/// at buf[0..bytes] (for styled text where bytes > visible chars).
pub fn padLine(buf: []u8, visible: u16, width: u16) usize {
    if (visible >= width) return 0;
    return pad(buf, width - visible);
}

// ---------------------------------------------------------------------------
// Scrollbar — shared vertical scrollbar renderer
// ---------------------------------------------------------------------------

/// Render a vertical scrollbar track with thumb.
/// `y` is the 1-based row to start, `col` is the 1-based column,
/// `visible` is the track height, `total` is the item count,
/// `offset` is the current scroll position.
pub fn renderScrollbar(buf: []u8, y: u16, col: u16, visible: u16, total: usize, offset: usize) usize {
    if (total <= visible) return 0;

    var pos: usize = 0;

    const thumb_h = @max(1, (@as(u32, visible) * visible) / @as(u32, @intCast(total)));
    const max_offset = total - visible;
    const track_space = visible - @as(u16, @intCast(thumb_h));
    const thumb_top: u16 = if (max_offset > 0)
        @intCast((@as(u32, @intCast(offset)) * track_space) / @as(u32, @intCast(max_offset)))
    else
        0;

    pos += style.dim(buf[pos..]);

    var row: u16 = 0;
    while (row < visible) : (row += 1) {
        pos += style.moveTo(buf[pos..], y + row, col);
        if (row >= thumb_top and row < thumb_top + @as(u16, @intCast(thumb_h))) {
            pos += style.cp(buf[pos..], style.box.scrollbar_thumb);
        } else {
            pos += style.cp(buf[pos..], style.box.scrollbar_track);
        }
    }

    pos += style.reset(buf[pos..]);
    return pos;
}

// ---------------------------------------------------------------------------
// Word separators — shared by editor.zig and tui/Input.zig
// ---------------------------------------------------------------------------

/// Characters that delimit words for ^W, Alt+B/F, etc.
pub fn isWordSep(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '/' or ch == '.' or ch == '-' or ch == '_' or ch == ':' or ch == '|';
}

// ---------------------------------------------------------------------------
// Action — component key handling result
// ---------------------------------------------------------------------------

pub const Action = enum {
    none, // key handled, no state change (e.g. cursor blink)
    changed, // content or selection changed
    submit, // Enter pressed
    cancel, // Escape pressed
    ignored, // key not handled — caller should process
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Rect.fromSize" {
    const r = Rect.fromSize(80, 24);
    try std.testing.expectEqual(@as(u16, 1), r.x);
    try std.testing.expectEqual(@as(u16, 1), r.y);
    try std.testing.expectEqual(@as(u16, 80), r.w);
    try std.testing.expectEqual(@as(u16, 24), r.h);
}

test "Rect.inner" {
    const r = Rect.fromSize(80, 24).inner(1);
    try std.testing.expectEqual(@as(u16, 2), r.x);
    try std.testing.expectEqual(@as(u16, 2), r.y);
    try std.testing.expectEqual(@as(u16, 78), r.w);
    try std.testing.expectEqual(@as(u16, 22), r.h);
}

test "Rect.inner overflow" {
    const base = Rect{ .x = 1, .y = 1, .w = 4, .h = 2 };
    const r = base.inner(5);
    try std.testing.expectEqual(@as(u16, 3), r.x);
    try std.testing.expectEqual(@as(u16, 2), r.y);
    try std.testing.expectEqual(@as(u16, 0), r.w);
    try std.testing.expectEqual(@as(u16, 0), r.h);
}

test "Rect.centered" {
    const screen = Rect.fromSize(80, 24);
    const popup = screen.centered(40, 10);
    try std.testing.expectEqual(@as(u16, 21), popup.x);
    try std.testing.expectEqual(@as(u16, 8), popup.y);
    try std.testing.expectEqual(@as(u16, 40), popup.w);
    try std.testing.expectEqual(@as(u16, 10), popup.h);
}

test "Rect.centeredPercent" {
    const screen = Rect.fromSize(100, 50);
    const popup = screen.centeredPercent(60, 80);
    try std.testing.expectEqual(@as(u16, 60), popup.w);
    try std.testing.expectEqual(@as(u16, 40), popup.h);
}

test "Rect.padding" {
    const r = Rect.fromSize(80, 24).padding(2, 3, 4, 5);
    try std.testing.expectEqual(@as(u16, 6), r.x);
    try std.testing.expectEqual(@as(u16, 3), r.y);
    try std.testing.expectEqual(@as(u16, 72), r.w);
    try std.testing.expectEqual(@as(u16, 18), r.h);
}

test "Rect.row" {
    const r = Rect.fromSize(80, 24).row(2);
    try std.testing.expectEqual(@as(u16, 1), r.x);
    try std.testing.expectEqual(@as(u16, 3), r.y);
    try std.testing.expectEqual(@as(u16, 80), r.w);
    try std.testing.expectEqual(@as(u16, 1), r.h);
}

test "Rect.splitRows fixed only" {
    const r = Rect{ .x = 1, .y = 1, .w = 80, .h = 10 };
    var out: [3]Rect = undefined;
    const s = r.splitRows(&.{ Size{ .fixed = 2 }, Size{ .fixed = 3 }, Size{ .fixed = 5 } }, &out);
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqual(@as(u16, 2), s[0].h);
    try std.testing.expectEqual(@as(u16, 3), s[1].h);
    try std.testing.expectEqual(@as(u16, 5), s[2].h);
    try std.testing.expectEqual(@as(u16, 1), s[0].y);
    try std.testing.expectEqual(@as(u16, 3), s[1].y);
    try std.testing.expectEqual(@as(u16, 6), s[2].y);
}

test "Rect.splitRows with flex" {
    const r = Rect{ .x = 1, .y = 1, .w = 80, .h = 20 };
    var out: [3]Rect = undefined;
    const s = r.splitRows(&.{ Size{ .fixed = 1 }, Size{ .flex = 1 }, Size{ .fixed = 1 } }, &out);
    try std.testing.expectEqual(@as(u16, 1), s[0].h);
    try std.testing.expectEqual(@as(u16, 18), s[1].h);
    try std.testing.expectEqual(@as(u16, 1), s[2].h);
}

test "Rect.splitRows flex distribution" {
    const r = Rect{ .x = 1, .y = 1, .w = 80, .h = 12 };
    var out: [3]Rect = undefined;
    const s = r.splitRows(&.{ Size{ .flex = 1 }, Size{ .fixed = 2 }, Size{ .flex = 1 } }, &out);
    try std.testing.expectEqual(@as(u16, 5), s[0].h);
    try std.testing.expectEqual(@as(u16, 2), s[1].h);
    try std.testing.expectEqual(@as(u16, 5), s[2].h);
}

test "Rect.splitCols" {
    const r = Rect.fromSize(80, 24);
    var out: [2]Rect = undefined;
    const s = r.splitCols(&.{ Size{ .fixed = 20 }, Size{ .flex = 1 } }, &out);
    try std.testing.expectEqual(@as(u16, 20), s[0].w);
    try std.testing.expectEqual(@as(u16, 60), s[1].w);
    try std.testing.expectEqual(@as(u16, 24), s[0].h);
}

test "Element.from and render" {
    const Dummy = struct {
        value: u8,
        pub fn render(self: *const @This(), buf: []u8, _: Rect) usize {
            buf[0] = self.value;
            return 1;
        }
    };
    const comp = Dummy{ .value = 42 };
    const elem = Element.from(&comp);
    var buf: [16]u8 = undefined;
    const n = elem.render(&buf, Rect.fromSize(80, 24));
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 42), buf[0]);
}

test "VStack renders children in order" {
    const Marker = struct {
        ch: u8,
        pub fn render(self: *const @This(), buf: []u8, _: Rect) usize {
            buf[0] = self.ch;
            return 1;
        }
    };
    const a = Marker{ .ch = 'A' };
    const b = Marker{ .ch = 'B' };
    const stack = VStack{
        .sizes = &.{ Size{ .fixed = 1 }, Size{ .flex = 1 } },
        .children = &.{ Element.from(&a), Element.from(&b) },
    };
    var buf: [16]u8 = undefined;
    const n = stack.render(&buf, Rect.fromSize(80, 24));
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 'A'), buf[0]);
    try std.testing.expectEqual(@as(u8, 'B'), buf[1]);
}

test "pad writes spaces" {
    var buf: [8]u8 = undefined;
    const n = pad(&buf, 5);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("     ", buf[0..5]);
}

test "clipText truncates" {
    var buf: [8]u8 = undefined;
    const n = clipText(&buf, "hello world", 5);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..5]);
}

test "renderScrollbar produces output" {
    var buf: [512]u8 = undefined;
    const n = renderScrollbar(&buf, 1, 80, 5, 20, 0);
    try std.testing.expect(n > 0);
    // Should contain thumb and track chars
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], style.box.scrollbar_thumb) != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], style.box.scrollbar_track) != null);
}

test "renderScrollbar no output when fits" {
    var buf: [256]u8 = undefined;
    const n = renderScrollbar(&buf, 1, 80, 10, 5, 0);
    try std.testing.expectEqual(@as(usize, 0), n);
}
