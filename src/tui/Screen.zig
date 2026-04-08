// Screen.zig — Double-buffered cell grid with diff-based terminal output.
//
// Components draw into the back buffer via write/fill/hline methods.
// flush() compares back vs front, emits only changed cells as minimal
// ANSI sequences, then copies back→front. This eliminates flicker
// because unchanged cells produce zero terminal output.
//
// Usage:
//
//   var screen = Screen.init(cols, rows);
//   // ... draw components via screen.write / screen.fill / etc ...
//   screen.flush(tty);         // diff + emit
//   screen.beginFrame();       // clear back buffer for next frame

const std = @import("std");
const style = @import("../style.zig");
const core = @import("core.zig");
const unicode = @import("unicode.zig");

const Rect = core.Rect;

// ---------------------------------------------------------------------------
// Cell — single terminal cell
// ---------------------------------------------------------------------------

pub const Cell = struct {
    char: [4]u8 = .{ ' ', 0, 0, 0 },
    char_len: u3 = 1,
    fg: u8 = 0, // style.Color int value, 0 = default (39)
    bg: u8 = 0,
    attrs: Attrs = .{},

    pub const Attrs = packed struct(u8) {
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,
        inverse: bool = false,
        _padding: u4 = 0,
    };

    const default_fg: u8 = @intFromEnum(style.Color.default);
    const default_bg: u8 = @intFromEnum(style.Color.default) + 10; // 49

    pub fn eql(a: Cell, b: Cell) bool {
        return std.mem.eql(u8, &a.char, &b.char) and
            a.char_len == b.char_len and
            a.fg == b.fg and
            a.bg == b.bg and
            @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
    }

    pub fn setChar(self: *Cell, ch: u8) void {
        self.char = .{ ch, 0, 0, 0 };
        self.char_len = 1;
    }

    pub fn setUtf8(self: *Cell, bytes: []const u8) void {
        const len: u3 = @intCast(@min(bytes.len, 4));
        self.char = .{ 0, 0, 0, 0 };
        for (0..len) |i| self.char[i] = bytes[i];
        self.char_len = len;
    }

    pub fn charSlice(self: *const Cell) []const u8 {
        return self.char[0..self.char_len];
    }
};

// ---------------------------------------------------------------------------
// Style — drawing state for write operations
// ---------------------------------------------------------------------------

pub const Style = struct {
    fg: ?style.Color = null, // null = default
    bg: ?style.Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    inverse: bool = false,

    pub const default: Style = .{};

    fn fgByte(self: Style) u8 {
        return if (self.fg) |c| @intFromEnum(c) else 0;
    }

    fn bgByte(self: Style) u8 {
        return if (self.bg) |c| @intFromEnum(c) else 0;
    }

    fn attrs(self: Style) Cell.Attrs {
        return .{
            .bold = self.bold,
            .dim = self.dim,
            .italic = self.italic,
            .inverse = self.inverse,
        };
    }
};

// ---------------------------------------------------------------------------
// Screen — double-buffered grid
// ---------------------------------------------------------------------------

pub const max_cols = 320;
pub const max_rows = 128;
const grid_size = max_cols * max_rows;

const Self = @This();

back: [grid_size]Cell = undefined,
front: [grid_size]Cell = undefined,
width: u16 = 0,
height: u16 = 0,
/// Cursor position for terminal cursor (e.g. text input).
cursor_row: u16 = 0,
cursor_col: u16 = 0,
cursor_visible: bool = false,
/// Track whether front buffer has valid data (false on first frame).
initialized: bool = false,

pub fn init(cols: u16, rows: u16) Self {
    var scr = Self{
        .width = @min(cols, max_cols),
        .height = @min(rows, max_rows),
    };
    const blank = Cell{};
    @memset(&scr.back, blank);
    @memset(&scr.front, blank);
    return scr;
}

pub fn resize(self: *Self, cols: u16, rows: u16) void {
    self.width = @min(cols, max_cols);
    self.height = @min(rows, max_rows);
    // Invalidate front buffer so next flush redraws everything
    self.initialized = false;
    const blank = Cell{};
    @memset(&self.back, blank);
    @memset(&self.front, blank);
}

