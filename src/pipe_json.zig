// pipe_json.zig — Shared utilities for structured pipe commands.
//
// Provides JSON reading/writing for pipe commands (select, where, sort).
// Builtins output JSON when stdout is a pipe, table when interactive.
// Pipe commands read JSON arrays, transform, and output JSON or table.

const std = @import("std");
const posix = std.posix;
const jp = @import("json_parser.zig");
const rich = @import("rich_output.zig");

/// Check if a file descriptor is a terminal (not a pipe).
pub fn isTerminal(fd: posix.fd_t) bool {
    const c_ext = struct {
        extern "c" fn isatty(fd: c_int) c_int;
    };
    return c_ext.isatty(fd) != 0;
}

/// Read all stdin into a buffer. Returns the filled slice.
pub fn readStdin(buf: []u8) []const u8 {
    const stdin = std.fs.File.stdin();
    var total: usize = 0;
    while (total < buf.len) {
        const n = stdin.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

/// Write a JSON value to a writer buffer.
pub fn writeValue(buf: []u8, pos: *usize, val: *const jp.Value) void {
    switch (val.*) {
        .string => |s| {
            appendChar(buf, pos, '"');
            appendSlice(buf, pos, s);
            appendChar(buf, pos, '"');
        },
        .number => |n| {
            // Check if it's an integer
            const int_val = @as(i64, @intFromFloat(n));
            if (@as(f64, @floatFromInt(int_val)) == n) {
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{int_val}) catch return;
                appendSlice(buf, pos, s);
            } else {
                var num_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d:.2}", .{n}) catch return;
                appendSlice(buf, pos, s);
            }
        },
        .boolean => |b| appendSlice(buf, pos, if (b) "true" else "false"),
        .null_val => appendSlice(buf, pos, "null"),
        .object => |fields| {
            appendChar(buf, pos, '{');
            for (fields, 0..) |f, i| {
                if (i > 0) appendChar(buf, pos, ',');
                appendChar(buf, pos, '"');
                appendSlice(buf, pos, f.key);
                appendSlice(buf, pos, "\":");
                writeValue(buf, pos, &f.value);
            }
            appendChar(buf, pos, '}');
        },
        .array => |items| {
            appendChar(buf, pos, '[');
            for (items, 0..) |*item, i| {
                if (i > 0) appendChar(buf, pos, ',');
                writeValue(buf, pos, item);
            }
            appendChar(buf, pos, ']');
        },
    }
}

/// Write an array of objects as JSON to stdout.
pub fn writeJsonArray(stdout: std.fs.File, items: []const jp.Value) void {
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;

    appendChar(&buf, &pos, '[');
    for (items, 0..) |*item, i| {
        if (i > 0) appendChar(&buf, &pos, ',');
        // Flush if buffer getting full
        if (pos > buf.len - 4096) {
            stdout.writeAll(buf[0..pos]) catch {};
            pos = 0;
        }
        writeValue(&buf, &pos, item);
    }
    appendChar(&buf, &pos, ']');
    stdout.writeAll(buf[0..pos]) catch {};
}

/// Render an array of objects as a rich table.
pub fn renderTable(stdout: std.fs.File, items: []const jp.Value) void {
    if (items.len == 0) return;

    // Detect columns from first object
    const first = items[0];
    var col_names: [rich.MAX_COLS][]const u8 = undefined;
    var col_count: usize = 0;

    switch (first) {
        .object => |fields| {
            for (fields) |f| {
                if (col_count >= rich.MAX_COLS) break;
                col_names[col_count] = f.key;
                col_count += 1;
            }
        },
        else => {
            col_names[0] = "value";
            col_count = 1;
        },
    }

    var table = rich.Table{};
    for (0..col_count) |ci| {
        table.addColumn(.{ .header = col_names[ci], .header_color = "\x1b[1;37m" });
    }

    const max_rows = @min(items.len, rich.MAX_ROWS);
    for (0..max_rows) |ri| {
        const row = table.addRow();
        const item = items[ri];
        switch (item) {
            .object => |fields| {
                for (0..col_count) |ci| {
                    var found = false;
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.key, col_names[ci])) {
                            var fmt_buf: [128]u8 = undefined;
                            table.setCellColor(row, ci, f.value.format(&fmt_buf), f.value.typeColor());
                            found = true;
                            break;
                        }
                    }
                    if (!found) table.setCellColor(row, ci, "null", "\x1b[2m");
                }
            },
            else => {
                var fmt_buf: [128]u8 = undefined;
                table.setCellColor(row, 0, item.format(&fmt_buf), item.typeColor());
            },
        }
    }

    table.render(stdout);
}

/// Build a new object with only the selected fields.
pub fn selectFields(
    allocator: std.mem.Allocator,
    obj: *const jp.Value,
    field_names: []const []const u8,
) ?jp.Value {
    switch (obj.*) {
        .object => |fields| {
            var selected = allocator.alloc(jp.Field, field_names.len) catch return null;
            for (field_names, 0..) |name, i| {
                // Support dotted paths
                var found_val: ?jp.Value = null;
                if (std.mem.indexOfScalar(u8, name, '.') != null) {
                    // Nested path
                    found_val = navigatePath(obj, name);
                } else {
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.key, name)) {
                            found_val = f.value;
                            break;
                        }
                    }
                }
                selected[i] = .{
                    .key = name,
                    .value = found_val orelse .{ .null_val = {} },
                };
            }
            return .{ .object = selected };
        },
        else => return null,
    }
}

/// Navigate a dotted path into a JSON value.
pub fn navigatePath(val: *const jp.Value, path: []const u8) ?jp.Value {
    var current = val.*;
    var remaining = path;
    while (remaining.len > 0) {
        const dot = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
        const segment = remaining[0..dot];
        remaining = if (dot < remaining.len) remaining[dot + 1 ..] else "";
        switch (current) {
            .object => |fields| {
                var found = false;
                for (fields) |f| {
                    if (std.mem.eql(u8, f.key, segment)) {
                        current = f.value;
                        found = true;
                        break;
                    }
                }
                if (!found) return null;
            },
            else => return null,
        }
    }
    return current;
}

fn appendChar(buf: []u8, pos: *usize, ch: u8) void {
    if (pos.* < buf.len) { buf[pos.*] = ch; pos.* += 1; }
}

fn appendSlice(buf: []u8, pos: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - pos.*);
    @memcpy(buf[pos.*..][0..n], s[0..n]);
    pos.* += n;
}
