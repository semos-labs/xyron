// attyx_bridge.zig — Native Attyx UI bridge.
//
// Invokes Attyx IPC commands (via the `attyx` CLI) to provide native
// UI primitives: picker, popup, inspector. Falls back to terminal-
// friendly alternatives when Attyx is not available.

const std = @import("std");
const posix = std.posix;

/// Whether Attyx native UI is available.
pub fn isAvailable() bool {
    const val = posix.getenv("ATTYX") orelse return false;
    return std.mem.eql(u8, val, "1");
}

// ---------------------------------------------------------------------------
// Picker — show a list of items, return selected
// ---------------------------------------------------------------------------

pub const PickerItem = struct {
    label: []const u8,
    description: []const u8 = "",
    value: []const u8 = "", // if empty, label is used as value
};

pub const PickerResult = struct {
    selected: ?[]const u8 = null, // null if cancelled
    buf: [1024]u8 = undefined, // backing storage
};

/// Open a native Attyx picker popup, or fall back to terminal.
pub fn picker(
    items: []const PickerItem,
    title: []const u8,
    stdout: std.fs.File,
    allocator: std.mem.Allocator,
) PickerResult {
    if (isAvailable()) {
        return attyxPicker(items, title, allocator);
    }
    return terminalPicker(items, title, stdout);
}

fn attyxPicker(items: []const PickerItem, title: []const u8, allocator: std.mem.Allocator) PickerResult {
    var result = PickerResult{};

    // Write items to a temp file for fzf
    const tmp_path = "/tmp/xyron-picker.txt";
    const out_path = "/tmp/xyron-picker-result.txt";

    {
        var file = std.fs.createFileAbsolute(tmp_path, .{}) catch return result;
        defer file.close();
        for (items) |item| {
            file.writeAll(item.label) catch {};
            if (item.description.len > 0) {
                file.writeAll("\t") catch {};
                file.writeAll(item.description) catch {};
            }
            file.writeAll("\n") catch {};
        }
    }

    // Build popup command: fzf reading from temp file, writing to result file
    var cmd_buf: [1024]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf,
        "cat {s} | fzf --prompt='{s}> ' --height=100% --layout=reverse | cut -f1 > {s}",
        .{ tmp_path, title, out_path },
    ) catch return result;

    // Run attyx popup
    var child = std.process.Child.init(
        &.{ "attyx", "popup", cmd, "--width", "60", "--height", "40" },
        allocator,
    );
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return result;
    _ = child.wait() catch return result;

    // Read result
    var file = std.fs.openFileAbsolute(out_path, .{}) catch return result;
    defer file.close();
    const n = file.read(&result.buf) catch return result;
    if (n > 0) {
        const trimmed = std.mem.trim(u8, result.buf[0..n], " \t\n\r");
        if (trimmed.len > 0) result.selected = trimmed;
    }

    // Clean up
    std.fs.deleteFileAbsolute(tmp_path) catch {};
    std.fs.deleteFileAbsolute(out_path) catch {};

    return result;
}

fn terminalPicker(items: []const PickerItem, title: []const u8, stdout: std.fs.File) PickerResult {
    var result = PickerResult{};

    // Simple numbered list fallback
    stdout.writeAll(title) catch {};
    stdout.writeAll(":\n") catch {};

    for (items, 0..) |item, i| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "  {d}) {s}", .{ i + 1, item.label }) catch continue;
        stdout.writeAll(msg) catch {};
        if (item.description.len > 0) {
            stdout.writeAll("  ") catch {};
            stdout.writeAll(item.description) catch {};
        }
        stdout.writeAll("\n") catch {};
    }

    // Read number from stdin
    stdout.writeAll("Select [1-") catch {};
    var nbuf: [8]u8 = undefined;
    const nstr = std.fmt.bufPrint(&nbuf, "{d}", .{items.len}) catch return result;
    stdout.writeAll(nstr) catch {};
    stdout.writeAll("]: ") catch {};

    var input_buf: [16]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &input_buf) catch return result;
    const trimmed = std.mem.trim(u8, input_buf[0..n], " \t\n\r");
    const idx = std.fmt.parseInt(usize, trimmed, 10) catch return result;
    if (idx >= 1 and idx <= items.len) {
        const label = items[idx - 1].label;
        const val = if (items[idx - 1].value.len > 0) items[idx - 1].value else label;
        @memcpy(result.buf[0..val.len], val);
        result.selected = result.buf[0..val.len];
    }

    return result;
}

// ---------------------------------------------------------------------------
// Popup — show content in a floating window
// ---------------------------------------------------------------------------

