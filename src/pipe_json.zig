// pipe_json.zig — Shared utilities for structured pipe commands.
//
// Provides JSON reading/writing for pipe commands (select, where, sort).
// Builtins output JSON when stdout is a pipe, table when interactive.
// Pipe commands read JSON arrays, transform, and output JSON or table.

const std = @import("std");
const posix = std.posix;
const jp = @import("json_parser.zig");
const rich = @import("rich_output.zig");

// ---------------------------------------------------------------------------
// Column type metadata — builtins declare how fields should be formatted
// ---------------------------------------------------------------------------

pub const ColType = enum {
    string,     // default text
    number,     // numeric, right-aligned
    size,       // bytes → human-readable (1.2K, 3.5M)
    path,       // file/dir name — colored by associated kind
    kind,       // file type (directory/file/symlink) — colored
    permissions,// file mode — dim
    pid,        // process ID — cyan
    percent,    // percentage — yellow
    status,     // running/stopped/active — semantic color
    exit_code,  // 0=green, else=red
    duration,   // ms → human-readable (1.2s, 2m30s)
    command,    // command string — white
    id,         // generic ID — cyan, right-aligned

    pub fn label(self: ColType) []const u8 {
        return @tagName(self);
    }
};

pub const MAX_TYPE_COLS: usize = 24;

/// Type schema for structured output.
pub const TypeSchema = struct {
    names: [MAX_TYPE_COLS][]const u8 = undefined,
    types: [MAX_TYPE_COLS]ColType = undefined,
    count: usize = 0,

    pub fn add(self: *TypeSchema, name: []const u8, col_type: ColType) void {
        if (self.count >= MAX_TYPE_COLS) return;
        self.names[self.count] = name;
        self.types[self.count] = col_type;
        self.count += 1;
    }

    pub fn getType(self: *const TypeSchema, name: []const u8) ?ColType {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.names[i], name)) return self.types[i];
        }
        return null;
    }
};

/// Output mode override, set by executor based on pipeline context.
pub const OutputMode = enum { auto, json, text };
pub var output_mode: OutputMode = .auto;

/// Check if output should be a table (true) or JSON (false).
pub fn isTerminal(fd: posix.fd_t) bool {
    return switch (output_mode) {
        .json => false,
        .text => true,
        .auto => {
            const c_ext = struct {
                extern "c" fn isatty(fd: c_int) c_int;
            };
            return c_ext.isatty(fd) != 0;
        },
    };
}

/// Result of parsing typed JSON input.
pub const TypedInput = struct {
    items: []const jp.Value,
    schema: ?TypeSchema,
};

/// Parse JSON input, detecting typed envelopes.
/// Returns the array of items and optional type schema.
pub fn parseTypedInput(allocator: std.mem.Allocator, input: []const u8) !TypedInput {
    const parsed = try jp.parse(allocator, input);

    // Check for typed envelope: {"_types": {...}, "rows": [...]}
    switch (parsed) {
        .object => |fields| {
            var types_val: ?jp.Value = null;
            var rows_val: ?jp.Value = null;
            for (fields) |f| {
                if (std.mem.eql(u8, f.key, "_types")) types_val = f.value;
                if (std.mem.eql(u8, f.key, "rows")) rows_val = f.value;
            }
            if (rows_val) |rv| {
                switch (rv) {
                    .array => |arr| {
                        var schema: ?TypeSchema = null;
                        if (types_val) |tv| {
                            switch (tv) {
                                .object => |type_fields| {
                                    var s = TypeSchema{};
                                    for (type_fields) |tf| {
                                        switch (tf.value) {
                                            .string => |type_name| {
                                                if (parseColType(type_name)) |ct| s.add(tf.key, ct);
                                            },
                                            else => {},
                                        }
                                    }
                                    schema = s;
                                },
                                else => {},
                            }
                        }
                        return .{ .items = arr, .schema = schema };
                    },
                    else => {},
                }
            }
        },
        .array => |arr| return .{ .items = arr, .schema = null },
        else => {},
    }
    // Not an array or envelope — wrap single value
    return .{ .items = &.{}, .schema = null };
}

fn parseColType(name: []const u8) ?ColType {
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "number")) return .number;
    if (std.mem.eql(u8, name, "size")) return .size;
    if (std.mem.eql(u8, name, "path")) return .path;
    if (std.mem.eql(u8, name, "kind")) return .kind;
    if (std.mem.eql(u8, name, "permissions")) return .permissions;
    if (std.mem.eql(u8, name, "pid")) return .pid;
    if (std.mem.eql(u8, name, "percent")) return .percent;
    if (std.mem.eql(u8, name, "status")) return .status;
    if (std.mem.eql(u8, name, "exit_code")) return .exit_code;
    if (std.mem.eql(u8, name, "duration")) return .duration;
    if (std.mem.eql(u8, name, "command")) return .command;
    if (std.mem.eql(u8, name, "id")) return .id;
    return null;
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
            writeEscapedString(buf, pos, s);
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

