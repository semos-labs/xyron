// Input.zig — Single-line text input with cursor and editing keys.
//
// Supports Emacs-style editing: ^A/^E (home/end), ^W (kill word),
// ^U/^K (kill to start/end), ^Y (yank), Alt+B/F (word movement),
// and standard backspace/delete/arrow keys.

const std = @import("std");
const core = @import("core.zig");
const style = @import("../style.zig");
const keys = @import("../keys.zig");

const Screen = @import("Screen.zig");
const Rect = core.Rect;
const Element = core.Element;
const Action = core.Action;
const Key = keys.Key;

pub const max_len = 1024;

// ---------------------------------------------------------------------------
// Input component
// ---------------------------------------------------------------------------

buf: [max_len]u8 = undefined,
len: usize = 0,
cursor: usize = 0, // byte offset
focused: bool = false,
prompt: []const u8 = "",
prompt_color: ?style.Color = null,
placeholder: []const u8 = "",

// Kill buffer for ^K/^U/^W/^Y
kill_buf: [max_len]u8 = undefined,
kill_len: usize = 0,

const Self = @This();

/// Get the current input value.
pub fn value(self: *const Self) []const u8 {
    return self.buf[0..self.len];
}

/// Set the input value and move cursor to end.
pub fn setValue(self: *Self, text: []const u8) void {
    const n = @min(text.len, max_len);
    @memcpy(self.buf[0..n], text[0..n]);
    self.len = n;
    self.cursor = n;
}

