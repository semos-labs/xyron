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

    // ------------------------------------------------------------------
    // Text objects — return (start, end) ranges
    // ------------------------------------------------------------------

    pub const TextRange = struct { start: usize, end: usize };

    /// Inner word: the word under the cursor (no surrounding whitespace).
    pub fn innerWord(self: *const Editor) ?TextRange {
        if (self.len == 0) return null;
        const pos = @min(self.cursor, self.len - 1);
        var start = pos;
        var end = pos;

        if (isWordChar(self.buf[pos])) {
            while (start > 0 and isWordChar(self.buf[start - 1])) : (start -= 1) {}
            while (end < self.len and isWordChar(self.buf[end])) : (end += 1) {}
        } else if (self.buf[pos] == ' ' or self.buf[pos] == '\t') {
            // Cursor on whitespace — select the whitespace run
            while (start > 0 and isWhitespace(self.buf[start - 1])) : (start -= 1) {}
            while (end < self.len and isWhitespace(self.buf[end])) : (end += 1) {}
        } else {
            // Cursor on punctuation — select punctuation run
            while (start > 0 and !isWordChar(self.buf[start - 1]) and !isWhitespace(self.buf[start - 1])) : (start -= 1) {}
            while (end < self.len and !isWordChar(self.buf[end]) and !isWhitespace(self.buf[end])) : (end += 1) {}
        }

        return .{ .start = start, .end = end };
    }

    /// A word: the word under the cursor plus trailing (or leading) whitespace.
    pub fn aWord(self: *const Editor) ?TextRange {
        const iw = self.innerWord() orelse return null;
        var start = iw.start;
        var end = iw.end;

        // Include trailing whitespace first
        if (end < self.len and isWhitespace(self.buf[end])) {
            while (end < self.len and isWhitespace(self.buf[end])) : (end += 1) {}
        } else if (start > 0 and isWhitespace(self.buf[start - 1])) {
            // No trailing whitespace — include leading whitespace
            while (start > 0 and isWhitespace(self.buf[start - 1])) : (start -= 1) {}
        }

        return .{ .start = start, .end = end };
    }

    /// Inner quoted: content between matching quotes (not including quotes).
    pub fn innerQuoted(self: *const Editor, quote: u8) ?TextRange {
        return self.findQuotedRange(quote, false);
    }

    /// A quoted: content between matching quotes (including the quotes).
    pub fn aQuoted(self: *const Editor, quote: u8) ?TextRange {
        return self.findQuotedRange(quote, true);
    }

    fn findQuotedRange(self: *const Editor, quote: u8, include_quotes: bool) ?TextRange {
        if (self.len == 0) return null;
        const buf = self.buf[0..self.len];
        const pos = @min(self.cursor, self.len - 1);

        // Strategy: find the quote pair surrounding the cursor.
        // Search backward for opening quote, forward for closing quote.
        var open: ?usize = null;
        var close: ?usize = null;

        // If cursor is on a quote, decide if it's opening or closing
        if (buf[pos] == quote) {
            // Count quotes before cursor to determine parity
            var count: usize = 0;
            for (buf[0..pos]) |c| {
                if (c == quote) count += 1;
            }
            if (count % 2 == 0) {
                // Even count before = this is an opening quote
                open = pos;
            } else {
                // Odd count before = this is a closing quote
                close = pos;
            }
        }

        // Search backward for opening quote if not found
        if (open == null) {
            var i = if (close != null and close.? > 0) close.? - 1 else if (pos > 0) pos - 1 else return null;
            while (true) {
                if (buf[i] == quote) { open = i; break; }
                if (i == 0) break;
                i -= 1;
            }
        }
        if (open == null) return null;

        // Search forward for closing quote if not found
        if (close == null) {
            var i = open.? + 1;
            while (i < buf.len) : (i += 1) {
                if (buf[i] == quote) { close = i; break; }
            }
        }
        if (close == null) return null;

        if (include_quotes) {
            return .{ .start = open.?, .end = close.? + 1 };
        } else {
            return .{ .start = open.? + 1, .end = close.? };
        }
    }

    /// Inner parentheses/brackets: content between matching pair.
    pub fn innerPair(self: *const Editor, open_ch: u8, close_ch: u8) ?TextRange {
        return self.findPairRange(open_ch, close_ch, false);
    }

    /// A parentheses/brackets: content including the delimiters.
    pub fn aPair(self: *const Editor, open_ch: u8, close_ch: u8) ?TextRange {
        return self.findPairRange(open_ch, close_ch, true);
    }

    fn findPairRange(self: *const Editor, open_ch: u8, close_ch: u8, include_delims: bool) ?TextRange {
        if (self.len == 0) return null;
        const buf = self.buf[0..self.len];
        const pos = @min(self.cursor, self.len - 1);

        // Search backward for opening delimiter (tracking nesting)
        var open_pos: ?usize = null;
        {
            var depth: i32 = 0;
            var i = pos;
            while (true) {
                if (buf[i] == close_ch) depth += 1;
                if (buf[i] == open_ch) {
                    if (depth == 0) { open_pos = i; break; }
                    depth -= 1;
                }
                if (i == 0) break;
                i -= 1;
            }
        }
        if (open_pos == null) return null;

        // Search forward for closing delimiter
        var close_pos: ?usize = null;
        {
            var depth: i32 = 0;
            var i = open_pos.? + 1;
            while (i < buf.len) : (i += 1) {
                if (buf[i] == open_ch) depth += 1;
                if (buf[i] == close_ch) {
                    if (depth == 0) { close_pos = i; break; }
                    depth -= 1;
                }
            }
        }
        if (close_pos == null) return null;

        if (include_delims) {
            return .{ .start = open_pos.?, .end = close_pos.? + 1 };
        } else {
            return .{ .start = open_pos.? + 1, .end = close_pos.? };
        }
    }

    /// Apply an operator (d, c, y) to a text range.
    pub fn applyOperator(self: *Editor, op: u8, range: TextRange) void {
        // Save to kill buffer
        const killed = self.buf[range.start..range.end];
        @memcpy(self.kill_buf[0..killed.len], killed);
        self.kill_len = killed.len;

        switch (op) {
            'd' => {
                self.replaceRange(range.start, range.end, "");
                self.cursor = range.start;
                self.clampNormal();
            },
            'c' => {
                self.replaceRange(range.start, range.end, "");
                self.cursor = range.start;
                self.mode = .insert;
            },
            'y' => {
                // Yank only — don't delete, move cursor to start
                self.cursor = range.start;
            },
            else => {},
        }
    }

    /// Find end position for a motion from current cursor.
    pub fn motionEnd(self: *const Editor, motion: u8) ?usize {
        var copy = self.*;
        switch (motion) {
            'w' => { copy.moveWordForward(); return copy.cursor; },
            'b' => { return null; }, // backward handled specially
            'e' => {
                // Move to end of word
                var i = copy.cursor;
                if (i < copy.len) i += 1; // skip current char
                while (i < copy.len and isWhitespace(copy.buf[i])) : (i += 1) {}
                while (i < copy.len and isWordChar(copy.buf[i])) : (i += 1) {}
                return i;
            },
            '$' => return copy.len,
            '0' => return null, // handled as backward motion
            else => return null,
        }
    }

    /// Find start position for a backward motion.
    pub fn motionStart(self: *const Editor, motion: u8) ?usize {
        var copy = self.*;
        switch (motion) {
            'b' => { copy.moveWordBackward(); return copy.cursor; },
            '0' => return 0,
            else => return null,
        }
    }

    fn isWordChar(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_';
    }

    fn isWhitespace(ch: u8) bool {
        return ch == ' ' or ch == '\t';
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

// ------------------------------------------------------------------
// Text object tests
// ------------------------------------------------------------------

test "innerWord on word" {
    var ed = Editor{};
    ed.setContent("hello world");
    ed.cursor = 2; // on 'l' in "hello"
    const range = ed.innerWord().?;
    try std.testing.expectEqual(@as(usize, 0), range.start);
    try std.testing.expectEqual(@as(usize, 5), range.end);
}

test "innerWord on whitespace" {
    var ed = Editor{};
    ed.setContent("hello   world");
    ed.cursor = 6; // on space between words
    const range = ed.innerWord().?;
    try std.testing.expectEqual(@as(usize, 5), range.start);
    try std.testing.expectEqual(@as(usize, 8), range.end);
}

test "aWord includes trailing whitespace" {
    var ed = Editor{};
    ed.setContent("hello world");
    ed.cursor = 2; // on 'l' in "hello"
    const range = ed.aWord().?;
    try std.testing.expectEqual(@as(usize, 0), range.start);
    try std.testing.expectEqual(@as(usize, 6), range.end);
}

test "innerQuoted double" {
    var ed = Editor{};
    ed.setContent("say \"hello world\" ok");
    ed.cursor = 8; // on 'l' inside quotes
    const range = ed.innerQuoted('"').?;
    try std.testing.expectEqual(@as(usize, 5), range.start);
    try std.testing.expectEqual(@as(usize, 16), range.end);
    try std.testing.expectEqualStrings("hello world", ed.buf[range.start..range.end]);
}

test "aQuoted includes quotes" {
    var ed = Editor{};
    ed.setContent("say \"hello\" ok");
    ed.cursor = 6; // inside quotes
    const range = ed.aQuoted('"').?;
    try std.testing.expectEqual(@as(usize, 4), range.start);
    try std.testing.expectEqual(@as(usize, 11), range.end);
    try std.testing.expectEqualStrings("\"hello\"", ed.buf[range.start..range.end]);
}

test "innerPair parentheses" {
    var ed = Editor{};
    ed.setContent("foo(bar, baz)");
    ed.cursor = 5; // on 'a' in "bar"
    const range = ed.innerPair('(', ')').?;
    try std.testing.expectEqual(@as(usize, 4), range.start);
    try std.testing.expectEqual(@as(usize, 12), range.end);
    try std.testing.expectEqualStrings("bar, baz", ed.buf[range.start..range.end]);
}

test "innerPair nested" {
    var ed = Editor{};
    ed.setContent("a(b(c)d)e");
    ed.cursor = 4; // on 'c'
    const range = ed.innerPair('(', ')').?;
    try std.testing.expectEqual(@as(usize, 4), range.start);
    try std.testing.expectEqual(@as(usize, 5), range.end);
    try std.testing.expectEqualStrings("c", ed.buf[range.start..range.end]);
}

test "applyOperator delete" {
    var ed = Editor{};
    ed.setContent("hello world");
    ed.cursor = 0;
    const range = ed.innerWord().?;
    ed.applyOperator('d', range);
    try std.testing.expectEqualStrings(" world", ed.content());
}

test "applyOperator change" {
    var ed = Editor{};
    ed.vim_enabled = true;
    ed.mode = .normal;
    ed.setContent("hello world");
    ed.cursor = 0;
    const range = ed.innerWord().?;
    ed.applyOperator('c', range);
    try std.testing.expectEqualStrings(" world", ed.content());
    try std.testing.expectEqual(VimMode.insert, ed.mode);
}

test "applyOperator yank" {
    var ed = Editor{};
    ed.setContent("hello world");
    ed.cursor = 0;
    const range = ed.innerWord().?;
    ed.applyOperator('y', range);
    // Content unchanged
    try std.testing.expectEqualStrings("hello world", ed.content());
    // Kill buffer has yanked text
    try std.testing.expectEqualStrings("hello", ed.kill_buf[0..ed.kill_len]);
}