/// Write a typed JSON envelope: {"_types": {...}, "rows": [...]}.
pub fn writeTypedJson(stdout: std.fs.File, items: []const jp.Value, schema: *const TypeSchema) void {
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;

    // Write _types object
    appendSlice(&buf, &pos, "{\"_types\":{");
    for (0..schema.count) |i| {
        if (i > 0) appendChar(&buf, &pos, ',');
        appendChar(&buf, &pos, '"');
        appendSlice(&buf, &pos, schema.names[i]);
        appendSlice(&buf, &pos, "\":\"");
        appendSlice(&buf, &pos, schema.types[i].label());
        appendChar(&buf, &pos, '"');
    }
    appendSlice(&buf, &pos, "},\"rows\":");
    stdout.writeAll(buf[0..pos]) catch {};
    pos = 0;

    // Write rows array
    appendChar(&buf, &pos, '[');
    for (items, 0..) |*item, i| {
        if (i > 0) appendChar(&buf, &pos, ',');
        if (pos > buf.len - 4096) {
            stdout.writeAll(buf[0..pos]) catch {};
            pos = 0;
        }
        writeValue(&buf, &pos, item);
    }
    appendSlice(&buf, &pos, "]}");
    stdout.writeAll(buf[0..pos]) catch {};
}

/// Write an array of objects as JSON to stdout (untyped).
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
/// If schema is provided, uses it for formatting. Otherwise falls back to heuristics.
pub fn renderTable(stdout: std.fs.File, items: []const jp.Value) void {
    renderTableWithSchema(stdout, items, null);
}

