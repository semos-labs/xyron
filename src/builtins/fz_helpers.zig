// fz_helpers.zig — Helper functions for the fz fuzzy finder.
//
// Extracted from fz.zig to keep files under 600 lines.
// Contains: file collection, preview loading, text rendering helpers.

const std = @import("std");
const posix = std.posix;
const style = @import("../style.zig");

pub const MAX_ITEMS: usize = 8192;
pub const MAX_LINE: usize = 512;

// ---------------------------------------------------------------------------
// Item storage
// ---------------------------------------------------------------------------

pub const ItemList = struct {
    bufs: [MAX_ITEMS][MAX_LINE]u8 = undefined,
    lens: [MAX_ITEMS]usize = undefined,
    count: usize = 0,

    pub fn add(self: *ItemList, text: []const u8) void {
        if (self.count >= MAX_ITEMS) return;
        const l = @min(text.len, MAX_LINE);
        @memcpy(self.bufs[self.count][0..l], text[0..l]);
        self.lens[self.count] = l;
        self.count += 1;
    }

    pub fn get(self: *const ItemList, idx: usize) []const u8 {
        return self.bufs[idx][0..self.lens[idx]];
    }
};

// ---------------------------------------------------------------------------
// File collection
// ---------------------------------------------------------------------------

pub fn collectFiles(dir_path: []const u8, items: *ItemList, depth: usize) void {
    if (depth > 8 or items.count >= MAX_ITEMS) return;

    var dir = if (dir_path[0] == '/')
        std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return
    else
        std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (items.count >= MAX_ITEMS) return;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
        if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;
        if (std.mem.eql(u8, entry.name, "target")) continue;

        var path_buf: [MAX_LINE]u8 = undefined;
        var pl: usize = 0;
        if (!std.mem.eql(u8, dir_path, ".")) {
            const dl = @min(dir_path.len, MAX_LINE);
            @memcpy(path_buf[0..dl], dir_path[0..dl]);
            pl = dl;
            if (pl < MAX_LINE) { path_buf[pl] = '/'; pl += 1; }
        }
        const nl = @min(entry.name.len, MAX_LINE - pl);
        @memcpy(path_buf[pl..][0..nl], entry.name[0..nl]);
        pl += nl;

        items.add(path_buf[0..pl]);

        if (entry.kind == .directory) {
            collectFiles(path_buf[0..pl], items, depth + 1);
        }
    }
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

pub fn loadPreview(
    item: []const u8,
    custom_cmd: ?[]const u8,
    preview_buf: *[4096]u8,
    lines: *[64][]const u8,
) usize {
    if (custom_cmd) |cmd_template| {
        var cmd_buf: [1024]u8 = undefined;
        var cl: usize = 0;
        var i: usize = 0;
        while (i < cmd_template.len) {
            if (i + 1 < cmd_template.len and cmd_template[i] == '{' and cmd_template[i + 1] == '}') {
                const n = @min(item.len, cmd_buf.len - cl);
                @memcpy(cmd_buf[cl..][0..n], item[0..n]);
                cl += n;
                i += 2;
            } else {
                if (cl < cmd_buf.len) { cmd_buf[cl] = cmd_template[i]; cl += 1; }
                i += 1;
            }
        }
        return runPreviewCmd(cmd_buf[0..cl], preview_buf, lines);
    }

    const file = std.fs.cwd().openFile(item, .{}) catch return 0;
    defer file.close();
    const n = file.read(preview_buf) catch return 0;
    if (n == 0) return 0;

    const check = @min(n, 512);
    for (preview_buf[0..check]) |ch| {
        if (ch == 0) { lines[0] = "[binary file]"; return 1; }
    }

    var count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, preview_buf[0..n], '\n');
    while (line_iter.next()) |line| {
        if (count >= 64) break;
        lines[count] = line;
        count += 1;
    }
    return count;
}

fn runPreviewCmd(cmd: []const u8, preview_buf: *[4096]u8, lines: *[64][]const u8) usize {
    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", cmd },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;

    var total: usize = 0;
    if (child.stdout) |f| {
        while (total < preview_buf.len) {
            const n = f.read(preview_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    _ = child.wait() catch {};

    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, preview_buf[0..total], '\n');
    while (iter.next()) |line| {
        if (count >= 64) break;
        lines[count] = line;
        count += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Rendering helpers
// ---------------------------------------------------------------------------

/// Render highlighted text into a raw ANSI buffer (used by inline mode).
pub fn renderHighlightedText(
    buf: []u8,
    pos: *usize,
    text: []const u8,
    max_len: usize,
    positions: []const u8,
    match_count: u8,
    base_color: []const u8,
    highlight_color: []const u8,
) void {
    const len = @min(text.len, max_len);
    var in_highlight = false;

    for (0..len) |ci| {
        var is_match = false;
        for (0..match_count) |mi| {
            if (positions[mi] == ci) { is_match = true; break; }
        }

        if (is_match and !in_highlight) {
            pos.* += cp(buf[pos.*..], highlight_color);
            in_highlight = true;
        } else if (!is_match and in_highlight) {
            pos.* += cp(buf[pos.*..], "\x1b[0m");
            pos.* += cp(buf[pos.*..], base_color);
            in_highlight = false;
        }

        if (pos.* < buf.len) { buf[pos.*] = text[ci]; pos.* += 1; }
    }

    if (in_highlight) pos.* += cp(buf[pos.*..], "\x1b[0m");
}

pub fn fileColorEnum(path: []const u8) ?style.Color {
    if (path.len > 0 and path[path.len - 1] == '/') return .blue;
    if (std.mem.endsWith(u8, path, ".zig")) return .yellow;
    if (std.mem.endsWith(u8, path, ".lua")) return .magenta;
    if (std.mem.endsWith(u8, path, ".md")) return .cyan;
    if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".toml") or
        std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) return .green;
    if (std.mem.endsWith(u8, path, ".sh") or std.mem.endsWith(u8, path, ".bash") or
        std.mem.endsWith(u8, path, ".py") or std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".jsx")) return .yellow;
    if (std.mem.endsWith(u8, path, ".rs") or std.mem.endsWith(u8, path, ".html")) return .red;
    if (std.mem.endsWith(u8, path, ".go") or std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".tsx")) return .cyan;
    if (std.mem.endsWith(u8, path, ".css") or std.mem.endsWith(u8, path, ".scss")) return .magenta;
    return .white;
}