/// Open a popup with content. Falls back to printing to stdout.
pub fn popup(
    content: []const u8,
    title: []const u8,
    stdout: std.fs.File,
    allocator: std.mem.Allocator,
) void {
    if (isAvailable()) {
        attyxPopup(content, title, allocator);
        return;
    }
    // Fallback: print to terminal
    stdout.writeAll("--- ") catch {};
    stdout.writeAll(title) catch {};
    stdout.writeAll(" ---\n") catch {};
    stdout.writeAll(content) catch {};
    stdout.writeAll("\n") catch {};
}

fn attyxPopup(content: []const u8, title: []const u8, allocator: std.mem.Allocator) void {
    _ = title;
    // Write content to temp file, show with less in popup
    const tmp_path = "/tmp/xyron-popup.txt";
    {
        var file = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
        defer file.close();
        file.writeAll(content) catch {};
    }

    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "less {s}", .{tmp_path}) catch return;

    var child = std.process.Child.init(
        &.{ "attyx", "popup", cmd, "--width", "80", "--height", "60" },
        allocator,
    );
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return;
    _ = child.wait() catch {};

    std.fs.deleteFileAbsolute(tmp_path) catch {};
}

// ---------------------------------------------------------------------------
// Inspect — show structured runtime object
// ---------------------------------------------------------------------------

/// Render a structured object for inspection.
pub fn inspect(
    kind: []const u8,
    content: []const u8,
    stdout: std.fs.File,
    allocator: std.mem.Allocator,
) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    pos += cp(buf[pos..], "=== ");
    pos += cp(buf[pos..], kind);
    pos += cp(buf[pos..], " ===\n\n");
    pos += cp(buf[pos..], content);
    pos += cp(buf[pos..], "\n");

    if (isAvailable()) {
        attyxPopup(buf[0..pos], kind, allocator);
    } else {
        stdout.writeAll(buf[0..pos]) catch {};
    }
}

// ---------------------------------------------------------------------------
// Inspect handlers
// ---------------------------------------------------------------------------

const history_db_mod = @import("history_db.zig");

/// Run an inspect sub-command. Returns true if handled.
pub fn runInspect(args: []const []const u8, stdout: std.fs.File, hdb: ?*history_db_mod.HistoryDb) bool {
    const kind = args[0];
    if (std.mem.eql(u8, kind, "history")) { inspectHistory(stdout, hdb); return true; }
    if (std.mem.eql(u8, kind, "env")) { inspectEnv(stdout); return true; }
    if (std.mem.eql(u8, kind, "attyx")) { inspectAttyx(stdout); return true; }
    return false;
}

fn inspectHistory(stdout: std.fs.File, hdb: ?*history_db_mod.HistoryDb) void {
    const db = hdb orelse { stdout.writeAll("No history database\n") catch {}; return; };
    var content_buf: [4096]u8 = undefined;
    var cpos: usize = 0;

    var entries: [10]history_db_mod.HistoryEntry = undefined;
    var str_buf: [4096]u8 = undefined;
    const count = db.recentEntries(&entries, &str_buf);

    var i = count;
    while (i > 0) {
        i -= 1;
        const n = std.fmt.bufPrint(content_buf[cpos..], "#{d}  {s}  (exit {d})\n", .{
            entries[i].id, entries[i].raw_input, entries[i].exit_code,
        }) catch break;
        cpos += n.len;
    }
    inspect("History", content_buf[0..cpos], stdout, std.heap.page_allocator);
}

fn inspectEnv(stdout: std.fs.File) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    pos += cp(buf[pos..], "ATTYX:  ");
    pos += cp(buf[pos..], if (isAvailable()) "yes" else "no");
    pos += cp(buf[pos..], "\nSHELL:  xyron\nHOME:   ");
    pos += cp(buf[pos..], posix.getenv("HOME") orelse "?");
    pos += cp(buf[pos..], "\nUSER:   ");
    pos += cp(buf[pos..], posix.getenv("USER") orelse "?");
    pos += cp(buf[pos..], "\n");
    inspect("Environment", buf[0..pos], stdout, std.heap.page_allocator);
}

fn inspectAttyx(stdout: std.fs.File) void {
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    pos += cp(buf[pos..], "Running inside Attyx: ");
    pos += cp(buf[pos..], if (isAvailable()) "yes" else "no");
    pos += cp(buf[pos..], "\n");
    if (isAvailable()) {
        pos += cp(buf[pos..], "ATTYX_PID: ");
        pos += cp(buf[pos..], posix.getenv("ATTYX_PID") orelse "?");
        pos += cp(buf[pos..], "\n");
    }
    inspect("Attyx Integration", buf[0..pos], stdout, std.heap.page_allocator);
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}
