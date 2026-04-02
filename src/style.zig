// style.zig — Terminal styling utilities.
//
// Provides composable ANSI escape sequence builders using standard
// terminal colors only (base 16 + attributes). Never uses 256-color
// or RGB — respects the user's terminal theme.
//
// Usage:
//   const s = style;
//   pos += s.bold(buf[pos..]);
//   pos += s.fg(.red, buf[pos..]);
//   pos += s.reset(buf[pos..]);
//
// Or use the write helpers:
//   pos += s.styled(buf[pos..], .bold, .red, "error");

const std = @import("std");

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------

pub const Color = enum(u8) {
    default = 39,
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    // Bright variants
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,
};

// ---------------------------------------------------------------------------
// Attribute sequences — write into buffer, return bytes written
// ---------------------------------------------------------------------------

pub fn reset(dest: []u8) usize { return cp(dest, "\x1b[0m"); }
pub fn bold(dest: []u8) usize { return cp(dest, "\x1b[1m"); }
pub fn dim(dest: []u8) usize { return cp(dest, "\x1b[2m"); }
pub fn italic(dest: []u8) usize { return cp(dest, "\x1b[3m"); }
pub fn underline(dest: []u8) usize { return cp(dest, "\x1b[4m"); }
pub fn blink(dest: []u8) usize { return cp(dest, "\x1b[5m"); }
pub fn inverse(dest: []u8) usize { return cp(dest, "\x1b[7m"); }
pub fn strikethrough(dest: []u8) usize { return cp(dest, "\x1b[9m"); }

// Reset specific attributes
pub fn unbold(dest: []u8) usize { return cp(dest, "\x1b[22m"); }
pub fn undim(dest: []u8) usize { return cp(dest, "\x1b[22m"); }
pub fn noitalic(dest: []u8) usize { return cp(dest, "\x1b[23m"); }
pub fn nounderline(dest: []u8) usize { return cp(dest, "\x1b[24m"); }
pub fn noinverse(dest: []u8) usize { return cp(dest, "\x1b[27m"); }

// ---------------------------------------------------------------------------
// Foreground / background colors
// ---------------------------------------------------------------------------

pub fn fg(dest: []u8, color: Color) usize {
    return writeCode(dest, @intFromEnum(color));
}

pub fn bg(dest: []u8, color: Color) usize {
    return writeCode(dest, @intFromEnum(color) + 10);
}

pub fn bgDefault(dest: []u8) usize { return cp(dest, "\x1b[49m"); }

// ---------------------------------------------------------------------------
// Compound styles — multiple attributes in one sequence
// ---------------------------------------------------------------------------

pub fn boldFg(dest: []u8, color: Color) usize {
    return writeCode2(dest, 1, @intFromEnum(color));
}

pub fn dimFg(dest: []u8, color: Color) usize {
    return writeCode2(dest, 2, @intFromEnum(color));
}

pub fn boldBg(dest: []u8, color: Color) usize {
    return writeCode2(dest, 1, @intFromEnum(color) + 10);
}

pub fn fgBg(dest: []u8, fgc: Color, bgc: Color) usize {
    return writeCode2(dest, @intFromEnum(fgc), @intFromEnum(bgc) + 10);
}

pub fn inverseFg(dest: []u8, color: Color) usize {
    return writeCode2(dest, 7, @intFromEnum(color));
}

// ---------------------------------------------------------------------------
// Text helpers — write styled text + reset
// ---------------------------------------------------------------------------

/// Write text with a single attribute, then reset.
pub fn styledText(dest: []u8, attr: []const u8, text: []const u8) usize {
    var pos: usize = 0;
    pos += cp(dest[pos..], attr);
    pos += cp(dest[pos..], text);
    pos += reset(dest[pos..]);
    return pos;
}

/// Write bold text in a color, then reset.
pub fn boldColored(dest: []u8, color: Color, text: []const u8) usize {
    var pos: usize = 0;
    pos += boldFg(dest[pos..], color);
    pos += cp(dest[pos..], text);
    pos += reset(dest[pos..]);
    return pos;
}

/// Write colored text, then reset.
pub fn colored(dest: []u8, color: Color, text: []const u8) usize {
    var pos: usize = 0;
    pos += fg(dest[pos..], color);
    pos += cp(dest[pos..], text);
    pos += reset(dest[pos..]);
    return pos;
}

/// Write dim text, then reset.
pub fn dimText(dest: []u8, text: []const u8) usize {
    var pos: usize = 0;
    pos += dim(dest[pos..]);
    pos += cp(dest[pos..], text);
    pos += reset(dest[pos..]);
    return pos;
}

/// Write bold text, then reset.
pub fn boldText(dest: []u8, text: []const u8) usize {
    var pos: usize = 0;
    pos += bold(dest[pos..]);
    pos += cp(dest[pos..], text);
    pos += reset(dest[pos..]);
    return pos;
}

