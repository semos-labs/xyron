// prompt.zig — Prompt engine with modular segments.
//
// Builds the prompt from a configurable sequence of segments, each
// producing styled text from runtime context. Supports Lua-defined
// segments and configuration. Falls back to a sensible default.

const std = @import("std");
const lua_api = @import("lua_api.zig");
const git_info_mod = @import("git_info.zig");
const style = @import("style.zig");
const powerline = @import("prompt_powerline.zig");

pub const MAX_PROMPT: usize = 4096;
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
    git: GitInfo = .{},
    vim_normal: bool = false, // true when in vim normal mode
};

pub const GitInfo = git_info_mod.GitInfo;

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
    xyron_project, // active xyron project name + status
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
    // Style — classic mode (raw ANSI string)
    color: []const u8 = "",
    // Style — powerline mode (structured colors, override `color` when set)
    fg_color: ?style.Color = null,
    bg_color: ?style.Color = null,
};

// ---------------------------------------------------------------------------
// Prompt configuration
// ---------------------------------------------------------------------------

pub const PromptConfig = struct {
    segments: [MAX_SEGMENTS]Segment = undefined,
    count: usize = 0,
    // Powerline separator glyph (e.g. , ). Empty = classic mode.
    separator: [16]u8 = undefined,
    separator_len: usize = 0,

    pub fn addBuiltin(self: *PromptConfig, kind: SegmentKind, color: []const u8) void {
        if (self.count >= MAX_SEGMENTS) return;
        self.segments[self.count] = .{ .kind = kind, .color = color };
        self.count += 1;
    }

    pub fn addStyledBuiltin(self: *PromptConfig, kind: SegmentKind, fg_color: ?style.Color, bg_color: ?style.Color) void {
        if (self.count >= MAX_SEGMENTS) return;
        self.segments[self.count] = .{ .kind = kind, .fg_color = fg_color, .bg_color = bg_color };
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

    pub fn addStyledText(self: *PromptConfig, literal: []const u8, fg_color: ?style.Color, bg_color: ?style.Color) void {
        if (self.count >= MAX_SEGMENTS) return;
        var seg = Segment{ .kind = .text, .fg_color = fg_color, .bg_color = bg_color };
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

    pub fn addStyledLua(self: *PromptConfig, ref: c_int, fg_color: ?style.Color, bg_color: ?style.Color) void {
        if (self.count >= MAX_SEGMENTS) return;
        self.segments[self.count] = .{ .kind = .lua_fn, .lua_ref = ref, .fg_color = fg_color, .bg_color = bg_color };
        self.count += 1;
    }

    pub fn setSeparator(self: *PromptConfig, sep: []const u8) void {
        const len = @min(sep.len, 16);
        @memcpy(self.separator[0..len], sep[0..len]);
        self.separator_len = len;
    }

    pub fn isPowerline(self: *const PromptConfig) bool {
        return self.separator_len > 0;
    }

    pub fn getSeparator(self: *const PromptConfig) []const u8 {
        return self.separator[0..self.separator_len];
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

// ---------------------------------------------------------------------------
// Widget configuration store
// ---------------------------------------------------------------------------

/// Git widget icons/labels — configurable via xyron.prompt.configure("git", {...})
pub const GitWidgetConfig = struct {
    icon_branch: [16]u8 = undefined,
    icon_branch_len: usize = 0,
    icon_staged: [8]u8 = undefined,
    icon_staged_len: usize = 0,
    icon_modified: [8]u8 = undefined,
    icon_modified_len: usize = 0,
    icon_deleted: [8]u8 = undefined,
    icon_deleted_len: usize = 0,
    icon_untracked: [8]u8 = undefined,
    icon_untracked_len: usize = 0,
    icon_conflicts: [8]u8 = undefined,
    icon_conflicts_len: usize = 0,
    icon_ahead: [8]u8 = undefined,
    icon_ahead_len: usize = 0,
    icon_behind: [8]u8 = undefined,
    icon_behind_len: usize = 0,
    icon_clean: [8]u8 = undefined,
    icon_clean_len: usize = 0,
    icon_lines_added: [8]u8 = undefined,
    icon_lines_added_len: usize = 0,
    icon_lines_removed: [8]u8 = undefined,
    icon_lines_removed_len: usize = 0,

    // Visibility toggles (all default to true)
    show_staged: bool = true,
    show_modified: bool = true,
    show_deleted: bool = true,
    show_untracked: bool = true,
    show_conflicts: bool = true,
    show_ahead_behind: bool = true,
    show_loc: bool = true,
    show_clean: bool = true,
    show_state: bool = true, // rebase/merge/cherry-pick

    pub fn getIcon(_: *const GitWidgetConfig, buf: []const u8, len: usize, default: []const u8) []const u8 {
        return if (len > 0) buf[0..len] else default;
    }
};

var git_widget_config: GitWidgetConfig = .{};

pub fn getGitWidgetConfig() *const GitWidgetConfig {
    return &git_widget_config;
}

pub fn setGitWidgetConfig(cfg: GitWidgetConfig) void {
    git_widget_config = cfg;
}

/// Cwd widget config — configurable via xyron.prompt.configure("cwd", {...})
pub const CwdWidgetConfig = struct {
    /// When > 0, show only the last N path components.
    truncate: u8 = 0, // 0 = no truncation
};

var cwd_widget_config: CwdWidgetConfig = .{};

pub fn getCwdWidgetConfig() *const CwdWidgetConfig {
    return &cwd_widget_config;
}

pub fn setCwdWidgetConfig(cfg: CwdWidgetConfig) void {
    cwd_widget_config = cfg;
}

/// Symbol widget config — configurable via xyron.prompt.configure("symbol", {...})
pub const SymbolWidgetConfig = struct {
    icon: [16]u8 = undefined,
    icon_len: usize = 0,
    icon_vim: [16]u8 = undefined,
    icon_vim_len: usize = 0,
};

var symbol_widget_config: SymbolWidgetConfig = .{};

pub fn getSymbolWidgetConfig() *const SymbolWidgetConfig {
    return &symbol_widget_config;
}

pub fn setSymbolWidgetConfig(cfg: SymbolWidgetConfig) void {
    symbol_widget_config = cfg;
}

/// Custom widget registry — Lua functions registered via xyron.prompt.register()
const MAX_CUSTOM_WIDGETS = 16;
var custom_widget_names: [MAX_CUSTOM_WIDGETS][64]u8 = undefined;
var custom_widget_name_lens: [MAX_CUSTOM_WIDGETS]usize = .{0} ** MAX_CUSTOM_WIDGETS;
var custom_widget_refs: [MAX_CUSTOM_WIDGETS]c_int = .{0} ** MAX_CUSTOM_WIDGETS;
var custom_widget_count: usize = 0;

pub fn registerCustomWidget(name: []const u8, ref: c_int) void {
    if (custom_widget_count >= MAX_CUSTOM_WIDGETS) return;
    const len = @min(name.len, 64);
    @memcpy(custom_widget_names[custom_widget_count][0..len], name[0..len]);
    custom_widget_name_lens[custom_widget_count] = len;
    custom_widget_refs[custom_widget_count] = ref;
    custom_widget_count += 1;
}

pub fn findCustomWidget(name: []const u8) ?c_int {
    for (0..custom_widget_count) |i| {
        if (std.mem.eql(u8, custom_widget_names[i][0..custom_widget_name_lens[i]], name)) {
            return custom_widget_refs[i];
        }
    }
    return null;
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
    ctx.git = git_info_mod.read();
    ctx.git_branch = ctx.git.branch;

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

        if (cfg.isPowerline()) {
            const r = powerline.renderLine(buf[pos..], cfg, cfg.segments[line_start..line_end], has_spacer, term_w, ctx, lua);
            pos += r.bytes;
            visible_len += r.visible;
        } else if (has_spacer) {
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
    return style.getTermSize(std.posix.STDOUT_FILENO).cols;
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

pub const SegResult = struct { bytes: usize, visible: usize };

pub fn renderSegment(dest: []u8, seg: *const Segment, ctx: *const PromptContext, lua: lua_api.LuaState) SegResult {
    return switch (seg.kind) {
        .cwd => renderCwd(dest, seg, ctx),
        .symbol => renderSymbol(dest, ctx),
        .status => renderStatus(dest, ctx),
        .duration => renderDuration(dest, ctx),
        .jobs => renderJobs(dest, seg, ctx),
        .git_branch => renderGitBranch(dest, seg, ctx),
        .xyron_project => renderXyronProject(dest),
        .newline => renderNewline(dest),
        .spacer => .{ .bytes = 0, .visible = 0 }, // handled by render()
        .text => renderText(dest, seg),
        .lua_fn => renderLuaSegment(dest, seg, lua),
    };
}

fn renderNewline(dest: []u8) SegResult {
    // Use \r\n in raw mode (OPOST disabled)
    const n = style.crlf(dest);
    return .{ .bytes = n, .visible = 0 };
}

fn renderCwd(dest: []u8, seg: *const Segment, ctx: *const PromptContext) SegResult {
    var pos: usize = 0;
    pos += cp(dest[pos..], seg.color);
    const vis_start = pos;

    // Tilde contraction
    var path: []const u8 = ctx.cwd;
    var tilde = false;
    if (ctx.home.len > 0 and std.mem.eql(u8, ctx.cwd, ctx.home)) {
        path = "~";
        tilde = true;
    } else if (ctx.home.len > 0 and std.mem.startsWith(u8, ctx.cwd, ctx.home) and ctx.cwd.len > ctx.home.len and ctx.cwd[ctx.home.len] == '/') {
        path = ctx.cwd[ctx.home.len..]; // "/foo/bar" portion after home
        tilde = true;
    }

    // Apply truncation — show only the last N components, no prefix
    const cfg = getCwdWidgetConfig();
    if (cfg.truncate > 0 and !std.mem.eql(u8, path, "~")) {
        const display = truncatePath(path, cfg.truncate);
        pos += cp(dest[pos..], display);
    } else {
        if (tilde) pos += cp(dest[pos..], "~");
        if (!tilde or !std.mem.eql(u8, path, "~")) pos += cp(dest[pos..], path);
    }

    const vis_end = pos;
    if (seg.color.len > 0) pos += style.reset(dest[pos..]);
    return .{ .bytes = pos, .visible = vis_end - vis_start };
}

/// Return the last N path components from a path string.
/// E.g. truncatePath("/foo/bar/baz/qux", 2) returns "baz/qux".
fn truncatePath(path: []const u8, n: u8) []const u8 {
    if (n == 0 or path.len == 0) return path;
    var count: u8 = 0;
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') {
            count += 1;
            if (count >= n) return path[i + 1 ..];
        }
    }
    // Fewer components than n — return the whole path (strip leading /)
    return if (path[0] == '/') path[1..] else path;
}

fn renderSymbol(dest: []u8, ctx: *const PromptContext) SegResult {
    var pos: usize = 0;
    const cfg = getSymbolWidgetConfig();
    const symbol: []const u8 = if (ctx.vim_normal)
        (if (cfg.icon_vim_len > 0) cfg.icon_vim[0..cfg.icon_vim_len] else "<")
    else
        (if (cfg.icon_len > 0) cfg.icon[0..cfg.icon_len] else ">");
    if (ctx.last_exit_code != 0) {
        pos += style.boldFg(dest[pos..], .red);
    } else {
        pos += if (ctx.vim_normal) style.boldFg(dest[pos..], .yellow) else style.boldFg(dest[pos..], .green);
    }
    pos += cp(dest[pos..], symbol);
    const vis = visLen(symbol);
    pos += style.reset(dest[pos..]);
    return .{ .bytes = pos, .visible = vis };
}

fn renderStatus(dest: []u8, ctx: *const PromptContext) SegResult {
    if (ctx.last_exit_code == 0) return .{ .bytes = 0, .visible = 0 };
    var pos: usize = 0;
    pos += style.fg(dest[pos..], .red);
    const n = std.fmt.bufPrint(dest[pos..], "✘{d}", .{ctx.last_exit_code}) catch return .{ .bytes = 0, .visible = 0 };
    pos += n.len;
    const vis = n.len;
    pos += style.reset(dest[pos..]);
    pos += cp(dest[pos..], " ");
    return .{ .bytes = pos, .visible = vis + 1 };
}

fn renderDuration(dest: []u8, ctx: *const PromptContext) SegResult {
    if (ctx.last_duration_ms < 500) return .{ .bytes = 0, .visible = 0 };
    var pos: usize = 0;
    pos += style.dimFg(dest[pos..], .yellow); // dim yellow
    var fmt_buf: [32]u8 = undefined;
    const dur = formatDuration(&fmt_buf, ctx.last_duration_ms);
    const n = std.fmt.bufPrint(dest[pos..], "{s} ", .{dur}) catch return .{ .bytes = 0, .visible = 0 };
    pos += n.len;
    const vis = n.len;
    pos += style.reset(dest[pos..]);
    return .{ .bytes = pos, .visible = vis };
}

/// Format a duration in ms to human-readable: 230ms, 1.2s, 2m30s, 1h5m
pub fn formatDuration(buf: []u8, ms: i64) []const u8 {
    if (ms < 1000) {
        return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch "?";
    }
    const total_secs = @divTrunc(ms, 1000);
    if (total_secs < 60) {
        const frac = @divTrunc(@mod(ms, 1000), 100);
        if (frac > 0) {
            return std.fmt.bufPrint(buf, "{d}.{d}s", .{ total_secs, frac }) catch "?";
        }
        return std.fmt.bufPrint(buf, "{d}s", .{total_secs}) catch "?";
    }
    const mins = @divTrunc(total_secs, 60);
    const secs = @mod(total_secs, 60);
    if (mins < 60) {
        if (secs > 0) {
            return std.fmt.bufPrint(buf, "{d}m{d}s", .{ mins, secs }) catch "?";
        }
        return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "?";
    }
    const hrs = @divTrunc(mins, 60);
    const rm = @mod(mins, 60);
    return std.fmt.bufPrint(buf, "{d}h{d}m", .{ hrs, rm }) catch "?";
}

fn renderJobs(dest: []u8, seg: *const Segment, ctx: *const PromptContext) SegResult {
    if (ctx.job_count == 0) return .{ .bytes = 0, .visible = 0 };
    var pos: usize = 0;
    pos += cp(dest[pos..], seg.color);
    const n = std.fmt.bufPrint(dest[pos..], " ⚙{d}", .{ctx.job_count}) catch return .{ .bytes = 0, .visible = 0 };
    pos += n.len;
    const vis = n.len;
    if (seg.color.len > 0) pos += style.reset(dest[pos..]);
    return .{ .bytes = pos, .visible = vis };
}

fn renderGitBranch(dest: []u8, seg: *const Segment, ctx: *const PromptContext) SegResult {
    const g = &ctx.git;
    if (g.branch.len == 0) return .{ .bytes = 0, .visible = 0 };
    const wcfg = getGitWidgetConfig();
    var pos: usize = 0;
    var vis: usize = 0;

    // Branch icon + name (+ worktree)
    pos += cp(dest[pos..], seg.color);
    const branch_icon = wcfg.getIcon(&wcfg.icon_branch, wcfg.icon_branch_len, "");
    if (branch_icon.len > 0) {
        pos += cp(dest[pos..], " ");
        vis += 1;
        pos += cp(dest[pos..], branch_icon);
        vis += visLen(branch_icon);
        pos += cp(dest[pos..], " ");
        vis += 1;
    } else {
        pos += cp(dest[pos..], " ");
        vis += 1;
    }
    pos += cp(dest[pos..], g.branch);
    vis += g.branch.len;
    // Worktree: show as branch:worktree-name
    if (g.is_worktree and g.worktree_name.len > 0) {
        pos += style.dim(dest[pos..]);
        pos += cp(dest[pos..], ":");
        pos += style.undim(dest[pos..]);
        vis += 1;
        pos += cp(dest[pos..], g.worktree_name);
        vis += g.worktree_name.len;
    }
    if (seg.color.len > 0) pos += style.reset(dest[pos..]);

    // State indicators (rebase/merge/cherry-pick)
    if (wcfg.show_state) {
        if (g.is_rebasing) { const r = appendState(dest[pos..], "|REBASE"); pos += r.bytes; vis += r.visible; }
        else if (g.is_merging) { const r = appendState(dest[pos..], "|MERGE"); pos += r.bytes; vis += r.visible; }
        else if (g.is_cherry_picking) { const r = appendState(dest[pos..], "|PICK"); pos += r.bytes; vis += r.visible; }
    }

    // Ahead/behind
    if (wcfg.show_ahead_behind and (g.ahead > 0 or g.behind > 0)) {
        if (g.ahead > 0) {
            pos += cp(dest[pos..], " "); vis += 1;
            const icon = wcfg.getIcon(&wcfg.icon_ahead, wcfg.icon_ahead_len, "\xe2\x87\xa1");
            const r = appendIndicator(dest[pos..], .green, icon, g.ahead);
            pos += r.bytes; vis += r.visible;
        }
        if (g.behind > 0) {
            pos += cp(dest[pos..], " "); vis += 1;
            const icon = wcfg.getIcon(&wcfg.icon_behind, wcfg.icon_behind_len, "\xe2\x87\xa3");
            const r = appendIndicator(dest[pos..], .red, icon, g.behind);
            pos += r.bytes; vis += r.visible;
        }
    }

    // File status
    var has_visible_status = false;
    if (wcfg.show_conflicts and g.conflicts > 0) {
        pos += cp(dest[pos..], " "); vis += 1;
        has_visible_status = true;
        const icon = wcfg.getIcon(&wcfg.icon_conflicts, wcfg.icon_conflicts_len, "\xe2\x9c\x96");
        const r = appendIndicatorBold(dest[pos..], .red, icon, g.conflicts);
        pos += r.bytes; vis += r.visible;
    }
    if (wcfg.show_staged and g.staged > 0) {
        pos += cp(dest[pos..], " "); vis += 1;
        has_visible_status = true;
        const icon = wcfg.getIcon(&wcfg.icon_staged, wcfg.icon_staged_len, "+");
        const r = appendIndicator(dest[pos..], .green, icon, g.staged);
        pos += r.bytes; vis += r.visible;
    }
    if (wcfg.show_modified and g.modified > 0) {
        pos += cp(dest[pos..], " "); vis += 1;
        has_visible_status = true;
        const icon = wcfg.getIcon(&wcfg.icon_modified, wcfg.icon_modified_len, "~");
        const r = appendIndicator(dest[pos..], .yellow, icon, g.modified);
        pos += r.bytes; vis += r.visible;
    }
    if (wcfg.show_deleted and g.deleted > 0) {
        pos += cp(dest[pos..], " "); vis += 1;
        has_visible_status = true;
        const icon = wcfg.getIcon(&wcfg.icon_deleted, wcfg.icon_deleted_len, "-");
        const r = appendIndicator(dest[pos..], .red, icon, g.deleted);
        pos += r.bytes; vis += r.visible;
    }
    if (wcfg.show_untracked and g.untracked > 0) {
        pos += cp(dest[pos..], " "); vis += 1;
        has_visible_status = true;
        const icon = wcfg.getIcon(&wcfg.icon_untracked, wcfg.icon_untracked_len, "?");
        const r = appendIndicatorDim(dest[pos..], icon, g.untracked);
        pos += r.bytes; vis += r.visible;
    }

    // Clean indicator (only when no visible status)
    if (!has_visible_status and wcfg.show_clean and g.branch.len > 0) {
        const clean_icon = wcfg.getIcon(&wcfg.icon_clean, wcfg.icon_clean_len, "");
        if (clean_icon.len > 0) {
            pos += cp(dest[pos..], " "); vis += 1;
            pos += style.fg(dest[pos..], .green);
            pos += cp(dest[pos..], clean_icon);
            vis += visLen(clean_icon);
            pos += style.reset(dest[pos..]);
        }
    }

    // Lines added/removed
    if (wcfg.show_loc) {
        if (g.lines_added > 0) {
            pos += cp(dest[pos..], " "); vis += 1;
            const icon = wcfg.getIcon(&wcfg.icon_lines_added, wcfg.icon_lines_added_len, "+");
            const r = appendIndicator(dest[pos..], .green, icon, g.lines_added);
            pos += r.bytes; vis += r.visible;
        }
        if (g.lines_removed > 0) {
            pos += cp(dest[pos..], " "); vis += 1;
            const icon = wcfg.getIcon(&wcfg.icon_lines_removed, wcfg.icon_lines_removed_len, "-");
            const r = appendIndicator(dest[pos..], .red, icon, g.lines_removed);
            pos += r.bytes; vis += r.visible;
        }
    }

    return .{ .bytes = pos, .visible = vis };
}

fn appendState(dest: []u8, label: []const u8) SegResult {
    var pos: usize = 0;
    pos += style.fg(dest[pos..], .yellow);
    pos += cp(dest[pos..], label);
    pos += style.reset(dest[pos..]);
    return .{ .bytes = pos, .visible = label.len };
}

fn appendIndicator(dest: []u8, color: style.Color, icon: []const u8, count: usize) SegResult {
    var pos: usize = 0;
    pos += style.fg(dest[pos..], color);
    pos += cp(dest[pos..], icon);
    pos += cp(dest[pos..], " ");
    const num = std.fmt.bufPrint(dest[pos..], "{d}", .{count}) catch "";
    pos += num.len;
    pos += style.reset(dest[pos..]);
    return .{ .bytes = pos, .visible = visLen(icon) + 1 + num.len };
}

fn appendIndicatorBold(dest: []u8, color: style.Color, icon: []const u8, count: usize) SegResult {
    var pos: usize = 0;
    pos += style.boldFg(dest[pos..], color);
    pos += cp(dest[pos..], icon);
    pos += cp(dest[pos..], " ");
    const num = std.fmt.bufPrint(dest[pos..], "{d}", .{count}) catch "";
    pos += num.len;
    pos += style.reset(dest[pos..]);
    return .{ .bytes = pos, .visible = visLen(icon) + 1 + num.len };
}

fn appendIndicatorDim(dest: []u8, icon: []const u8, count: usize) SegResult {
    var pos: usize = 0;
    pos += style.dim(dest[pos..]);
    pos += cp(dest[pos..], icon);
    pos += cp(dest[pos..], " ");
    const num = std.fmt.bufPrint(dest[pos..], "{d}", .{count}) catch "";
    pos += num.len;
    pos += style.reset(dest[pos..]);
    return .{ .bytes = pos, .visible = visLen(icon) + 1 + num.len };
}

/// Visible width of a string that may contain ANSI escapes.
fn visLenAnsi(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            // Skip CSI sequence: ESC [ ... final_byte
            i += 2;
            while (i < s.len and s[i] < 0x40) : (i += 1) {}
            if (i < s.len) i += 1; // skip final byte
        } else if (s[i] < 0x80) { i += 1; n += 1; }
        else if (s[i] < 0xE0) { i += 2; n += 1; }
        else if (s[i] < 0xF0) { i += 3; n += 1; }
        else { i += 4; n += 1; }
    }
    return n;
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

fn renderXyronProject(dest: []u8) SegResult {
    const info = lua_api.getProjectInfo();
    if (info.status == .none) return .{ .bytes = 0, .visible = 0 };

    var pos: usize = 0;
    var vis: usize = 0;

    if (info.status == .invalid) {
        // Red indicator for invalid project
        pos += style.fg(dest[pos..], .red);
        pos += cp(dest[pos..], "\xe2\x9c\x97 "); // ✗
        vis += 2;
        const name = info.name[0..info.name_len];
        pos += cp(dest[pos..], name);
        vis += visLen(name);
        pos += style.reset(dest[pos..]);
        return .{ .bytes = pos, .visible = vis };
    }

    // Valid project: icon + name
    pos += style.fg(dest[pos..], .cyan);
    pos += cp(dest[pos..], "\xe2\x97\x86 "); // ◆
    vis += 2;
    const name = info.name[0..info.name_len];
    pos += cp(dest[pos..], name);
    vis += visLen(name);
    pos += style.reset(dest[pos..]);

    // Missing secrets indicator
    if (info.missing_secrets > 0) {
        pos += cp(dest[pos..], " ");
        vis += 1;
        pos += style.fg(dest[pos..], .red);
        const n = std.fmt.bufPrint(dest[pos..], "\xe2\x9c\x97{d}", .{info.missing_secrets}) catch "";
        pos += n.len;
        vis += visLen(n);
        pos += style.reset(dest[pos..]);
    }

    return .{ .bytes = pos, .visible = vis };
}

fn renderText(dest: []u8, seg: *const Segment) SegResult {
    var pos: usize = 0;
    if (seg.color.len > 0) pos += cp(dest[pos..], seg.color);
    const text = seg.text[0..seg.text_len];
    pos += cp(dest[pos..], text);
    const vis = text.len;
    if (seg.color.len > 0) pos += style.reset(dest[pos..]);
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
        return .{ .bytes = n, .visible = visLenAnsi(text) };
    }
    c.lua_settop(state, -(1) - 1);
    return .{ .bytes = 0, .visible = 0 };
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

test "renderDuration hidden under 500ms" {
    var buf: [64]u8 = undefined;
    const ctx = PromptContext{ .last_duration_ms = 200 };
    const result = renderDuration(&buf, &ctx);
    try std.testing.expectEqual(@as(usize, 0), result.bytes);
}

test "renderDuration shows for 500ms+" {
    var buf: [64]u8 = undefined;
    const ctx = PromptContext{ .last_duration_ms = 750 };
    const result = renderDuration(&buf, &ctx);
    try std.testing.expect(result.bytes > 0);
}

test "powerline config" {
    var cfg = PromptConfig{};
    try std.testing.expect(!cfg.isPowerline());
    cfg.setSeparator("\xee\x80\xb0"); // U+E0B0
    try std.testing.expect(cfg.isPowerline());
    try std.testing.expectEqualStrings("\xee\x80\xb0", cfg.getSeparator());
}

test "addStyledBuiltin sets colors" {
    var cfg = PromptConfig{};
    cfg.addStyledBuiltin(.cwd, .white, .blue);
    try std.testing.expect(cfg.count == 1);
    try std.testing.expect(cfg.segments[0].fg_color.? == .white);
    try std.testing.expect(cfg.segments[0].bg_color.? == .blue);
}