/// Clear the back buffer for a new frame. Call before drawing.
pub fn beginFrame(self: *Self) void {
    const blank = Cell{};
    @memset(&self.back, blank);
    self.cursor_visible = false;
}

/// Set cursor position (1-based row/col, matching terminal conventions).
pub fn setCursor(self: *Self, row: u16, col: u16) void {
    self.cursor_row = row;
    self.cursor_col = col;
    self.cursor_visible = true;
}

pub fn hideCursor(self: *Self) void {
    self.cursor_visible = false;
}

// ---------------------------------------------------------------------------
// Drawing API
// ---------------------------------------------------------------------------

fn cellAt(self: *Self, row: u16, col: u16) ?*Cell {
    if (row == 0 or col == 0) return null;
    const r = row - 1; // convert to 0-based
    const c = col - 1;
    if (r >= self.height or c >= self.width) return null;
    return &self.back[@as(usize, r) * max_cols + c];
}

/// Write a single character at (row, col) with style. 1-based coordinates.
pub fn putChar(self: *Self, row: u16, col: u16, ch: u8, s: Style) void {
    const cell = self.cellAt(row, col) orelse return;
    cell.setChar(ch);
    cell.fg = s.fgByte();
    cell.bg = s.bgByte();
    cell.attrs = s.attrs();
}

/// Write a UTF-8 string at (row, col). Returns columns consumed.
/// Handles multi-byte characters and wide chars (CJK).
pub fn write(self: *Self, row: u16, col: u16, text: []const u8, s: Style) u16 {
    if (row == 0 or col == 0) return 0;
    const r = row - 1;
    const c_start = col - 1;
    if (r >= self.height or c_start >= self.width) return 0;

    const fg = s.fgByte();
    const bg = s.bgByte();
    const a = s.attrs();
    var c = c_start;
    var i: usize = 0;

    while (i < text.len and c < self.width) {
        const byte = text[i];
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            // Invalid UTF-8 — write as single byte
            const cell = &self.back[@as(usize, r) * max_cols + c];
            cell.setChar(byte);
            cell.fg = fg;
            cell.bg = bg;
            cell.attrs = a;
            c += 1;
            i += 1;
            continue;
        };

        if (i + seq_len > text.len) break;

        const cp = std.unicode.utf8Decode(text[i..][0..seq_len]) catch {
            i += 1;
            continue;
        };

        const w = unicode.codepointWidth(cp);
        if (w == 0) { i += seq_len; continue; } // combining mark — skip
        if (c + w > self.width) break; // wide char doesn't fit

        const cell = &self.back[@as(usize, r) * max_cols + c];
        cell.setUtf8(text[i..][0..seq_len]);
        cell.fg = fg;
        cell.bg = bg;
        cell.attrs = a;

        // For wide chars, fill the next cell with a blank marker
        if (w == 2 and c + 1 < self.width) {
            const next = &self.back[@as(usize, r) * max_cols + c + 1];
            next.setChar(0);
            next.char_len = 0; // marker: continuation of wide char
            next.fg = fg;
            next.bg = bg;
            next.attrs = a;
        }

        c += w;
        i += seq_len;
    }

    return c - c_start;
}

/// Fill a rect with spaces using the given style.
pub fn fill(self: *Self, rect: Rect, s: Style) void {
    if (rect.w == 0 or rect.h == 0) return;
    const fg = s.fgByte();
    const bg = s.bgByte();
    const a = s.attrs();

    var row: u16 = 0;
    while (row < rect.h) : (row += 1) {
        const r = rect.y + row - 1;
        if (r >= self.height) break;
        var col: u16 = 0;
        while (col < rect.w) : (col += 1) {
            const c = rect.x + col - 1;
            if (c >= self.width) break;
            const cell = &self.back[@as(usize, r) * max_cols + c];
            cell.setChar(' ');
            cell.fg = fg;
            cell.bg = bg;
            cell.attrs = a;
        }
    }
}

/// Draw a horizontal line of box-drawing characters.
pub fn hline(self: *Self, row: u16, col: u16, width: u16, s: Style) void {
    const ch = style.box.horizontal;
    var c: u16 = 0;
    while (c < width) : (c += 1) {
        _ = self.write(row, col + c, ch, s);
    }
}