/// Case-insensitive exact substring match.
pub fn exactContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (0..needle.len) |j| {
            const h = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z') haystack[i + j] + 32 else haystack[i + j];
            const n = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (h != n) { matched = false; break; }
        }
        if (matched) return true;
    }
    return false;
}

pub fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

pub fn getTermSize(fd: posix.fd_t) struct { rows: usize, cols: usize } {
    const ts = style.getTermSize(fd);
    return .{ .rows = ts.rows, .cols = ts.cols };
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    multi: bool = false,
    inline_mode: bool = false,
    preview: bool = false,
    preview_cmd: ?[]const u8 = null,
    query: ?[]const u8 = null,
    prompt: []const u8 = "> ",
    header: ?[]const u8 = null,
    header_lines: usize = 0,
    exact: bool = false,
    print0: bool = false,
    reverse: bool = false,
    height: ?usize = null,
};

pub fn parseOptions(args: []const []const u8) Options {
    var opts = Options{};
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--multi") or std.mem.eql(u8, arg, "-m")) {
            opts.multi = true;
        } else if (std.mem.eql(u8, arg, "--inline") or std.mem.eql(u8, arg, "-i")) {
            opts.inline_mode = true;
        } else if (std.mem.eql(u8, arg, "--preview") or std.mem.eql(u8, arg, "-p")) {
            opts.preview = true;
        } else if (std.mem.eql(u8, arg, "--preview-cmd") and i + 1 < args.len) {
            opts.preview = true;
            i += 1;
            opts.preview_cmd = args[i];
        } else if ((std.mem.eql(u8, arg, "--query") or std.mem.eql(u8, arg, "-q")) and i + 1 < args.len) {
            i += 1;
            opts.query = args[i];
        } else if (std.mem.eql(u8, arg, "--prompt") and i + 1 < args.len) {
            i += 1;
            opts.prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--header") and i + 1 < args.len) {
            i += 1;
            opts.header = args[i];
        } else if (std.mem.eql(u8, arg, "--header-lines") and i + 1 < args.len) {
            i += 1;
            opts.header_lines = std.fmt.parseInt(usize, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--exact") or std.mem.eql(u8, arg, "-e")) {
            opts.exact = true;
        } else if (std.mem.eql(u8, arg, "--print0") or std.mem.eql(u8, arg, "-0")) {
            opts.print0 = true;
        } else if (std.mem.eql(u8, arg, "--reverse")) {
            opts.reverse = true;
        } else if (std.mem.eql(u8, arg, "--height") and i + 1 < args.len) {
            i += 1;
            opts.height = std.fmt.parseInt(usize, args[i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
        }
        i += 1;
    }
    return opts;
}

pub fn printHelp() void {
    const stderr = std.fs.File.stderr();
    stderr.writeAll(
        \\fz — fuzzy finder
        \\
        \\Usage:
        \\  fz [options]              Find files in current directory
        \\  ... | fz [options]        Pick from piped input
        \\
        \\Options:
        \\  -q, --query STRING        Start with query pre-filled
        \\  --prompt STRING           Custom prompt (default: "> ")
        \\  --header STRING           Header text above the list
        \\  --header-lines N          Treat first N input lines as header
        \\  -e, --exact               Exact substring match (not fuzzy)
        \\  -m, --multi               Enable multi-select (Tab to toggle)
        \\  -p, --preview             Show file preview (right pane)
        \\  --preview-cmd "cmd {}"    Custom preview command ({} = selected item)
        \\  -i, --inline              Inline mode (no alternate screen)
        \\  -0, --print0              NUL-terminated output
        \\  --reverse                 Top-down layout (prompt at top)
        \\  --height N                Limit to N rows
        \\  -h, --help                Show this help
        \\
        \\Keys:
        \\  Up/Down                   Navigate
        \\  Tab / Shift-Tab           Toggle selection (multi-select)
        \\  Enter                     Confirm selection
        \\  Escape / Ctrl+C           Cancel (exit code 1)
        \\  Type to filter            Fuzzy search
        \\
    ) catch {};
}