/// Clear the input.
pub fn clear(self: *Self) void {
    self.len = 0;
    self.cursor = 0;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

pub fn render(self: *const Self, buf: []u8, rect: Rect) usize {
    if (rect.w == 0 or rect.h == 0) return 0;

    var pos: usize = 0;
    pos += style.moveTo(buf[pos..], rect.y, rect.x);

    var vis: u16 = 0;
    const max_w = rect.w;

    // Prompt
    if (self.prompt.len > 0) {
        if (self.prompt_color) |c| {
            if (self.focused) {
                pos += style.boldFg(buf[pos..], c);
            } else {
                pos += style.dimFg(buf[pos..], c);
            }
        } else {
            if (self.focused) {
                pos += style.bold(buf[pos..]);
            } else {
                pos += style.dim(buf[pos..]);
            }
        }
        const pw = @min(self.prompt.len, max_w);
        pos += core.clipText(buf[pos..], self.prompt, @intCast(pw));
        vis += @intCast(pw);
        pos += style.reset(buf[pos..]);
    }

    // Input text or placeholder
    const text = self.value();
    if (text.len == 0 and self.placeholder.len > 0 and !self.focused) {
        pos += style.dim(buf[pos..]);
        const ph_w: u16 = @intCast(@min(self.placeholder.len, max_w -| vis));
        pos += core.clipText(buf[pos..], self.placeholder, ph_w);
        vis += ph_w;
        pos += style.reset(buf[pos..]);
    } else {
        // Calculate visible window of text (scroll if cursor is beyond view)
        const text_area = max_w -| vis;
        const scroll = self.scrollOffset(text_area);
        const visible_text = text[scroll..@min(text.len, scroll + text_area)];

        if (self.focused) pos += style.bold(buf[pos..]);
        const tw: u16 = @intCast(@min(visible_text.len, text_area));
        pos += core.clipText(buf[pos..], visible_text, tw);
        vis += tw;
        if (self.focused) pos += style.reset(buf[pos..]);
    }

    // Pad remaining
    pos += core.pad(buf[pos..], max_w -| vis);

    // Position cursor (for terminal cursor rendering)
    if (self.focused) {
        const text_area = max_w -| @as(u16, @intCast(@min(self.prompt.len, max_w)));
        const scroll = self.scrollOffset(text_area);
        const cursor_col = rect.x + @as(u16, @intCast(@min(self.prompt.len, max_w))) +
            @as(u16, @intCast(self.cursor -| scroll));
        pos += style.moveTo(buf[pos..], rect.y, cursor_col);
    }

    return pos;
}

/// Render into a Screen (double-buffered, flicker-free).
pub fn draw(self: *const Self, scr: *Screen, rect: Rect) void {
    if (rect.w == 0 or rect.h == 0) return;

    var col = rect.x;
    const max_w = rect.w;

    // Prompt
    if (self.prompt.len > 0) {
        var prompt_style = Screen.Style{};
        if (self.prompt_color) |c_color| {
            prompt_style.fg = c_color;
            if (self.focused) { prompt_style.bold = true; } else { prompt_style.dim = true; }
        } else {
            if (self.focused) { prompt_style.bold = true; } else { prompt_style.dim = true; }
        }
        const pw: u16 = @intCast(@min(self.prompt.len, max_w));
        col += scr.write(rect.y, col, self.prompt[0..pw], prompt_style);
    }

    const vis_start = col - rect.x;
    const text = self.value();

    if (text.len == 0 and self.placeholder.len > 0 and !self.focused) {
        const ph_w: u16 = @intCast(@min(self.placeholder.len, max_w -| vis_start));
        col += scr.write(rect.y, col, self.placeholder[0..ph_w], .{ .dim = true });
    } else {
        const text_area = max_w -| vis_start;
        const scroll_off = self.scrollOffset(text_area);
        const end = @min(text.len, scroll_off + text_area);
        const visible_text = text[scroll_off..end];

        const text_style: Screen.Style = if (self.focused) .{ .bold = true } else .{};
        col += scr.write(rect.y, col, visible_text, text_style);
    }

    // Pad remaining
    scr.pad(rect.y, col, rect.x + rect.w - col, .{});

    // Position cursor
    if (self.focused) {
        const text_area = max_w -| @as(u16, @intCast(@min(self.prompt.len, max_w)));
        const scroll_off = self.scrollOffset(text_area);
        const cursor_col = rect.x + @as(u16, @intCast(@min(self.prompt.len, max_w))) +
            @as(u16, @intCast(self.cursor -| scroll_off));
        scr.setCursor(rect.y, cursor_col);
    }
}

/// Calculate horizontal scroll offset so the cursor stays visible.
fn scrollOffset(self: *const Self, text_area: u16) usize {
    if (text_area == 0) return 0;
    if (self.cursor <= text_area) return 0;
    return self.cursor - text_area + 1;
}

pub fn element(self: *const Self) Element {
    return Element.from(self);
}

// ---------------------------------------------------------------------------
// Key handling
// ---------------------------------------------------------------------------

pub fn handleKey(self: *Self, key: Key) Action {
    switch (key) {
        .char => |ch| {
            self.insertByte(ch);
            return .changed;
        },
        .utf8 => |u| {
            self.insertBytes(u.bytes[0..u.len]);
            return .changed;
        },
        .backspace => {
            if (self.deleteBack()) return .changed;
            return .none;
        },
        .delete, .ctrl_d => {
            if (self.deleteForward()) return .changed;
            return .none;
        },
        .left, .ctrl_b => {
            self.moveLeft();
            return .none;
        },
        .right, .ctrl_f => {
            self.moveRight();
            return .none;
        },
        .home, .ctrl_a => {
            self.cursor = 0;
            return .none;
        },
        .end_key, .ctrl_e => {
            self.cursor = self.len;
            return .none;
        },
        .ctrl_w, .alt_backspace => {
            if (self.killWordBack()) return .changed;
            return .none;
        },
        .alt_d => {
            if (self.killWordForward()) return .changed;
            return .none;
        },
        .ctrl_u => {
            if (self.killToStart()) return .changed;
            return .none;
        },
        .ctrl_k => {
            if (self.killToEnd()) return .changed;
            return .none;
        },
        .ctrl_y => {
            if (self.yank()) return .changed;
            return .none;
        },
        .alt_b => {
            self.moveWordLeft();
            return .none;
        },
        .alt_f => {
            self.moveWordRight();
            return .none;
        },
        .ctrl_t => {
            if (self.transpose()) return .changed;
            return .none;
        },
        .enter => return .submit,
        .escape => return .cancel,
        .tab, .shift_tab => return .ignored,
        else => return .ignored,
    }
}

// ---------------------------------------------------------------------------
// Editing operations
// ---------------------------------------------------------------------------

fn insertByte(self: *Self, ch: u8) void {
    if (self.len >= max_len) return;
    // Shift right to make room
    if (self.cursor < self.len) {
        std.mem.copyBackwards(u8, self.buf[self.cursor + 1 .. self.len + 1], self.buf[self.cursor..self.len]);
    }
    self.buf[self.cursor] = ch;
    self.cursor += 1;
    self.len += 1;
}

fn insertBytes(self: *Self, bytes: []const u8) void {
    if (self.len + bytes.len > max_len) return;
    if (self.cursor < self.len) {
        std.mem.copyBackwards(
            u8,
            self.buf[self.cursor + bytes.len .. self.len + bytes.len],
            self.buf[self.cursor..self.len],
        );
    }
    @memcpy(self.buf[self.cursor .. self.cursor + bytes.len], bytes);
    self.cursor += bytes.len;
    self.len += bytes.len;
}

fn deleteBack(self: *Self) bool {
    if (self.cursor == 0) return false;
    const start = prevCharStart(self.buf[0..self.len], self.cursor);
    self.removeRange(start, self.cursor);
    self.cursor = start;
    return true;
}

fn deleteForward(self: *Self) bool {
    if (self.cursor >= self.len) return false;
    const end = nextCharEnd(self.buf[0..self.len], self.cursor);
    self.removeRange(self.cursor, end);
    return true;
}

fn moveLeft(self: *Self) void {
    if (self.cursor > 0)
        self.cursor = prevCharStart(self.buf[0..self.len], self.cursor);
}

fn moveRight(self: *Self) void {
    if (self.cursor < self.len)
        self.cursor = nextCharEnd(self.buf[0..self.len], self.cursor);
}

fn moveWordLeft(self: *Self) void {
    var i = self.cursor;
    // Skip spaces
    while (i > 0 and self.buf[i - 1] == ' ') i -= 1;
    // Skip word chars
    while (i > 0 and self.buf[i - 1] != ' ') i -= 1;
    self.cursor = i;
}

fn moveWordRight(self: *Self) void {
    var i = self.cursor;
    // Skip word chars
    while (i < self.len and self.buf[i] != ' ') i += 1;
    // Skip spaces
    while (i < self.len and self.buf[i] == ' ') i += 1;
    self.cursor = i;
}

fn killWordBack(self: *Self) bool {
    if (self.cursor == 0) return false;
    var start = self.cursor;
    while (start > 0 and self.buf[start - 1] == ' ') start -= 1;
    while (start > 0 and self.buf[start - 1] != ' ') start -= 1;
    self.saveKill(self.buf[start..self.cursor]);
    self.removeRange(start, self.cursor);
    self.cursor = start;
    return true;
}

fn killWordForward(self: *Self) bool {
    if (self.cursor >= self.len) return false;
    var end = self.cursor;
    while (end < self.len and self.buf[end] == ' ') end += 1;
    while (end < self.len and self.buf[end] != ' ') end += 1;
    self.saveKill(self.buf[self.cursor..end]);
    self.removeRange(self.cursor, end);
    return true;
}

fn killToStart(self: *Self) bool {
    if (self.cursor == 0) return false;
    self.saveKill(self.buf[0..self.cursor]);
    self.removeRange(0, self.cursor);
    self.cursor = 0;
    return true;
}

fn killToEnd(self: *Self) bool {
    if (self.cursor >= self.len) return false;
    self.saveKill(self.buf[self.cursor..self.len]);
    self.len = self.cursor;
    return true;
}

fn yank(self: *Self) bool {
    if (self.kill_len == 0) return false;
    self.insertBytes(self.kill_buf[0..self.kill_len]);
    return true;
}

fn transpose(self: *Self) bool {
    if (self.len < 2 or self.cursor == 0) return false;
    // If at end, swap last two chars
    const pos = if (self.cursor >= self.len) self.cursor - 1 else self.cursor;
    if (pos == 0) return false;
    const tmp = self.buf[pos - 1];
    self.buf[pos - 1] = self.buf[pos];
    self.buf[pos] = tmp;
    if (self.cursor < self.len) self.cursor += 1;
    return true;
}

fn saveKill(self: *Self, text: []const u8) void {
    const n = @min(text.len, max_len);
    @memcpy(self.kill_buf[0..n], text[0..n]);
    self.kill_len = n;
}

fn removeRange(self: *Self, start: usize, end: usize) void {
    if (end >= self.len) {
        self.len = start;
        return;
    }
    const tail = self.len - end;
    std.mem.copyForwards(u8, self.buf[start .. start + tail], self.buf[end .. end + tail]);
    self.len -= (end - start);
}

// ---------------------------------------------------------------------------
// UTF-8 helpers
// ---------------------------------------------------------------------------

fn prevCharStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    // Skip continuation bytes (10xxxxxx)
    while (i > 0 and text[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

fn nextCharEnd(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    var i = pos + 1;
    // Skip continuation bytes
    while (i < text.len and text[i] & 0xC0 == 0x80) i += 1;
    return i;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "insert and value" {
    var input: Self = .{};
    input.insertByte('h');
    input.insertByte('i');
    try std.testing.expectEqualStrings("hi", input.value());
    try std.testing.expectEqual(@as(usize, 2), input.cursor);
}

test "setValue" {
    var input: Self = .{};
    input.setValue("hello");
    try std.testing.expectEqualStrings("hello", input.value());
    try std.testing.expectEqual(@as(usize, 5), input.cursor);
}

test "backspace" {
    var input: Self = .{};
    input.setValue("abc");
    try std.testing.expect(input.deleteBack());
    try std.testing.expectEqualStrings("ab", input.value());
}

test "backspace at start" {
    var input: Self = .{};
    input.setValue("abc");
    input.cursor = 0;
    try std.testing.expect(!input.deleteBack());
}

test "delete forward" {
    var input: Self = .{};
    input.setValue("abc");
    input.cursor = 1;
    try std.testing.expect(input.deleteForward());
    try std.testing.expectEqualStrings("ac", input.value());
}

test "insert in middle" {
    var input: Self = .{};
    input.setValue("ac");
    input.cursor = 1;
    input.insertByte('b');
    try std.testing.expectEqualStrings("abc", input.value());
    try std.testing.expectEqual(@as(usize, 2), input.cursor);
}

test "kill word backward" {
    var input: Self = .{};
    input.setValue("hello world");
    try std.testing.expect(input.killWordBack());
    try std.testing.expectEqualStrings("hello ", input.value());
    try std.testing.expectEqualStrings("world", input.kill_buf[0..input.kill_len]);
}

test "kill to start" {
    var input: Self = .{};
    input.setValue("hello");
    input.cursor = 3;
    try std.testing.expect(input.killToStart());
    try std.testing.expectEqualStrings("lo", input.value());
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
}

test "kill to end" {
    var input: Self = .{};
    input.setValue("hello");
    input.cursor = 2;
    try std.testing.expect(input.killToEnd());
    try std.testing.expectEqualStrings("he", input.value());
}

test "yank" {
    var input: Self = .{};
    input.setValue("hello world");
    _ = input.killWordBack();
    input.cursor = 0;
    try std.testing.expect(input.yank());
    try std.testing.expectEqualStrings("worldhello ", input.value());
}

test "word movement" {
    var input: Self = .{};
    input.setValue("one two three");
    input.cursor = 0;
    input.moveWordRight();
    try std.testing.expectEqual(@as(usize, 4), input.cursor);
    input.moveWordRight();
    try std.testing.expectEqual(@as(usize, 8), input.cursor);
    input.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 4), input.cursor);
}

test "transpose" {
    var input: Self = .{};
    input.setValue("ab");
    try std.testing.expect(input.transpose());
    try std.testing.expectEqualStrings("ba", input.value());
}

test "clear" {
    var input: Self = .{};
    input.setValue("hello");
    input.clear();
    try std.testing.expectEqualStrings("", input.value());
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
}

test "handleKey char" {
    var input: Self = .{};
    const action = input.handleKey(.{ .char = 'x' });
    try std.testing.expectEqual(Action.changed, action);
    try std.testing.expectEqualStrings("x", input.value());
}

test "handleKey enter" {
    var input: Self = .{};
    try std.testing.expectEqual(Action.submit, input.handleKey(.enter));
}

test "handleKey escape" {
    var input: Self = .{};
    try std.testing.expectEqual(Action.cancel, input.handleKey(.escape));
}

test "render produces output" {
    var input: Self = .{ .focused = true, .prompt = "> " };
    input.setValue("test");
    var buf: [512]u8 = undefined;
    const n = input.render(&buf, Rect{ .x = 1, .y = 1, .w = 20, .h = 1 });
    try std.testing.expect(n > 0);
    const output = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, output, "> ") != null);
}

test "render zero rect" {
    var input: Self = .{};
    var buf: [256]u8 = undefined;
    const n = input.render(&buf, Rect{ .x = 1, .y = 1, .w = 0, .h = 0 });
    try std.testing.expectEqual(@as(usize, 0), n);
}
