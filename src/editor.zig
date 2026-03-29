// editor.zig — Minimal line editor.
//
// Manages a single-line input buffer with cursor position. Supports
// character insertion, deletion, and cursor movement. The editor
// does not handle I/O directly — it operates on its internal buffer
// and tells the caller what changed so the display can be updated.

const std = @import("std");

/// Maximum line length supported by the editor.
pub const MAX_LINE: usize = 4096;

pub const VimMode = enum { insert, normal };

/// Line editor state.
pub const Editor = struct {
    /// Input buffer.
    buf: [MAX_LINE]u8 = undefined,
    /// Current length of content in the buffer.
    len: usize = 0,
    /// Cursor position (index into buf, 0..len).
    cursor: usize = 0,
    /// Vim editing mode.
    mode: VimMode = .insert,
    /// Whether vim mode is enabled globally.
    vim_enabled: bool = false,

    /// Reset the editor to an empty state.
    pub fn clear(self: *Editor) void {
        self.len = 0;
        self.cursor = 0;
    }

    /// Get the current line content as a slice.
    pub fn content(self: *const Editor) []const u8 {
        return self.buf[0..self.len];
    }

    /// Returns true if the buffer is empty.
    pub fn isEmpty(self: *const Editor) bool {
        return self.len == 0;
    }

    /// Replace buf[start..end] with `replacement`, adjusting len and cursor.
    pub fn replaceRange(self: *Editor, start: usize, end: usize, replacement: []const u8) void {
        if (start > self.len or end > self.len or start > end) return;
        const old_len = end - start;
        const new_len = replacement.len;
        if (self.len - old_len + new_len > MAX_LINE) return;

        // Shift tail
        const tail_len = self.len - end;
        if (new_len > old_len) {
            // Growing — shift right
            std.mem.copyBackwards(u8, self.buf[start + new_len ..][0..tail_len], self.buf[end..][0..tail_len]);
        } else if (new_len < old_len) {
            // Shrinking — shift left
            std.mem.copyForwards(u8, self.buf[start + new_len ..][0..tail_len], self.buf[end..][0..tail_len]);
        }
        @memcpy(self.buf[start..][0..new_len], replacement);
        self.len = self.len - old_len + new_len;
        self.cursor = start + new_len;
    }

    /// Replace buffer contents entirely (for history navigation).
    pub fn setContent(self: *Editor, text: []const u8) void {
        const n = @min(text.len, MAX_LINE);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
        self.cursor = n;
    }

    // ------------------------------------------------------------------
    // Editing operations
    // ------------------------------------------------------------------

    /// Insert a character at the cursor position.
    pub fn insert(self: *Editor, ch: u8) void {
        if (self.len >= MAX_LINE) return;

        // Shift everything after cursor right by one
        if (self.cursor < self.len) {
            std.mem.copyBackwards(
                u8,
                self.buf[self.cursor + 1 .. self.len + 1],
                self.buf[self.cursor .. self.len],
            );
        }
        self.buf[self.cursor] = ch;
        self.cursor += 1;
        self.len += 1;
    }

    /// Delete the character before the cursor (backspace).
    pub fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;

        // Shift everything after cursor left by one
        if (self.cursor < self.len) {
            std.mem.copyForwards(
                u8,
                self.buf[self.cursor - 1 .. self.len - 1],
                self.buf[self.cursor .. self.len],
            );
        }
        self.cursor -= 1;
        self.len -= 1;
    }

    /// Delete the character at the cursor (delete key).
    pub fn delete(self: *Editor) void {
        if (self.cursor >= self.len) return;

        if (self.cursor + 1 < self.len) {
            std.mem.copyForwards(
                u8,
                self.buf[self.cursor .. self.len - 1],
                self.buf[self.cursor + 1 .. self.len],
            );
        }
        self.len -= 1;
    }

    // ------------------------------------------------------------------
    // Cursor movement
    // ------------------------------------------------------------------

    /// Move cursor one position left.
    pub fn moveLeft(self: *Editor) void {
        if (self.cursor > 0) self.cursor -= 1;
    }

    /// Move cursor one position right.
    pub fn moveRight(self: *Editor) void {
        if (self.cursor < self.len) self.cursor += 1;
    }

    /// Move cursor to the beginning of the line.
    pub fn moveHome(self: *Editor) void {
        self.cursor = 0;
    }

    /// Move cursor to the end of the line.
    pub fn moveEnd(self: *Editor) void {
        self.cursor = self.len;
    }

    // ------------------------------------------------------------------
    // Word motions (vim-style)
    // ------------------------------------------------------------------

    /// Move cursor to the start of the next word.
    pub fn moveWordForward(self: *Editor) void {
        if (self.cursor >= self.len) return;
        var i = self.cursor;
        // Skip current word chars
        while (i < self.len and !isWordSep(self.buf[i])) : (i += 1) {}
        // Skip whitespace
        while (i < self.len and isWordSep(self.buf[i])) : (i += 1) {}
        self.cursor = i;
    }

    /// Move cursor to the start of the previous word.
    pub fn moveWordBackward(self: *Editor) void {
        if (self.cursor == 0) return;
        var i = self.cursor;
        // Skip whitespace backward
        while (i > 0 and isWordSep(self.buf[i - 1])) : (i -= 1) {}
        // Skip word chars backward
        while (i > 0 and !isWordSep(self.buf[i - 1])) : (i -= 1) {}
        self.cursor = i;
    }

    // ------------------------------------------------------------------
    // Vim editing operations
    // ------------------------------------------------------------------

    /// Delete character under cursor (x in normal mode).
    pub fn deleteAtCursor(self: *Editor) void {
        self.delete();
    }

    /// Delete from cursor to end of line (D in normal mode).
    pub fn deleteToEnd(self: *Editor) void {
        self.len = self.cursor;
    }

    /// Delete from cursor to start of next word (dw).
    pub fn deleteWord(self: *Editor) void {
        if (self.cursor >= self.len) return;
        var end = self.cursor;
        while (end < self.len and !isWordSep(self.buf[end])) : (end += 1) {}
        while (end < self.len and isWordSep(self.buf[end])) : (end += 1) {}
        self.replaceRange(self.cursor, end, "");
    }

    /// Delete from cursor backward to start of word (db).
    pub fn deleteWordBackward(self: *Editor) void {
        if (self.cursor == 0) return;
        var start = self.cursor;
        while (start > 0 and isWordSep(self.buf[start - 1])) : (start -= 1) {}
        while (start > 0 and !isWordSep(self.buf[start - 1])) : (start -= 1) {}
        self.replaceRange(start, self.cursor, "");
    }

    /// Clamp cursor for normal mode (must stay on a character, not past end).
    pub fn clampNormal(self: *Editor) void {
        if (self.len > 0 and self.cursor >= self.len) {
            self.cursor = self.len - 1;
        }
    }

    fn isWordSep(c: u8) bool {
        return c == ' ' or c == '\t' or c == '/' or c == '.' or c == '-' or c == '_';
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "insert characters" {
    var ed = Editor{};
    ed.insert('a');
    ed.insert('b');
    ed.insert('c');

    try std.testing.expectEqualStrings("abc", ed.content());
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);
}