/// Pad (fill with spaces) from col for width columns.
pub fn pad(self: *Self, row: u16, col: u16, width: u16, s: Style) void {
    if (row == 0 or col == 0) return;
    const r = row - 1;
    if (r >= self.height) return;
    const fg = s.fgByte();
    const bg = s.bgByte();
    const a = s.attrs();

    var i: u16 = 0;
    while (i < width) : (i += 1) {
        const c = col - 1 + i;
        if (c >= self.width) break;
        const cell = &self.back[@as(usize, r) * max_cols + c];
        cell.setChar(' ');
        cell.fg = fg;
        cell.bg = bg;
        cell.attrs = a;
    }
}

// ---------------------------------------------------------------------------
// Flush — diff back vs front, emit minimal ANSI
// ---------------------------------------------------------------------------

pub fn flush(self: *Self, writer: std.fs.File) void {
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;

    // Hide cursor during update
    pos += style.hideCursor(buf[pos..]);

    // Track current terminal style state to minimize SGR output
    var cur_fg: u8 = 0;
    var cur_bg: u8 = 0;
    var cur_attrs: Cell.Attrs = .{};
    var cur_row: u16 = 0;
    var cur_col: u16 = 0;
    var moved = false;

    // First frame: also send home + clear implicit state
    if (!self.initialized) {
        pos += style.home(buf[pos..]);
        cur_row = 1;
        cur_col = 1;
        moved = true;
    }

    var r: u16 = 0;
    while (r < self.height) : (r += 1) {
        var c: u16 = 0;
        while (c < self.width) : (c += 1) {
            const idx = @as(usize, r) * max_cols + c;
            const back = &self.back[idx];
            const front = &self.front[idx];

            // Skip unchanged cells
            if (self.initialized and back.eql(front.*)) {
                c += 1;
                // Check for run of unchanged cells to skip — actually just continue
                c -= 1; // undo, the while loop increments
                continue;
            }

            // Skip wide-char continuation markers
            if (back.char_len == 0) continue;

            // Flush buffer if getting full
            if (pos > buf.len - 64) {
                writer.writeAll(buf[0..pos]) catch {};
                pos = 0;
            }

            // Move cursor if needed
            const target_row = r + 1; // 1-based
            const target_col = c + 1;
            if (!moved or cur_row != target_row or cur_col != target_col) {
                pos += style.moveTo(buf[pos..], target_row, target_col);
                cur_row = target_row;
                cur_col = target_col;
                moved = true;
            }

            // Update style if changed
            pos += self.emitStyle(buf[pos..], back.*, &cur_fg, &cur_bg, &cur_attrs);

            // Write character
            const ch = back.charSlice();
            @memcpy(buf[pos .. pos + ch.len], ch);
            pos += ch.len;
            cur_col += 1;

            // If wide char, skip next cell (cursor advances by 2)
            if (unicode.codepointWidth(std.unicode.utf8Decode(ch[0..@intCast(back.char_len)]) catch ' ') == 2) {
                cur_col += 1;
                c += 1; // skip continuation cell
            }
        }
    }

    // Reset style at end of frame
    if (cur_fg != 0 or cur_bg != 0 or @as(u8, @bitCast(cur_attrs)) != 0) {
        pos += style.reset(buf[pos..]);
    }

    // Cursor
    if (self.cursor_visible) {
        pos += style.showCursor(buf[pos..]);
        pos += style.moveTo(buf[pos..], self.cursor_row, self.cursor_col);
    }

    // Write remaining
    if (pos > 0) writer.writeAll(buf[0..pos]) catch {};

    // Copy back → front
    @memcpy(&self.front, &self.back);
    self.initialized = true;
}