pub fn renderTableWithSchema(stdout: std.fs.File, items: []const jp.Value, schema: ?*const TypeSchema) void {
    if (items.len == 0) return;

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
        const ct = if (schema) |s| s.getType(col_names[ci]) else null;
        const col_align: rich.Align = if (ct) |t| switch (t) {
            .number, .size, .pid, .percent, .id, .exit_code, .duration => .right,
            else => .left,
        } else if (isNumericColumn(col_names[ci])) .right else .left;
        table.addColumn(.{ .header = col_names[ci], .header_color = "\x1b[1;37m", .align_ = col_align });
    }

    // Detect "type"/"kind" column for row-level context
    var type_col: ?usize = null;
    for (0..col_count) |ci| {
        const ct = if (schema) |s| s.getType(col_names[ci]) else null;
        if (ct) |t| { if (t == .kind) { type_col = ci; break; } }
        if (std.mem.eql(u8, col_names[ci], "type")) { type_col = ci; break; }
    }

    const max_rows = @min(items.len, rich.MAX_ROWS);
    for (0..max_rows) |ri| {
        const row = table.addRow();
        const item = items[ri];
        switch (item) {
            .object => |fields| {
                var row_type: []const u8 = "";
                if (type_col != null) {
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.key, "type") or std.mem.eql(u8, f.key, "kind")) {
                            switch (f.value) { .string => |s| { row_type = s; }, else => {} }
                            break;
                        }
                    }
                }

                for (0..col_count) |ci| {
                    var found = false;
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.key, col_names[ci])) {
                            var fmt_buf: [128]u8 = undefined;
                            const ct = if (schema) |s| s.getType(col_names[ci]) else null;
                            const color = if (ct) |t| typedColor(t, &f.value, row_type) else semanticColor(col_names[ci], &f.value, row_type);

                            // Format based on declared type
                            if (ct) |t| {
                                switch (t) {
                                    .size => switch (f.value) {
                                        .number => |n| {
                                            var sb: [32]u8 = undefined;
                                            table.setCellColor(row, ci, rich.formatSize(&sb, @intFromFloat(n)), color);
                                        },
                                        else => table.setCellColor(row, ci, f.value.format(&fmt_buf), color),
                                    },
                                    .duration => switch (f.value) {
                                        .number => |n| {
                                            const prompt_mod = @import("prompt.zig");
                                            var db: [32]u8 = undefined;
                                            table.setCellColor(row, ci, prompt_mod.formatDuration(&db, @intFromFloat(n)), color);
                                        },
                                        else => table.setCellColor(row, ci, f.value.format(&fmt_buf), color),
                                    },
                                    .permissions => table.setCellColor(row, ci, f.value.format(&fmt_buf), "\x1b[2m"),
                                    else => table.setCellColor(row, ci, f.value.format(&fmt_buf), color),
                                }
                            } else if (isSizeColumn(col_names[ci])) {
                                switch (f.value) {
                                    .number => |n| {
                                        var sb: [32]u8 = undefined;
                                        table.setCellColor(row, ci, rich.formatSize(&sb, @intFromFloat(n)), color);
                                    },
                                    else => table.setCellColor(row, ci, f.value.format(&fmt_buf), color),
                                }
                            } else {
                                table.setCellColor(row, ci, f.value.format(&fmt_buf), color);
                            }
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

/// Color based on declared column type — no heuristics.
fn typedColor(ct: ColType, val: *const jp.Value, row_type: []const u8) []const u8 {
    return switch (ct) {
        .path => {
            if (std.mem.eql(u8, row_type, "directory")) return "\x1b[1;34m";
            if (std.mem.eql(u8, row_type, "symlink")) return "\x1b[1;36m";
            return "\x1b[37m";
        },
        .kind => {
            if (std.mem.eql(u8, row_type, "directory")) return "\x1b[34m";
            if (std.mem.eql(u8, row_type, "symlink")) return "\x1b[36m";
            return "\x1b[2m";
        },
        .size => switch (val.*) {
            .number => |n| {
                if (n >= 1073741824) return "\x1b[1;31m";
                if (n >= 1048576) return "\x1b[33m";
                if (n >= 1024) return "\x1b[32m";
                return "\x1b[2m";
            },
            else => "\x1b[2m",
        },
        .permissions => "\x1b[2m",
        .pid, .id => "\x1b[36m",
        .percent => "\x1b[33m",
        .command => "\x1b[37m",
        .exit_code => switch (val.*) {
            .number => |n| if (n == 0) "\x1b[32m" else "\x1b[31m",
            else => "\x1b[2m",
        },
        .status => switch (val.*) {
            .string => |s| {
                if (std.mem.eql(u8, s, "running") or std.mem.eql(u8, s, "active") or std.mem.eql(u8, s, "success")) return "\x1b[32m";
                if (std.mem.eql(u8, s, "stopped") or std.mem.eql(u8, s, "failed") or std.mem.eql(u8, s, "error")) return "\x1b[31m";
                return "\x1b[33m";
            },
            else => "\x1b[2m",
        },
        .duration => "\x1b[33m",
        else => val.typeColor(),
    };
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

/// Smart coloring based on field name and value — mimics ls, ps, etc.
fn semanticColor(col_name: []const u8, val: *const jp.Value, row_type: []const u8) []const u8 {
    // Name/path fields — color by file type
    if (std.mem.eql(u8, col_name, "name") or std.mem.eql(u8, col_name, "path") or
        std.mem.eql(u8, col_name, "file"))
    {
        if (std.mem.eql(u8, row_type, "directory")) return "\x1b[1;34m"; // bold blue
        if (std.mem.eql(u8, row_type, "symlink")) return "\x1b[1;36m"; // bold cyan
        return "\x1b[37m"; // white
    }

    // Type field itself
    if (std.mem.eql(u8, col_name, "type") or std.mem.eql(u8, col_name, "kind")) {
        if (std.mem.eql(u8, row_type, "directory")) return "\x1b[34m";
        if (std.mem.eql(u8, row_type, "symlink")) return "\x1b[36m";
        return "\x1b[2m"; // dim
    }

    // Size fields — color by magnitude
    if (std.mem.eql(u8, col_name, "size") or std.mem.eql(u8, col_name, "bytes")) {
        switch (val.*) {
            .number => |n| {
                if (n >= 1073741824) return "\x1b[1;31m"; // bold red (>= 1GB)
                if (n >= 1048576) return "\x1b[33m"; // yellow (>= 1MB)
                if (n >= 1024) return "\x1b[32m"; // green (>= 1KB)
                return "\x1b[2m"; // dim (< 1KB)
            },
            else => return "\x1b[2m",
        }
    }

    // Permissions
    if (std.mem.eql(u8, col_name, "permissions") or std.mem.eql(u8, col_name, "mode")) {
        return "\x1b[2m"; // dim
    }

    // Process fields
    if (std.mem.eql(u8, col_name, "PID") or std.mem.eql(u8, col_name, "pid")) return "\x1b[36m"; // cyan
    if (std.mem.eql(u8, col_name, "%CPU") or std.mem.eql(u8, col_name, "%MEM") or
        std.mem.eql(u8, col_name, "cpu") or std.mem.eql(u8, col_name, "mem"))
        return "\x1b[33m"; // yellow

    // State fields
    if (std.mem.eql(u8, col_name, "state") or std.mem.eql(u8, col_name, "status")) {
        switch (val.*) {
            .string => |s| {
                if (std.mem.eql(u8, s, "running") or std.mem.eql(u8, s, "Running") or
                    std.mem.eql(u8, s, "active") or std.mem.eql(u8, s, "success"))
                    return "\x1b[32m"; // green
                if (std.mem.eql(u8, s, "stopped") or std.mem.eql(u8, s, "Stopped") or
                    std.mem.eql(u8, s, "failed") or std.mem.eql(u8, s, "error"))
                    return "\x1b[31m"; // red
                if (std.mem.eql(u8, s, "pending") or std.mem.eql(u8, s, "waiting"))
                    return "\x1b[33m"; // yellow
            },
            else => {},
        }
        return "\x1b[2m";
    }

    // Exit code
    if (std.mem.eql(u8, col_name, "exit_code") or std.mem.eql(u8, col_name, "exitCode")) {
        switch (val.*) {
            .number => |n| return if (n == 0) "\x1b[32m" else "\x1b[31m",
            else => {},
        }
    }

    // Variable names (env)
    if (std.mem.eql(u8, col_name, "variable") or std.mem.eql(u8, col_name, "key"))
        return "\x1b[1;36m"; // bold cyan

    // Command fields
    if (std.mem.eql(u8, col_name, "command") or std.mem.eql(u8, col_name, "COMMAND"))
        return "\x1b[37m";

    // ID fields — right-align already handled, color cyan
    if (std.mem.eql(u8, col_name, "id") or std.mem.eql(u8, col_name, "ID") or
        std.mem.eql(u8, col_name, "userId"))
        return "\x1b[36m";

    // Default: use type-based coloring
    return val.typeColor();
}

fn isSizeColumn(name: []const u8) bool {
    return std.mem.eql(u8, name, "size") or std.mem.eql(u8, name, "bytes") or
        std.mem.eql(u8, name, "filesize") or std.mem.eql(u8, name, "disk_usage");
}

fn isNumericColumn(name: []const u8) bool {
    return std.mem.eql(u8, name, "size") or std.mem.eql(u8, name, "bytes") or
        std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "ID") or
        std.mem.eql(u8, name, "PID") or std.mem.eql(u8, name, "pid") or
        std.mem.eql(u8, name, "%CPU") or std.mem.eql(u8, name, "%MEM") or
        std.mem.eql(u8, name, "exit_code") or std.mem.eql(u8, name, "userId") or
        std.mem.eql(u8, name, "count") or std.mem.eql(u8, name, "duration") or
        std.mem.eql(u8, name, "port");
}

/// Write a string with JSON escaping (newlines, tabs, backslashes, quotes, control chars).
fn writeEscapedString(buf: []u8, pos: *usize, s: []const u8) void {
    for (s) |ch| {
        switch (ch) {
            '"' => { appendChar(buf, pos, '\\'); appendChar(buf, pos, '"'); },
            '\\' => { appendChar(buf, pos, '\\'); appendChar(buf, pos, '\\'); },
            '\n' => { appendChar(buf, pos, '\\'); appendChar(buf, pos, 'n'); },
            '\r' => { appendChar(buf, pos, '\\'); appendChar(buf, pos, 'r'); },
            '\t' => { appendChar(buf, pos, '\\'); appendChar(buf, pos, 't'); },
            0x08 => { appendChar(buf, pos, '\\'); appendChar(buf, pos, 'b'); },
            0x0C => { appendChar(buf, pos, '\\'); appendChar(buf, pos, 'f'); },
            else => |c| {
                if (c < 0x20) {
                    // Control characters → \u00XX
                    const hex = "0123456789abcdef";
                    appendSlice(buf, pos, "\\u00");
                    appendChar(buf, pos, hex[c >> 4]);
                    appendChar(buf, pos, hex[c & 0x0f]);
                } else {
                    appendChar(buf, pos, c);
                }
            },
        }
    }
}

fn appendChar(buf: []u8, pos: *usize, ch: u8) void {
    if (pos.* < buf.len) { buf[pos.*] = ch; pos.* += 1; }
}

fn appendSlice(buf: []u8, pos: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - pos.*);
    @memcpy(buf[pos.*..][0..n], s[0..n]);
    pos.* += n;
}