test "backspace" {
    var ed = Editor{};
    ed.insert('a');
    ed.insert('b');
    ed.insert('c');
    ed.backspace();

    try std.testing.expectEqualStrings("ab", ed.content());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "backspace at beginning does nothing" {
    var ed = Editor{};
    ed.backspace();
    try std.testing.expectEqual(@as(usize, 0), ed.len);
}

test "insert in middle" {
    var ed = Editor{};
    ed.insert('a');
    ed.insert('c');
    ed.moveLeft();
    ed.insert('b');

    try std.testing.expectEqualStrings("abc", ed.content());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "delete at cursor" {
    var ed = Editor{};
    ed.insert('a');
    ed.insert('b');
    ed.insert('c');
    ed.moveHome();
    ed.delete();

    try std.testing.expectEqualStrings("bc", ed.content());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "delete at end does nothing" {
    var ed = Editor{};
    ed.insert('a');
    ed.delete();
    try std.testing.expectEqualStrings("a", ed.content());
}

test "cursor movement" {
    var ed = Editor{};
    ed.insert('a');
    ed.insert('b');
    ed.insert('c');

    ed.moveLeft();
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);

    ed.moveLeft();
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);

    ed.moveRight();
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);

    ed.moveHome();
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);

    ed.moveEnd();
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);
}

test "clear resets state" {
    var ed = Editor{};
    ed.insert('a');
    ed.insert('b');
    ed.clear();

    try std.testing.expect(ed.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "backspace in middle" {
    var ed = Editor{};
    ed.insert('a');
    ed.insert('b');
    ed.insert('c');
    ed.moveLeft(); // cursor at 2 (before 'c')
    ed.backspace(); // delete 'b'

    try std.testing.expectEqualStrings("ac", ed.content());
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
}