fn emitStyle(self: *const Self, buf: []u8, cell: Cell, cur_fg: *u8, cur_bg: *u8, cur_attrs: *Cell.Attrs) usize {
    _ = self;
    var pos: usize = 0;
    const attrs_byte = @as(u8, @bitCast(cell.attrs));
    const cur_attrs_byte = @as(u8, @bitCast(cur_attrs.*));

    // If attrs changed, we need to reset and re-apply (SGR is not easily composable)
    if (attrs_byte != cur_attrs_byte or cell.fg != cur_fg.* or cell.bg != cur_bg.*) {
        pos += style.reset(buf[pos..]);

        // Apply attributes
        if (cell.attrs.bold) pos += style.bold(buf[pos..]);
        if (cell.attrs.dim) pos += style.dim(buf[pos..]);
        if (cell.attrs.italic) pos += style.italic(buf[pos..]);
        if (cell.attrs.inverse) pos += style.inverse(buf[pos..]);

        // Apply colors
        if (cell.fg != 0) {
            pos += style.fg(buf[pos..], @enumFromInt(cell.fg));
        }
        if (cell.bg != 0) {
            pos += style.bg(buf[pos..], @enumFromInt(cell.bg));
        }

        cur_fg.* = cell.fg;
        cur_bg.* = cell.bg;
        cur_attrs.* = cell.attrs;
    }

    return pos;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "init and beginFrame" {
    var scr = Self.init(80, 24);
    try std.testing.expectEqual(@as(u16, 80), scr.width);
    try std.testing.expectEqual(@as(u16, 24), scr.height);
    scr.beginFrame();
}

test "write ASCII" {
    var scr = Self.init(80, 24);
    const n = scr.write(1, 1, "hello", .{});
    try std.testing.expectEqual(@as(u16, 5), n);
    // Check cells
    const cell = scr.back[0]; // row 0, col 0
    try std.testing.expectEqual(@as(u8, 'h'), cell.char[0]);
    try std.testing.expectEqual(@as(u3, 1), cell.char_len);
}

test "write with style" {
    var scr = Self.init(80, 24);
    _ = scr.write(1, 1, "hi", .{ .fg = .red, .bold = true });
    const cell = scr.back[0];
    try std.testing.expectEqual(@as(u8, @intFromEnum(style.Color.red)), cell.fg);
    try std.testing.expect(cell.attrs.bold);
}

test "write CJK" {
    var scr = Self.init(80, 24);
    const n = scr.write(1, 1, "你好", .{});
    try std.testing.expectEqual(@as(u16, 4), n); // 2 chars * 2 cols each
}

test "fill rect" {
    var scr = Self.init(80, 24);
    scr.fill(Rect{ .x = 1, .y = 1, .w = 5, .h = 3 }, .{ .bg = .blue });
    const cell = scr.back[0];
    try std.testing.expectEqual(@as(u8, ' '), cell.char[0]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(style.Color.blue)), cell.bg);
}

test "putChar" {
    var scr = Self.init(80, 24);
    scr.putChar(1, 1, 'X', .{ .fg = .green });
    try std.testing.expectEqual(@as(u8, 'X'), scr.back[0].char[0]);
}

test "write clips at boundary" {
    var scr = Self.init(10, 1);
    const n = scr.write(1, 8, "hello", .{});
    try std.testing.expectEqual(@as(u16, 3), n); // only 3 cols left (8,9,10)
}

test "setCursor" {
    var scr = Self.init(80, 24);
    scr.setCursor(5, 10);
    try std.testing.expect(scr.cursor_visible);
    try std.testing.expectEqual(@as(u16, 5), scr.cursor_row);
    try std.testing.expectEqual(@as(u16, 10), scr.cursor_col);
}

test "diff skips unchanged cells" {
    var scr = Self.init(80, 24);
    _ = scr.write(1, 1, "hello", .{});
    // Simulate flush by copying back→front
    @memcpy(&scr.front, &scr.back);
    scr.initialized = true;

    // Begin new frame, write same content
    scr.beginFrame();
    _ = scr.write(1, 1, "hello", .{});

    // Back and front should match — flush emits nothing for content
    for (0..5) |i| {
        try std.testing.expect(scr.back[i].eql(scr.front[i]));
    }
}

test "resize invalidates" {
    var scr = Self.init(80, 24);
    scr.initialized = true;
    scr.resize(100, 30);
    try std.testing.expect(!scr.initialized);
    try std.testing.expectEqual(@as(u16, 100), scr.width);
}
