// unicode.zig — Unicode display width utilities for TUI rendering.
//
// Provides codepoint-level and string-level display width calculations
// following Unicode East Asian Width and zero-width character rules.
// Used by TUI components to correctly clip and pad text containing
// CJK characters, emoji, and combining marks.

const std = @import("std");

/// Display width of a single Unicode codepoint.
/// Returns 0 for combining marks and control chars,
/// 2 for fullwidth/wide (CJK, some symbols), 1 otherwise.
pub fn codepointWidth(cp: u21) u16 {
    // Zero-width characters
    if (cp == 0) return 0;
    // C0/C1 control characters (except tab which we treat as 1)
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0;
    // Combining characters (general category Mn, Mc, Me)
    if (isCombining(cp)) return 0;
    // Soft hyphen
    if (cp == 0xAD) return 1;
    // Zero-width characters
    if (cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF) return 0;
    // Variation selectors
    if (cp >= 0xFE00 and cp <= 0xFE0F) return 0;
    if (cp >= 0xE0100 and cp <= 0xE01EF) return 0;
    // Wide characters
    if (isWide(cp)) return 2;
    return 1;
}

/// Calculate the display width of a UTF-8 string in terminal columns.
pub fn displayWidth(text: []const u8) u16 {
    var width: u16 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            // Invalid UTF-8 byte — treat as 1 column
            width += 1;
            i += 1;
            continue;
        };
        if (i + len > text.len) {
            // Truncated sequence
            width += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            width += 1;
            i += 1;
            continue;
        };
        width +|= codepointWidth(cp);
        i += len;
    }
    return width;
}

/// Copy text into buf, limited to max_w display columns.
/// Returns a struct with bytes written and visible columns consumed.
/// Handles multi-byte UTF-8 and wide characters correctly.
pub fn clipText(buf: []u8, text: []const u8, max_w: u16) ClipResult {
    var vis: u16 = 0;
    var src: usize = 0;
    var dst: usize = 0;

    while (src < text.len and vis < max_w) {
        const len = std.unicode.utf8ByteSequenceLength(text[src]) catch {
            // Invalid byte — copy as-is, count as 1 column
            if (dst >= buf.len) break;
            buf[dst] = text[src];
            dst += 1;
            src += 1;
            vis += 1;
            continue;
        };
        if (src + len > text.len) break; // truncated sequence
        const cp = std.unicode.utf8Decode(text[src..][0..len]) catch {
            if (dst >= buf.len) break;
            buf[dst] = text[src];
            dst += 1;
            src += 1;
            vis += 1;
            continue;
        };

        const w = codepointWidth(cp);
        // Don't start a wide char if it would exceed max_w
        if (w > 0 and vis + w > max_w) break;

        // Copy the bytes
        if (dst + len > buf.len) break;
        @memcpy(buf[dst .. dst + len], text[src .. src + len]);
        dst += len;
        src += len;
        vis +|= w;
    }

    return .{ .bytes = dst, .width = vis };
}

pub const ClipResult = struct {
    bytes: usize,
    width: u16,
};

// ---------------------------------------------------------------------------
// Unicode range tables
// ---------------------------------------------------------------------------

/// Check if a codepoint is a combining character (zero-width).
fn isCombining(cp: u21) bool {
    // Combining Diacritical Marks
    if (cp >= 0x0300 and cp <= 0x036F) return true;
    // Combining Diacritical Marks Extended
    if (cp >= 0x1AB0 and cp <= 0x1AFF) return true;
    // Combining Diacritical Marks Supplement
    if (cp >= 0x1DC0 and cp <= 0x1DFF) return true;
    // Combining Diacritical Marks for Symbols
    if (cp >= 0x20D0 and cp <= 0x20FF) return true;
    // Combining Half Marks
    if (cp >= 0xFE20 and cp <= 0xFE2F) return true;
    // Thai combining
    if (cp >= 0x0E31 and cp <= 0x0E3A) return true;
    if (cp >= 0x0E47 and cp <= 0x0E4E) return true;
    // Devanagari etc. combining vowels/marks (common ranges)
    if (cp >= 0x0900 and cp <= 0x0903) return true;
    if (cp >= 0x093A and cp <= 0x094F) return true;
    if (cp >= 0x0951 and cp <= 0x0957) return true;
    // Arabic combining
    if (cp >= 0x0610 and cp <= 0x061A) return true;
    if (cp >= 0x064B and cp <= 0x065F) return true;
    if (cp >= 0x0670 and cp == 0x0670) return true;
    // Hangul Jungseong / Jongseong (combining Jamo)
    if (cp >= 0x1160 and cp <= 0x11FF) return true;
    // Enclosing marks
    if (cp >= 0x0488 and cp <= 0x0489) return true;
    return false;
}

