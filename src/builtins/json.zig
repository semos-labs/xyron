// json — parse JSON input and render as structured table.
//
// Usage:
//   curl api | json              # render first level
//   curl api | json .data        # access field
//   curl api | json .data.items  # nested field
//   curl api | json .data.[0]    # array index
//   curl api | json .data.[]     # iterate array

const std = @import("std");
const jp = @import("../json_parser.zig");
const rich = @import("../rich_output.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File) Result {
    _ = args;
    // json is a pipe target — read from stdin handled by executor
    stdout.writeAll("xyron: json: use as pipe target: command | json [path]\n") catch {};
    return .{ .exit_code = 1 };
}

/// Called from forked child with stdin wired to pipe.
pub fn runFromPipe(args: []const []const u8) void {
    const alloc = std.heap.page_allocator;
    const posix = std.posix;

    // Read all stdin
    var buf: [262144]u8 = undefined; // 256KB
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(posix.STDIN_FILENO, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) { std.process.exit(0); }

    // Parse JSON
    const value = jp.parse(alloc, buf[0..total]) catch {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("xyron: json: invalid JSON\n") catch {};
        std.process.exit(1);
    };

    // Apply path query
    const path = if (args.len > 0) args[0] else ".";
    const target = applyPath(value, path) orelse {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("xyron: json: path not found\n") catch {};
        std.process.exit(1);
    };

    // Check if path ends with .[] (iterate array)
    const iterate = std.mem.endsWith(u8, path, ".[]") or std.mem.eql(u8, path, ".[]");

    const stdout_f = std.fs.File.stdout();
    if (iterate and target == .array) {
        renderArrayOfValues(stdout_f, target.array);
    } else {
        renderValue(stdout_f, target);
    }
    std.process.exit(0);
}

// ---------------------------------------------------------------------------
// Path query: .field.nested.[0]
// ---------------------------------------------------------------------------

fn applyPath(root: jp.Value, path: []const u8) ?jp.Value {
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return root;
    if (std.mem.eql(u8, path, ".[]")) return root;

    var current = root;
    var remaining = path;

    // Strip leading dot
    if (remaining.len > 0 and remaining[0] == '.') remaining = remaining[1..];
    // Strip trailing .[]
    if (std.mem.endsWith(u8, remaining, ".[]")) remaining = remaining[0 .. remaining.len - 3];

    while (remaining.len > 0) {
        // Array index: [N]
        if (remaining[0] == '[') {
            const close = std.mem.indexOf(u8, remaining, "]") orelse return null;
            const idx_str = remaining[1..close];
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch return null;
            current = current.getIndex(idx) orelse return null;
            remaining = remaining[close + 1 ..];
            if (remaining.len > 0 and remaining[0] == '.') remaining = remaining[1..];
            continue;
        }

        // Field access
        const dot = std.mem.indexOf(u8, remaining, ".") orelse remaining.len;
        const bracket = std.mem.indexOf(u8, remaining, "[") orelse remaining.len;
        const end = @min(dot, bracket);
        const field = remaining[0..end];
        if (field.len == 0) break;
        current = current.getField(field) orelse return null;
        remaining = remaining[end..];
        if (remaining.len > 0 and remaining[0] == '.') remaining = remaining[1..];
    }

    return current;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn renderValue(stdout: std.fs.File, val: jp.Value) void {
    switch (val) {
        .object => |fields| renderObject(stdout, fields),
        .array => |items| renderArray(stdout, items),
        .string => |s| {
            stdout.writeAll(s) catch {};
            stdout.writeAll("\n") catch {};
        },
        .number => |n| {
            var buf: [64]u8 = undefined;
            stdout.writeAll(std.fmt.bufPrint(&buf, "{d}\n", .{n}) catch "?\n") catch {};
        },
        .boolean => |b| stdout.writeAll(if (b) "true\n" else "false\n") catch {},
        .null_val => stdout.writeAll("null\n") catch {},
    }
}

fn renderObject(stdout: std.fs.File, fields: []const jp.Field) void {
    if (fields.len == 0) return;

    var tbl = rich.Table{};
    tbl.addColumn(.{ .header = "key", .color = "\x1b[1;37m" });
    tbl.addColumn(.{ .header = "value", .color = "" });
    tbl.addColumn(.{ .header = "type", .color = "\x1b[2m" });

    for (fields) |f| {
        const r = tbl.addRow();
        tbl.setCell(r, 0, f.key);
        var vbuf: [rich.MAX_CELL]u8 = undefined;
        tbl.setCellColor(r, 1, f.value.format(&vbuf), f.value.typeColor());
        tbl.setCell(r, 2, f.value.typeName());
    }
    tbl.render(stdout);
}

fn renderArray(stdout: std.fs.File, items: []const jp.Value) void {
    if (items.len == 0) return;

    // Check if all items are objects with same keys → table
    if (items[0] == .object) {
        const keys = items[0].object;
        var all_objects = true;
        for (items[1..]) |item| {
            if (item != .object) { all_objects = false; break; }
        }
        if (all_objects and keys.len > 0 and keys.len <= rich.MAX_COLS) {
            renderArrayOfObjects(stdout, items, keys);
            return;
        }
    }

    // Fallback: index + value table
    renderArrayOfValues(stdout, items);
}

fn renderArrayOfObjects(stdout: std.fs.File, items: []const jp.Value, keys: []const jp.Field) void {
    var tbl = rich.Table{};
    for (keys) |k| {
        tbl.addColumn(.{ .header = k.key, .color = "" });
    }

    for (items) |item| {
        if (item != .object) continue;
        const r = tbl.addRow();
        for (keys, 0..) |k, c| {
            if (item.getField(k.key)) |v| {
                var vbuf: [rich.MAX_CELL]u8 = undefined;
                tbl.setCellColor(r, c, v.format(&vbuf), v.typeColor());
            }
        }
    }
    tbl.render(stdout);
}

fn renderArrayOfValues(stdout: std.fs.File, items: []const jp.Value) void {
    var tbl = rich.Table{};
    tbl.addColumn(.{ .header = "#", .align_ = .right, .color = "\x1b[2m" });
    tbl.addColumn(.{ .header = "value", .color = "" });
    tbl.addColumn(.{ .header = "type", .color = "\x1b[2m" });

    for (items, 0..) |item, i| {
        const r = tbl.addRow();
        var idx_buf: [8]u8 = undefined;
        tbl.setCell(r, 0, std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch "?");
        var vbuf: [rich.MAX_CELL]u8 = undefined;
        tbl.setCellColor(r, 1, item.format(&vbuf), item.typeColor());
        tbl.setCell(r, 2, item.typeName());
    }
    tbl.render(stdout);
}
