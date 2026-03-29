// prompt.zig — Prompt engine with modular segments.
//
// Builds the prompt from a configurable sequence of segments, each
// producing styled text from runtime context. Supports Lua-defined
// segments and configuration. Falls back to a sensible default.

const std = @import("std");
const lua_api = @import("lua_api.zig");

pub const MAX_PROMPT: usize = 2048;
pub const MAX_SEGMENTS: usize = 16;

// ---------------------------------------------------------------------------
// Prompt context — runtime state passed to each segment
// ---------------------------------------------------------------------------

pub const PromptContext = struct {
    cwd: []const u8 = "",
    home: []const u8 = "",
    last_exit_code: u8 = 0,
    last_duration_ms: i64 = 0,
    job_count: usize = 0,
    user: []const u8 = "",
    hostname: []const u8 = "",
    git_branch: []const u8 = "",
    vim_normal: bool = false, // true when in vim normal mode
};

// ---------------------------------------------------------------------------
// Built-in segment types
// ---------------------------------------------------------------------------

pub const SegmentKind = enum {
    cwd,
    symbol,
    status,
    duration,
    jobs,
    git_branch,
    newline, // line break for multiline prompts
    spacer, // fills remaining space to push next segments to the right
    text, // literal text
    lua_fn, // Lua-defined segment
};