/// Check if a codepoint is wide (takes 2 columns).
fn isWide(cp: u21) bool {
    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true;
    // CJK Unified Ideographs Extension A
    if (cp >= 0x3400 and cp <= 0x4DBF) return true;
    // CJK Unified Ideographs Extension B
    if (cp >= 0x20000 and cp <= 0x2A6DF) return true;
    // CJK Unified Ideographs Extension C-F
    if (cp >= 0x2A700 and cp <= 0x2CEAF) return true;
    // CJK Compatibility Ideographs
    if (cp >= 0xF900 and cp <= 0xFAFF) return true;
    // CJK Compatibility Ideographs Supplement
    if (cp >= 0x2F800 and cp <= 0x2FA1F) return true;
    // Hangul Syllables
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true;
    // CJK Radicals Supplement
    if (cp >= 0x2E80 and cp <= 0x2EFF) return true;
    // Kangxi Radicals
    if (cp >= 0x2F00 and cp <= 0x2FDF) return true;
    // CJK Symbols and Punctuation
    if (cp >= 0x3000 and cp <= 0x303F) return true;
    // Hiragana
    if (cp >= 0x3040 and cp <= 0x309F) return true;
    // Katakana
    if (cp >= 0x30A0 and cp <= 0x30FF) return true;
    // Bopomofo
    if (cp >= 0x3100 and cp <= 0x312F) return true;
    // Enclosed CJK Letters and Months
    if (cp >= 0x3200 and cp <= 0x32FF) return true;
    // CJK Compatibility
    if (cp >= 0x3300 and cp <= 0x33FF) return true;
    // Katakana Phonetic Extensions
    if (cp >= 0x31F0 and cp <= 0x31FF) return true;
    // Halfwidth and Fullwidth Forms (fullwidth range)
    if (cp >= 0xFF01 and cp <= 0xFF60) return true;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return true;
    // Emoji (common ranges that display as wide)
    if (cp >= 0x1F300 and cp <= 0x1F9FF) return true;
    if (cp >= 0x1FA00 and cp <= 0x1FA6F) return true;
    if (cp >= 0x1FA70 and cp <= 0x1FAFF) return true;
    // Miscellaneous Symbols and Pictographs
    if (cp >= 0x1F600 and cp <= 0x1F64F) return true;
    // Transport and Map Symbols
    if (cp >= 0x1F680 and cp <= 0x1F6FF) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ASCII width" {
    try std.testing.expectEqual(@as(u16, 5), displayWidth("hello"));
    try std.testing.expectEqual(@as(u16, 0), displayWidth(""));
}

test "CJK width" {
    // 你好 = 2 characters, each 2 columns wide
    try std.testing.expectEqual(@as(u16, 4), displayWidth("你好"));
    // Mixed: "hi你" = 2 + 2 = 4
    try std.testing.expectEqual(@as(u16, 4), displayWidth("hi你"));
}

test "combining marks zero width" {
    // e + combining acute accent = 1 column
    try std.testing.expectEqual(@as(u16, 1), displayWidth("e\xCC\x81"));
}

test "emoji width" {
    // 🎉 = U+1F389
    try std.testing.expectEqual(@as(u16, 2), displayWidth("🎉"));
}

test "codepointWidth control chars" {
    try std.testing.expectEqual(@as(u16, 0), codepointWidth(0));
    try std.testing.expectEqual(@as(u16, 0), codepointWidth(0x01));
    try std.testing.expectEqual(@as(u16, 1), codepointWidth('A'));
}

test "clipText ASCII" {
    var buf: [32]u8 = undefined;
    const r = clipText(&buf, "hello world", 5);
    try std.testing.expectEqual(@as(usize, 5), r.bytes);
    try std.testing.expectEqual(@as(u16, 5), r.width);
    try std.testing.expectEqualStrings("hello", buf[0..r.bytes]);
}

test "clipText CJK truncation" {
    var buf: [32]u8 = undefined;
    // "你好世界" = 4 chars, 8 columns. Clip to 5 columns = "你好" (4) + can't fit 世 (would be 6)
    const r = clipText(&buf, "你好世界", 5);
    try std.testing.expectEqual(@as(u16, 4), r.width);
    try std.testing.expectEqualStrings("你好", buf[0..r.bytes]);
}

test "clipText mixed" {
    var buf: [32]u8 = undefined;
    // "a你b" = 1 + 2 + 1 = 4 columns
    const r = clipText(&buf, "a你b", 10);
    try std.testing.expectEqual(@as(u16, 4), r.width);
    try std.testing.expectEqualStrings("a你b", buf[0..r.bytes]);
}

test "clipText wide char boundary" {
    var buf: [32]u8 = undefined;
    // "你好" = 4 columns. Clip to 3 = only "你" (2 columns, can't fit 好)
    const r = clipText(&buf, "你好", 3);
    try std.testing.expectEqual(@as(u16, 2), r.width);
    try std.testing.expectEqualStrings("你", buf[0..r.bytes]);
}
