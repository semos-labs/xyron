// Table.zig — Column-based table with headers, alignment, and scrolling.
//
// Renders a table with configurable columns (fixed/flex width, alignment),
// a styled header row, selectable rows, and a scrollbar when needed.

const std = @import("std");
const core = @import("core.zig");
const style = @import("../style.zig");
const keys = @import("../keys.zig");
const Text = @import("Text.zig");

const Rect = core.Rect;
const Element = core.Element;
const Action = core.Action;
const Key = keys.Key;

// ---------------------------------------------------------------------------
// Table component
// ---------------------------------------------------------------------------

pub const Column = struct {
    header: []const u8,
    width: core.Size,
    alignment: Text.Alignment = .left,
};

columns: []const Column = &.{},
/// Each row is a slice of cell strings, one per column.
rows: []const []const []const u8 = &.{},
selected: ?usize = null, // null = no selection mode
scroll_offset: usize = 0,
show_header: bool = true,
show_scrollbar: bool = true,
focused: bool = true,
header_color: ?style.Color = null,

const Self = @This();

/// Get the currently selected row index, or null.
pub fn selectedRow(self: *const Self) ?usize {
    return self.selected;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

pub fn render(self: *const Self, buf: []u8, rect: Rect) usize {
    if (rect.w == 0 or rect.h == 0 or self.columns.len == 0) return 0;

    var pos: usize = 0;
    const has_scrollbar = self.show_scrollbar and self.rows.len > self.bodyHeight(rect);
    const table_w: u16 = if (has_scrollbar) rect.w -| 1 else rect.w;

    // Resolve column widths
    var col_widths: [core.max_children]u16 = undefined;
    self.resolveColumnWidths(table_w, &col_widths);

    // Header row
    var data_y = rect.y;
    if (self.show_header) {
        pos += style.moveTo(buf[pos..], rect.y, rect.x);
        pos += style.inverse(buf[pos..]);
        if (self.header_color) |c| pos += style.fg(buf[pos..], c);

        var vis: u16 = 0;
        for (self.columns, 0..) |col, ci| {
            const cw = col_widths[ci];
            pos += renderCell(buf[pos..], col.header, cw, col.alignment);
            vis += cw;
        }
        // Pad remaining
        pos += core.pad(buf[pos..], table_w -| vis);
        pos += style.reset(buf[pos..]);
        data_y += 1;
    }

    // Data rows
    const body_h = self.bodyHeight(rect);
    var row_i: u16 = 0;
    while (row_i < body_h) : (row_i += 1) {
        const data_idx = self.scroll_offset + row_i;
        pos += style.moveTo(buf[pos..], data_y + row_i, rect.x);

        if (data_idx < self.rows.len) {
            const is_selected = self.selected != null and data_idx == self.selected.?;

            if (is_selected and self.focused) {
                pos += style.inverse(buf[pos..]);
                pos += style.bold(buf[pos..]);
            } else if (is_selected) {
                pos += style.inverse(buf[pos..]);
            }

            const row_data = self.rows[data_idx];
            var vis: u16 = 0;
            for (self.columns, 0..) |col, ci| {
                const cw = col_widths[ci];
                const cell = if (ci < row_data.len) row_data[ci] else "";
                pos += renderCell(buf[pos..], cell, cw, col.alignment);
                vis += cw;
            }
            pos += core.pad(buf[pos..], table_w -| vis);

            if (is_selected) pos += style.reset(buf[pos..]);
        } else {
            pos += core.pad(buf[pos..], table_w);
        }
    }

    // Scrollbar
    if (has_scrollbar) {
        pos += core.renderScrollbar(buf[pos..], data_y, rect.x + rect.w - 1, body_h, self.rows.len, self.scroll_offset);
    }

    return pos;
}

fn bodyHeight(self: *const Self, rect: Rect) u16 {
    return if (self.show_header) rect.h -| 1 else rect.h;
}

fn resolveColumnWidths(self: *const Self, total_w: u16, out: []u16) void {
    var used: u32 = 0;
    var flex_total: u32 = 0;

    for (self.columns, 0..) |col, i| {
        _ = i;
        switch (col.width) {
            .fixed => |n| used += n,
            .percent => |p| used += (@as(u32, total_w) * p) / 100,
            .flex => |w| flex_total += w,
        }
    }

    const remaining = @as(u32, total_w) -| used;
    var flex_assigned: u32 = 0;
    var flex_seen: u32 = 0;

    for (self.columns, 0..) |col, i| {
        out[i] = switch (col.width) {
            .fixed => |n| @intCast(@min(n, total_w)),
            .percent => |p| @intCast((@as(u32, total_w) * p) / 100),
            .flex => |w| blk: {
                flex_seen += w;
                const target = (remaining * flex_seen) / flex_total;
                const this = target - flex_assigned;
                flex_assigned = target;
                break :blk @intCast(this);
            },
        };
    }
}

fn renderCell(buf: []u8, text: []const u8, width: u16, alignment: Text.Alignment) usize {
    if (width == 0) return 0;
    var pos: usize = 0;

    const text_w: u16 = @intCast(@min(text.len, width));
    const left_pad: u16 = switch (alignment) {
        .left => 0,
        .center => (width -| text_w) / 2,
        .right => width -| text_w,
    };

    pos += core.pad(buf[pos..], left_pad);
    pos += core.clipText(buf[pos..], text, text_w);
    pos += core.pad(buf[pos..], width -| left_pad -| text_w);

    return pos;
}

pub fn element(self: *const Self) Element {
    return Element.from(self);
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

pub fn handleKey(self: *Self, key: Key) Action {
    if (self.selected == null) return .ignored;
    switch (key) {
        .up, .ctrl_p => {
            if (self.selected.? > 0) self.selected = self.selected.? - 1;
            return .changed;
        },
        .down, .ctrl_n => {
            if (self.rows.len > 0 and self.selected.? < self.rows.len - 1)
                self.selected = self.selected.? + 1;
            return .changed;
        },
        .home => {
            self.selected = 0;
            return .changed;
        },
        .end_key => {
            if (self.rows.len > 0) self.selected = self.rows.len - 1;
            return .changed;
        },
        .enter => return .submit,
        .escape => return .cancel,
        else => return .ignored,
    }
}

/// Ensure selected row is visible. Call before render.
pub fn ensureVisible(self: *Self, rect: Rect) void {
    const body = self.bodyHeight(rect);
    if (self.selected) |sel| {
        if (sel < self.scroll_offset) {
            self.scroll_offset = sel;
        } else if (sel >= self.scroll_offset + body) {
            self.scroll_offset = sel - body + 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "resolveColumnWidths fixed" {
    const table: Self = .{
        .columns = &.{
            .{ .header = "A", .width = .{ .fixed = 10 } },
            .{ .header = "B", .width = .{ .fixed = 20 } },
        },
    };
    var widths: [core.max_children]u16 = undefined;
    table.resolveColumnWidths(80, &widths);
    try testing.expectEqual(@as(u16, 10), widths[0]);
    try testing.expectEqual(@as(u16, 20), widths[1]);
}

test "resolveColumnWidths with flex" {
    const table: Self = .{
        .columns = &.{
            .{ .header = "A", .width = .{ .fixed = 10 } },
            .{ .header = "B", .width = .{ .flex = 1 } },
        },
    };
    var widths: [core.max_children]u16 = undefined;
    table.resolveColumnWidths(80, &widths);
    try testing.expectEqual(@as(u16, 10), widths[0]);
    try testing.expectEqual(@as(u16, 70), widths[1]);
}

test "renderCell left aligned" {
    var buf: [32]u8 = undefined;
    const n = renderCell(&buf, "hi", 10, .left);
    try testing.expectEqualStrings("hi        ", buf[0..n]);
}

test "renderCell right aligned" {
    var buf: [32]u8 = undefined;
    const n = renderCell(&buf, "hi", 10, .right);
    try testing.expectEqualStrings("        hi", buf[0..n]);
}

test "renderCell center aligned" {
    var buf: [32]u8 = undefined;
    const n = renderCell(&buf, "hi", 10, .center);
    try testing.expectEqualStrings("    hi    ", buf[0..n]);
}

test "handleKey navigation" {
    const row0: []const []const u8 = &.{ "a", "1" };
    const row1: []const []const u8 = &.{ "b", "2" };
    const row2: []const []const u8 = &.{ "c", "3" };
    var table: Self = .{
        .columns = &.{
            .{ .header = "Name", .width = .{ .fixed = 10 } },
            .{ .header = "Val", .width = .{ .fixed = 5 } },
        },
        .rows = &.{ row0, row1, row2 },
        .selected = 0,
    };
    try testing.expectEqual(Action.changed, table.handleKey(.down));
    try testing.expectEqual(@as(?usize, 1), table.selected);
    try testing.expectEqual(Action.changed, table.handleKey(.down));
    try testing.expectEqual(@as(?usize, 2), table.selected);
    try testing.expectEqual(Action.changed, table.handleKey(.up));
    try testing.expectEqual(@as(?usize, 1), table.selected);
}

test "render produces output" {
    const row0: []const []const u8 = &.{"hello"};
    const table: Self = .{
        .columns = &.{
            .{ .header = "Col", .width = .{ .fixed = 10 } },
        },
        .rows = &.{row0},
    };
    var buf: [2048]u8 = undefined;
    const n = table.render(&buf, Rect{ .x = 1, .y = 1, .w = 20, .h = 5 });
    try testing.expect(n > 0);
    const output = buf[0..n];
    try testing.expect(std.mem.indexOf(u8, output, "Col") != null);
    try testing.expect(std.mem.indexOf(u8, output, "hello") != null);
}

test "render empty table" {
    const table: Self = .{
        .columns = &.{
            .{ .header = "A", .width = .{ .fixed = 10 } },
        },
    };
    var buf: [2048]u8 = undefined;
    const n = table.render(&buf, Rect{ .x = 1, .y = 1, .w = 20, .h = 5 });
    try testing.expect(n > 0);
}

test "render zero rect" {
    const table: Self = .{};
    var buf: [256]u8 = undefined;
    const n = table.render(&buf, Rect{ .x = 1, .y = 1, .w = 0, .h = 0 });
    try testing.expectEqual(@as(usize, 0), n);
}

test "bodyHeight respects show_header" {
    const rect = Rect{ .x = 1, .y = 1, .w = 80, .h = 10 };
    const with_header: Self = .{
        .columns = &.{.{ .header = "A", .width = .{ .fixed = 10 } }},
        .show_header = true,
    };
    const no_header: Self = .{
        .columns = &.{.{ .header = "A", .width = .{ .fixed = 10 } }},
        .show_header = false,
    };
    try testing.expectEqual(@as(u16, 9), with_header.bodyHeight(rect));
    try testing.expectEqual(@as(u16, 10), no_header.bodyHeight(rect));
}