// ---------------------------------------------------------------------------
// Cursor / screen control
// ---------------------------------------------------------------------------

pub fn clearLine(dest: []u8) usize { return cp(dest, "\x1b[K"); }
pub fn clearScreen(dest: []u8) usize { return cp(dest, "\x1b[2J"); }
pub fn clearBelow(dest: []u8) usize { return cp(dest, "\x1b[J"); }
pub fn home(dest: []u8) usize { return cp(dest, "\x1b[H"); }
pub fn saveCursor(dest: []u8) usize { return cp(dest, "\x1b[s"); }
pub fn restoreCursor(dest: []u8) usize { return cp(dest, "\x1b[u"); }
pub fn hideCursor(dest: []u8) usize { return cp(dest, "\x1b[?25l"); }
pub fn showCursor(dest: []u8) usize { return cp(dest, "\x1b[?25h"); }
pub fn altScreenOn(dest: []u8) usize { return cp(dest, "\x1b[?1049h"); }
pub fn altScreenOff(dest: []u8) usize { return cp(dest, "\x1b[?1049l"); }

pub fn moveTo(dest: []u8, row: usize, col: usize) usize {
    return (std.fmt.bufPrint(dest, "\x1b[{d};{d}H", .{ row, col }) catch return 0).len;
}

pub fn moveUp(dest: []u8, n: usize) usize {
    return (std.fmt.bufPrint(dest, "\x1b[{d}A", .{n}) catch return 0).len;
}

pub fn moveDown(dest: []u8, n: usize) usize {
    return (std.fmt.bufPrint(dest, "\x1b[{d}B", .{n}) catch return 0).len;
}

pub fn moveRight(dest: []u8, n: usize) usize {
    return (std.fmt.bufPrint(dest, "\x1b[{d}C", .{n}) catch return 0).len;
}

pub fn cr(dest: []u8) usize { return cp(dest, "\r"); }
pub fn crlf(dest: []u8) usize { return cp(dest, "\r\n"); }

// ---------------------------------------------------------------------------
// Box drawing characters (UTF-8)
// ---------------------------------------------------------------------------

pub const box = struct {
    pub const horizontal: []const u8 = "\xe2\x94\x80"; // ─
    pub const vertical: []const u8 = "\xe2\x94\x82"; // │
    pub const top_left: []const u8 = "\xe2\x94\x8c"; // ┌
    pub const top_right: []const u8 = "\xe2\x94\x90"; // ┐
    pub const bottom_left: []const u8 = "\xe2\x94\x94"; // └
    pub const bottom_right: []const u8 = "\xe2\x94\x98"; // ┘
    pub const t_left: []const u8 = "\xe2\x94\x9c"; // ├
    pub const t_right: []const u8 = "\xe2\x94\xa4"; // ┤
    pub const scrollbar_thumb: []const u8 = "\xe2\x96\x90"; // ▐
    pub const scrollbar_track: []const u8 = "\xe2\x96\x91"; // ░
    pub const bullet: []const u8 = "\xe2\x97\x8f"; // ●
    pub const cross: []const u8 = "\xe2\x9c\x97"; // ✗
    pub const ellipsis: []const u8 = "\xe2\x80\xa6"; // …
};

/// Write N horizontal box-drawing chars.
pub fn hline(dest: []u8, n: usize) usize {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < n and pos + 3 <= dest.len) : (i += 1) {
        dest[pos] = 0xe2;
        dest[pos + 1] = 0x94;
        dest[pos + 2] = 0x80;
        pos += 3;
    }
    return pos;
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

fn writeCode(dest: []u8, code: u8) usize {
    return (std.fmt.bufPrint(dest, "\x1b[{d}m", .{code}) catch return 0).len;
}

fn writeCode2(dest: []u8, a: u8, b: u8) usize {
    return (std.fmt.bufPrint(dest, "\x1b[{d};{d}m", .{ a, b }) catch return 0).len;
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "fg produces correct escape" {
    var buf: [32]u8 = undefined;
    const n = fg(&buf, .red);
    try std.testing.expectEqualStrings("\x1b[31m", buf[0..n]);
}

test "boldFg compound" {
    var buf: [32]u8 = undefined;
    const n = boldFg(&buf, .cyan);
    try std.testing.expectEqualStrings("\x1b[1;36m", buf[0..n]);
}

test "colored writes and resets" {
    var buf: [64]u8 = undefined;
    const n = colored(&buf, .green, "ok");
    try std.testing.expectEqualStrings("\x1b[32mok\x1b[0m", buf[0..n]);
}

test "hline" {
    var buf: [64]u8 = undefined;
    const n = hline(&buf, 3);
    try std.testing.expectEqual(@as(usize, 9), n); // 3 chars × 3 bytes
}

test "moveTo" {
    var buf: [32]u8 = undefined;
    const n = moveTo(&buf, 5, 10);
    try std.testing.expectEqualStrings("\x1b[5;10H", buf[0..n]);
}
