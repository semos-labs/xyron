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
    /// Kill buffer for Ctrl+K/U/W/Y (yank/paste).
    kill_buf: [MAX_LINE]u8 = undefined,
    kill_len: usize = 0,

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

    /// Insert a single ASCII character at the cursor position.
    pub fn insert(self: *Editor, ch: u8) void {
        self.insertBytes(&.{ch});
    }

    /// Insert a multi-byte UTF-8 sequence at the cursor position.
    pub fn insertUtf8(self: *Editor, bytes: []const u8) void {
        self.insertBytes(bytes);
    }

    fn insertBytes(self: *Editor, bytes: []const u8) void {
        const n = bytes.len;
        if (self.len + n > MAX_LINE) return;

        // Shift everything after cursor right by n
        if (self.cursor < self.len) {
            std.mem.copyBackwards(
                u8,
                self.buf[self.cursor + n .. self.len + n],
                self.buf[self.cursor .. self.len],
            );
        }
        @memcpy(self.buf[self.cursor..][0..n], bytes);
        self.cursor += n;
        self.len += n;
    }

    /// Delete the character (codepoint) before the cursor (backspace).
    pub fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;
        const char_start = prevCharStart(self.buf[0..self.len], self.cursor);
        const char_len = self.cursor - char_start;
        if (self.cursor < self.len) {
            std.mem.copyForwards(
                u8,
                self.buf[char_start .. self.len - char_len],
                self.buf[self.cursor .. self.len],
            );
        }
        self.cursor = char_start;
        self.len -= char_len;
    }

    /// Delete the character (codepoint) at the cursor (delete key).
    pub fn delete(self: *Editor) void {
        if (self.cursor >= self.len) return;
        const char_len = charLenAt(self.buf[0..self.len], self.cursor);
        if (self.cursor + char_len < self.len) {
            std.mem.copyForwards(
                u8,
                self.buf[self.cursor .. self.len - char_len],
                self.buf[self.cursor + char_len .. self.len],
            );
        }
        self.len -= char_len;
    }

    // ------------------------------------------------------------------
    // Cursor movement (UTF-8 aware)
    // ------------------------------------------------------------------

    /// Move cursor one codepoint left.
    pub fn moveLeft(self: *Editor) void {
        if (self.cursor > 0) {
            self.cursor = prevCharStart(self.buf[0..self.len], self.cursor);
        }
    }

    /// Move cursor one codepoint right.
    pub fn moveRight(self: *Editor) void {
        if (self.cursor < self.len) {
            self.cursor += charLenAt(self.buf[0..self.len], self.cursor);
        }
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
    // Emacs-style editing
    // ------------------------------------------------------------------

    /// Kill from cursor to end of line (Ctrl+K). Saves to kill buffer.
    pub fn killToEnd(self: *Editor) void {
        if (self.cursor >= self.len) return;
        const killed = self.buf[self.cursor..self.len];
        @memcpy(self.kill_buf[0..killed.len], killed);
        self.kill_len = killed.len;
        self.len = self.cursor;
    }

    /// Kill from start of line to cursor (Ctrl+U). Saves to kill buffer.
    pub fn killToStart(self: *Editor) void {
        if (self.cursor == 0) return;
        const killed = self.buf[0..self.cursor];
        @memcpy(self.kill_buf[0..killed.len], killed);
        self.kill_len = killed.len;
        // Shift remaining content left
        const tail = self.len - self.cursor;
        if (tail > 0) std.mem.copyForwards(u8, self.buf[0..tail], self.buf[self.cursor..self.len]);
        self.len = tail;
        self.cursor = 0;
    }

    /// Kill word backward (Ctrl+W / Alt+Backspace). Saves to kill buffer.
    pub fn killWordBackward(self: *Editor) void {
        if (self.cursor == 0) return;
        var start = self.cursor;
        // Skip whitespace backward
        while (start > 0 and isWordSep(self.buf[start - 1])) : (start -= 1) {}
        // Skip word chars backward
        while (start > 0 and !isWordSep(self.buf[start - 1])) : (start -= 1) {}
        const killed = self.buf[start..self.cursor];
        @memcpy(self.kill_buf[0..killed.len], killed);
        self.kill_len = killed.len;
        self.replaceRange(start, self.cursor, "");
    }

    /// Kill word forward (Alt+D). Saves to kill buffer.
    pub fn killWordForward(self: *Editor) void {
        if (self.cursor >= self.len) return;
        var end = self.cursor;
        while (end < self.len and !isWordSep(self.buf[end])) : (end += 1) {}
        while (end < self.len and isWordSep(self.buf[end])) : (end += 1) {}
        const killed = self.buf[self.cursor..end];
        @memcpy(self.kill_buf[0..killed.len], killed);
        self.kill_len = killed.len;
        self.replaceRange(self.cursor, end, "");
    }

    /// Yank (paste) from kill buffer (Ctrl+Y).
    pub fn yank(self: *Editor) void {
        if (self.kill_len == 0) return;
        if (self.len + self.kill_len > MAX_LINE) return;
        // Insert kill buffer at cursor
        const tail = self.len - self.cursor;
        if (tail > 0) {
            std.mem.copyBackwards(u8, self.buf[self.cursor + self.kill_len ..][0..tail], self.buf[self.cursor..self.len]);
        }
        @memcpy(self.buf[self.cursor..][0..self.kill_len], self.kill_buf[0..self.kill_len]);
        self.len += self.kill_len;
        self.cursor += self.kill_len;
    }

    /// Transpose the two characters before cursor (Ctrl+T).
    pub fn transpose(self: *Editor) void {
        if (self.cursor < 2) return;
        const tmp = self.buf[self.cursor - 2];
        self.buf[self.cursor - 2] = self.buf[self.cursor - 1];
        self.buf[self.cursor - 1] = tmp;
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

    fn isWordSep(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '/' or ch == '.' or ch == '-' or ch == '_';
    }

    // ------------------------------------------------------------------
    // UTF-8 helpers
    // ------------------------------------------------------------------

    /// Length of the UTF-8 character starting at `pos`.
    fn charLenAt(buf: []const u8, pos: usize) usize {
        if (pos >= buf.len) return 1;
        const b = buf[pos];
        if (b < 0x80) return 1;
        if (b & 0xE0 == 0xC0) return @min(2, buf.len - pos);
        if (b & 0xF0 == 0xE0) return @min(3, buf.len - pos);
        if (b & 0xF8 == 0xF0) return @min(4, buf.len - pos);
        return 1; // invalid byte, treat as 1
    }

    /// Find the start of the character ending at or before `pos`.
    fn prevCharStart(buf: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        var i = pos - 1;
        // Walk back over continuation bytes (10xxxxxx)
        while (i > 0 and buf[i] & 0xC0 == 0x80) : (i -= 1) {}
        // Verify it's a valid lead byte
        if (buf[i] & 0xC0 == 0x80) return pos - 1; // all continuation, just go back 1
        return i;
    }

    /// Count visible characters (codepoints) in the buffer (for cursor display).
    pub fn visibleCursorPos(self: *const Editor) usize {
        var vis: usize = 0;
        var i: usize = 0;
        while (i < self.cursor) {
            i += charLenAt(self.buf[0..self.len], i);
            vis += 1;
        }
        return vis;
    }

    /// Count total visible characters in the buffer.
    pub fn visibleLen(self: *const Editor) usize {
        var vis: usize = 0;
        var i: usize = 0;
        while (i < self.len) {
            i += charLenAt(self.buf[0..self.len], i);
            vis += 1;
        }
        return vis;
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
