// prompt_powerline.zig — Powerline-style prompt rendering.
//
// Handles rendering prompt segments with background colors and
// separator transitions (e.g. , , or custom glyphs).
// Extracted from prompt.zig to keep files within size limits.

const std = @import("std");
const style = @import("style.zig");
const lua_api = @import("lua_api.zig");
const prompt = @import("prompt.zig");

const Segment = prompt.Segment;
const PromptConfig = prompt.PromptConfig;
const PromptContext = prompt.PromptContext;
const SegResult = prompt.SegResult;
const MAX_SEGMENTS = prompt.MAX_SEGMENTS;

/// Render a single line in powerline mode.
/// Pre-renders all segments, then composes with bg colors and separator transitions.
pub fn renderLine(
    dest: []u8,
    cfg: *PromptConfig,
    segments: []Segment,
    has_spacer: bool,
    term_w: usize,
    ctx: *const PromptContext,
    lua: lua_api.LuaState,
) SegResult {
    // Phase 1: pre-render all segments to temp buffers, determine which are non-empty
    const max_segs = MAX_SEGMENTS;
    var raw_bufs: [max_segs][512]u8 = undefined;
    var raw_lens: [max_segs]usize = .{0} ** max_segs;
    var raw_vis: [max_segs]usize = .{0} ** max_segs;
    var is_powerline_seg: [max_segs]bool = .{false} ** max_segs;

    for (segments, 0..) |*seg, idx| {
        if (idx >= max_segs) break;
        if (seg.kind == .spacer) continue;
        const r = prompt.renderSegment(&raw_bufs[idx], seg, ctx, lua);
        raw_lens[idx] = r.bytes;
        raw_vis[idx] = r.visible;
        is_powerline_seg[idx] = seg.bg_color != null;
    }

    // Phase 2: if spacer, measure total visible width for spacing
    var spacer_w: usize = 0;
    if (has_spacer) {
        var total_vis: usize = 0;
        for (segments, 0..) |*seg, idx| {
            if (idx >= max_segs) break;
            if (seg.kind == .spacer) continue;
            if (raw_vis[idx] == 0) continue;
            if (is_powerline_seg[idx]) {
                total_vis += raw_vis[idx] + 2; // padding spaces
                total_vis += visLen(cfg.getSeparator()); // separator glyph
            } else {
                total_vis += raw_vis[idx];
            }
        }
        spacer_w = if (term_w > total_vis) term_w - total_vis else 1;
    }

    // Phase 3: compose output with powerline transitions
    var pos: usize = 0;
    var visible: usize = 0;
    var prev_bg: ?style.Color = null;

    for (segments, 0..) |*seg, idx| {
        if (idx >= max_segs) break;

        if (seg.kind == .spacer) {
            // End current powerline run, insert spacer, continue
            if (prev_bg) |pbg| {
                pos += style.reset(dest[pos..]);
                pos += style.fg(dest[pos..], pbg);
                pos += cp(dest[pos..], cfg.getSeparator());
                visible += visLen(cfg.getSeparator());
                pos += style.reset(dest[pos..]);
                prev_bg = null;
            }
            const n = @min(spacer_w, dest.len - pos);
            @memset(dest[pos..][0..n], ' ');
            pos += n;
            visible += n;
            continue;
        }

        // Skip empty segments
        if (raw_vis[idx] == 0) continue;

        if (is_powerline_seg[idx]) {
            const seg_bg = seg.bg_color.?;
            const seg_fg = seg.fg_color orelse .white;

            // Separator transition from previous segment
            if (prev_bg) |pbg| {
                // Transition: fg=prev_bg, bg=current_bg
                pos += style.fg(dest[pos..], pbg);
                pos += style.bg(dest[pos..], seg_bg);
                pos += cp(dest[pos..], cfg.getSeparator());
                visible += visLen(cfg.getSeparator());
            } else {
                // First powerline segment — just set bg
                pos += style.bg(dest[pos..], seg_bg);
            }

            // Segment content: fg color + stripped text with padding
            pos += style.fg(dest[pos..], seg_fg);
            pos += cp(dest[pos..], " ");
            visible += 1;

            // Strip ANSI from pre-rendered content and output raw text
            var stripped: [512]u8 = undefined;
            const slen = stripAnsi(&stripped, raw_bufs[idx][0..raw_lens[idx]]);
            pos += cp(dest[pos..], stripped[0..slen]);
            visible += visLen(stripped[0..slen]);

            pos += cp(dest[pos..], " ");
            visible += 1;

            prev_bg = seg_bg;
        } else {
            // Non-powerline segment: end powerline run if active, render normally
            if (prev_bg) |pbg| {
                pos += style.reset(dest[pos..]);
                pos += style.fg(dest[pos..], pbg);
                pos += cp(dest[pos..], cfg.getSeparator());
                visible += visLen(cfg.getSeparator());
                pos += style.reset(dest[pos..]);
                prev_bg = null;
            }
            // Render the segment as-is (already in raw_bufs)
            pos += cp(dest[pos..], raw_bufs[idx][0..raw_lens[idx]]);
            visible += raw_vis[idx];
        }
    }

    // Final transition: close last powerline segment
    if (prev_bg) |pbg| {
        pos += style.reset(dest[pos..]);
        pos += style.fg(dest[pos..], pbg);
        pos += cp(dest[pos..], cfg.getSeparator());
        visible += visLen(cfg.getSeparator());
        pos += style.reset(dest[pos..]);
    }

    return .{ .bytes = pos, .visible = visible };
}

/// Strip ANSI escape sequences from a string, returning only visible text.
pub fn stripAnsi(dest: []u8, src: []const u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < dest.len) {
        if (src[i] == 0x1b and i + 1 < src.len and src[i + 1] == '[') {
            // Skip CSI sequence: ESC [ ... final_byte
            i += 2;
            while (i < src.len and src[i] < 0x40) : (i += 1) {}
            if (i < src.len) i += 1; // skip final byte
        } else {
            dest[out] = src[i];
            out += 1;
            i += 1;
        }
    }
    return out;
}

/// Estimate visible width of a UTF-8 string (count codepoints, not bytes).
fn visLen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) { i += 1; }
        else if (s[i] < 0xE0) { i += 2; }
        else if (s[i] < 0xF0) { i += 3; }
        else { i += 4; }
        n += 1;
    }
    return n;
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stripAnsi removes escape sequences" {
    var out: [64]u8 = undefined;
    const n = stripAnsi(&out, "\x1b[1;34mhello\x1b[0m world");
    try std.testing.expectEqualStrings("hello world", out[0..n]);
}

test "stripAnsi passthrough plain text" {
    var out: [64]u8 = undefined;
    const n = stripAnsi(&out, "plain text");
    try std.testing.expectEqualStrings("plain text", out[0..n]);
}