pub const Segment = struct {
    kind: SegmentKind,
    // For .text segments
    text: [128]u8 = undefined,
    text_len: usize = 0,
    // For .lua_fn segments — Lua registry ref
    lua_ref: c_int = 0,
    // Style
    color: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Prompt configuration
// ---------------------------------------------------------------------------

pub const PromptConfig = struct {
    segments: [MAX_SEGMENTS]Segment = undefined,
    count: usize = 0,

    pub fn addBuiltin(self: *PromptConfig, kind: SegmentKind, color: []const u8) void {
        if (self.count >= MAX_SEGMENTS) return;
        self.segments[self.count] = .{ .kind = kind, .color = color };
        self.count += 1;
    }

    pub fn addText(self: *PromptConfig, literal: []const u8, color: []const u8) void {
        if (self.count >= MAX_SEGMENTS) return;
        var seg = Segment{ .kind = .text, .color = color };
        const len = @min(literal.len, 128);
        @memcpy(seg.text[0..len], literal[0..len]);
        seg.text_len = len;
        self.segments[self.count] = seg;
        self.count += 1;
    }

    pub fn addNewline(self: *PromptConfig) void {
        if (self.count >= MAX_SEGMENTS) return;
        self.segments[self.count] = .{ .kind = .newline };
        self.count += 1;
    }

    pub fn addLua(self: *PromptConfig, ref: c_int) void {
        if (self.count >= MAX_SEGMENTS) return;
        self.segments[self.count] = .{ .kind = .lua_fn, .lua_ref = ref };
        self.count += 1;
    }
};

/// Default prompt config — used when no Lua config overrides it.
pub fn defaultConfig() PromptConfig {
    var cfg = PromptConfig{};
    cfg.addBuiltin(.cwd, "\x1b[1;34m"); // bold blue
    cfg.addText(" ", "");
    cfg.addBuiltin(.git_branch, "\x1b[35m"); // magenta
    cfg.addBuiltin(.jobs, "\x1b[33m"); // yellow
    cfg.addBuiltin(.symbol, ""); // color set dynamically
    cfg.addText(" ", "");
    return cfg;
}

// Global prompt config — set by Lua or default
var global_config: ?PromptConfig = null;

pub fn getConfig() *PromptConfig {
    if (global_config == null) {
        global_config = defaultConfig();
    }
    return &(global_config.?);
}

pub fn setConfig(cfg: PromptConfig) void {
    global_config = cfg;
}

// ---------------------------------------------------------------------------
// Prompt rendering
// ---------------------------------------------------------------------------

// Static buffers so slices in PromptContext outlive buildContext()
var static_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;

/// Build the prompt context from current shell state.
pub fn buildContext(last_exit: u8, last_duration: i64, job_count: usize) PromptContext {
    var ctx = PromptContext{
        .last_exit_code = last_exit,
        .last_duration_ms = last_duration,
        .job_count = job_count,
    };

    ctx.cwd = std.posix.getcwd(&static_cwd_buf) catch "?";
    ctx.home = std.posix.getenv("HOME") orelse "";
    ctx.user = std.posix.getenv("USER") orelse "";
    ctx.git_branch = readGitBranch() orelse "";

    return ctx;
}

/// Render the full prompt into a buffer. Returns the visible length
/// (excluding ANSI escapes) and the full buffer slice.
pub fn render(buf: *[MAX_PROMPT]u8, ctx: *const PromptContext, lua: lua_api.LuaState) PromptResult {
    var pos: usize = 0;
    var visible_len: usize = 0;
    var lines: usize = 1;
    const cfg = getConfig();
    const term_w = getTermWidth();

    // Render line-by-line to support spacers
    var seg_i: usize = 0;
    while (seg_i < cfg.count) {
        // Find the range of segments for this line (until newline or end)
        const line_start = seg_i;
        var line_end = seg_i;
        var has_spacer = false;
        while (line_end < cfg.count and cfg.segments[line_end].kind != .newline) {
            if (cfg.segments[line_end].kind == .spacer) has_spacer = true;
            line_end += 1;
        }

        if (has_spacer) {
            // Two-pass: measure non-spacer visible width, then fill spacer
            var non_spacer_vis: usize = 0;
            // Pass 1: measure
            for (cfg.segments[line_start..line_end]) |*seg| {
                if (seg.kind == .spacer) continue;
                var tmp: [512]u8 = undefined;
                const r = renderSegment(&tmp, seg, ctx, lua);
                non_spacer_vis += r.visible;
            }
            const spacer_w = if (term_w > non_spacer_vis) term_w - non_spacer_vis else 1;

            // Pass 2: render with spacer filled
            for (cfg.segments[line_start..line_end]) |*seg| {
                if (seg.kind == .spacer) {
                    // Fill with spaces
                    const n = @min(spacer_w, MAX_PROMPT - pos);
                    @memset(buf[pos..][0..n], ' ');
                    pos += n;
                    visible_len += n;
                } else {
                    const r = renderSegment(buf[pos..], seg, ctx, lua);
                    pos += r.bytes;
                    visible_len += r.visible;
                }
            }
        } else {
            // No spacer — render directly
            for (cfg.segments[line_start..line_end]) |*seg| {
                const r = renderSegment(buf[pos..], seg, ctx, lua);
                pos += r.bytes;
                visible_len += r.visible;
            }
        }

        seg_i = line_end;
        // Render newline if present
        if (seg_i < cfg.count and cfg.segments[seg_i].kind == .newline) {
            const r = renderNewline(buf[pos..]);
            pos += r.bytes;
            lines += 1;
            seg_i += 1;
        }
    }

    return .{ .text = buf[0..pos], .visible_len = visible_len, .line_count = lines };
}

fn getTermWidth() usize {
    const c_ext = struct {
        const winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    };
    var ws: c_ext.winsize = undefined;
    if (c_ext.ioctl(std.posix.STDOUT_FILENO, 0x40087468, &ws) == 0 and ws.ws_col > 0) {
        return ws.ws_col;
    }
    return 80;
}

pub const PromptResult = struct {
    text: []const u8,
    visible_len: usize,
    line_count: usize, // number of lines (1 = single line, 2 = one newline, etc.)
};

/// Write for direct-to-stdout rendering (cooked mode fallback).
pub fn renderPrompt(stdout: std.fs.File, ctx: *const PromptContext, lua: lua_api.LuaState) void {
    var buf: [MAX_PROMPT]u8 = undefined;
    const result = render(&buf, ctx, lua);
    stdout.writeAll(result.text) catch {};
}

// ---------------------------------------------------------------------------
// Segment rendering
// ---------------------------------------------------------------------------

const SegResult = struct { bytes: usize, visible: usize };

fn renderSegment(dest: []u8, seg: *const Segment, ctx: *const PromptContext, lua: lua_api.LuaState) SegResult {
    return switch (seg.kind) {
        .cwd => renderCwd(dest, seg, ctx),
        .symbol => renderSymbol(dest, ctx),
        .status => renderStatus(dest, ctx),
        .duration => renderDuration(dest, ctx),
        .jobs => renderJobs(dest, seg, ctx),
        .git_branch => renderGitBranch(dest, seg, ctx),
        .newline => renderNewline(dest),
        .spacer => .{ .bytes = 0, .visible = 0 }, // handled by render()
        .text => renderText(dest, seg),
        .lua_fn => renderLuaSegment(dest, seg, lua),
    };
}

fn renderNewline(dest: []u8) SegResult {
    // Use \r\n in raw mode (OPOST disabled)
    const n = cp(dest, "\r\n");
    return .{ .bytes = n, .visible = 0 };
}

fn renderCwd(dest: []u8, seg: *const Segment, ctx: *const PromptContext) SegResult {
    var pos: usize = 0;
    pos += cp(dest[pos..], seg.color);
    const vis_start = pos;

    // Tilde contraction
    if (ctx.home.len > 0 and std.mem.eql(u8, ctx.cwd, ctx.home)) {
        pos += cp(dest[pos..], "~");
    } else if (ctx.home.len > 0 and std.mem.startsWith(u8, ctx.cwd, ctx.home) and ctx.cwd.len > ctx.home.len and ctx.cwd[ctx.home.len] == '/') {
        pos += cp(dest[pos..], "~");
        pos += cp(dest[pos..], ctx.cwd[ctx.home.len..]);
    } else {
        pos += cp(dest[pos..], ctx.cwd);
    }

    const vis_end = pos;
    if (seg.color.len > 0) pos += cp(dest[pos..], "\x1b[0m");
    return .{ .bytes = pos, .visible = vis_end - vis_start };
}

fn renderSymbol(dest: []u8, ctx: *const PromptContext) SegResult {
    var pos: usize = 0;
    const symbol: []const u8 = if (ctx.vim_normal) "<" else ">";
    if (ctx.last_exit_code != 0) {
        pos += cp(dest[pos..], "\x1b[1;31m");
    } else {
        pos += cp(dest[pos..], if (ctx.vim_normal) "\x1b[1;33m" else "\x1b[1;32m");
    }
    pos += cp(dest[pos..], symbol);
    pos += cp(dest[pos..], "\x1b[0m");
    return .{ .bytes = pos, .visible = 1 };
}

fn renderStatus(dest: []u8, ctx: *const PromptContext) SegResult {
    if (ctx.last_exit_code == 0) return .{ .bytes = 0, .visible = 0 };
    var pos: usize = 0;
    pos += cp(dest[pos..], "\x1b[31m");
    const n = std.fmt.bufPrint(dest[pos..], "✘{d}", .{ctx.last_exit_code}) catch return .{ .bytes = 0, .visible = 0 };
    pos += n.len;
    const vis = n.len;
    pos += cp(dest[pos..], "\x1b[0m ");
    return .{ .bytes = pos, .visible = vis + 1 };
}

fn renderDuration(dest: []u8, ctx: *const PromptContext) SegResult {
    if (ctx.last_duration_ms < 1000) return .{ .bytes = 0, .visible = 0 };
    var pos: usize = 0;
    pos += cp(dest[pos..], "\x1b[33m");
    const secs = @divTrunc(ctx.last_duration_ms, 1000);
    const n = std.fmt.bufPrint(dest[pos..], "took {d}s ", .{secs}) catch return .{ .bytes = 0, .visible = 0 };
    pos += n.len;
    const vis = n.len;
    pos += cp(dest[pos..], "\x1b[0m");
    return .{ .bytes = pos, .visible = vis };
}

fn renderJobs(dest: []u8, seg: *const Segment, ctx: *const PromptContext) SegResult {
    if (ctx.job_count == 0) return .{ .bytes = 0, .visible = 0 };
    var pos: usize = 0;
    pos += cp(dest[pos..], seg.color);
    const n = std.fmt.bufPrint(dest[pos..], " ⚙{d}", .{ctx.job_count}) catch return .{ .bytes = 0, .visible = 0 };
    pos += n.len;
    const vis = n.len;
    if (seg.color.len > 0) pos += cp(dest[pos..], "\x1b[0m");
    return .{ .bytes = pos, .visible = vis };
}

fn renderGitBranch(dest: []u8, seg: *const Segment, ctx: *const PromptContext) SegResult {
    if (ctx.git_branch.len == 0) return .{ .bytes = 0, .visible = 0 };
    var pos: usize = 0;
    pos += cp(dest[pos..], seg.color);
    pos += cp(dest[pos..], " ");
    pos += cp(dest[pos..], ctx.git_branch);
    const vis = 1 + ctx.git_branch.len;
    if (seg.color.len > 0) pos += cp(dest[pos..], "\x1b[0m");
    return .{ .bytes = pos, .visible = vis };
}

fn renderText(dest: []u8, seg: *const Segment) SegResult {
    var pos: usize = 0;
    if (seg.color.len > 0) pos += cp(dest[pos..], seg.color);
    const text = seg.text[0..seg.text_len];
    pos += cp(dest[pos..], text);
    const vis = text.len;
    if (seg.color.len > 0) pos += cp(dest[pos..], "\x1b[0m");
    return .{ .bytes = pos, .visible = vis };
}

fn renderLuaSegment(dest: []u8, seg: *const Segment, lua: lua_api.LuaState) SegResult {
    const c = lua_api.c;
    const state = lua orelse return .{ .bytes = 0, .visible = 0 };

    _ = c.lua_rawgeti(state, c.LUA_REGISTRYINDEX, seg.lua_ref);
    if (lua_api.pcall(state, 0, 1) != 0) {
        c.lua_settop(state, -(1) - 1);
        return .{ .bytes = 0, .visible = 0 };
    }

    const result = c.lua_tolstring(state, -1, null);
    if (result) |r| {
        const text = std.mem.span(r);
        const n = cp(dest, text);
        c.lua_settop(state, -(1) - 1);
        return .{ .bytes = n, .visible = n }; // Lua segments are assumed visible
    }
    c.lua_settop(state, -(1) - 1);
    return .{ .bytes = 0, .visible = 0 };
}

// ---------------------------------------------------------------------------
// Git branch detection (cheap — reads .git/HEAD only)
// ---------------------------------------------------------------------------

var git_branch_buf: [128]u8 = undefined;

fn readGitBranch() ?[]const u8 {
    // Walk up from cwd looking for .git/HEAD
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir = std.posix.getcwd(&path_buf) catch return null;

    while (true) {
        var head_path: [std.fs.max_path_bytes]u8 = undefined;
        const hp = std.fmt.bufPrint(&head_path, "{s}/.git/HEAD", .{dir}) catch return null;

        const file = std.fs.openFileAbsolute(hp, .{}) catch {
            // Go up one directory
            const sep = std.mem.lastIndexOf(u8, dir, "/") orelse return null;
            if (sep == 0) return null;
            dir = dir[0..sep];
            continue;
        };
        defer file.close();

        const n = file.read(&git_branch_buf) catch return null;
        const content = git_branch_buf[0..n];

        // "ref: refs/heads/main\n" → "main"
        const prefix = "ref: refs/heads/";
        if (std.mem.startsWith(u8, content, prefix)) {
            const rest = content[prefix.len..];
            const end = std.mem.indexOf(u8, rest, "\n") orelse rest.len;
            return rest[0..end];
        }

        // Detached HEAD — show short hash
        if (n >= 8) return content[0..8];
        return null;
    }
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "default config has segments" {
    const cfg = defaultConfig();
    try std.testing.expect(cfg.count > 0);
}

test "renderSymbol shows green on success" {
    var buf: [64]u8 = undefined;
    const ctx = PromptContext{ .last_exit_code = 0 };
    const result = renderSymbol(&buf, &ctx);
    try std.testing.expect(result.visible == 1);
    try std.testing.expect(result.bytes > 0);
}

test "renderJobs empty when no jobs" {
    var buf: [64]u8 = undefined;
    const seg = Segment{ .kind = .jobs, .color = "" };
    const ctx = PromptContext{ .job_count = 0 };
    const result = renderJobs(&buf, &seg, &ctx);
    try std.testing.expectEqual(@as(usize, 0), result.bytes);
}

test "renderDuration hidden under 1s" {
    var buf: [64]u8 = undefined;
    const ctx = PromptContext{ .last_duration_ms = 500 };
    const result = renderDuration(&buf, &ctx);
    try std.testing.expectEqual(@as(usize, 0), result.bytes);
}
