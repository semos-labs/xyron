// json_parser.zig — Minimal JSON parser with typed values.
//
// Parses JSON into a Value tree. Supports objects, arrays, strings,
// numbers, booleans, and null. Uses an allocator for dynamic structures.

const std = @import("std");

pub const Value = union(enum) {
    object: []Field,
    array: []const Value,
    string: []const u8,
    number: f64,
    boolean: bool,
    null_val: void,

    pub fn getField(self: Value, key: []const u8) ?Value {
        if (self != .object) return null;
        for (self.object) |f| {
            if (std.mem.eql(u8, f.key, key)) return f.value;
        }
        return null;
    }

    pub fn getIndex(self: Value, idx: usize) ?Value {
        if (self != .array) return null;
        if (idx >= self.array.len) return null;
        return self.array[idx];
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .object => "object",
            .array => "array",
            .string => "string",
            .number => "number",
            .boolean => "boolean",
            .null_val => "null",
        };
    }

    /// Format value as string for display.
    pub fn format(self: Value, buf: []u8) []const u8 {
        return switch (self) {
            .string => |s| blk: {
                const n = @min(s.len, buf.len);
                @memcpy(buf[0..n], s[0..n]);
                break :blk buf[0..n];
            },
            .number => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "?",
            .boolean => |b| if (b) "true" else "false",
            .null_val => "null",
            .object => "{...}",
            .array => |a| blk: {
                break :blk std.fmt.bufPrint(buf, "[{d} items]", .{a.len}) catch "[...]";
            },
        };
    }

    pub fn typeColor(self: Value) []const u8 {
        return switch (self) {
            .string => "\x1b[32m", // green
            .number => "\x1b[36m", // cyan
            .boolean => "\x1b[33m", // yellow
            .null_val => "\x1b[2m", // dim
            .object => "\x1b[35m", // magenta
            .array => "\x1b[34m", // blue
        };
    }
};

pub const Field = struct {
    key: []const u8,
    value: Value,
};

pub const ParseError = error{
    InvalidJson,
    UnexpectedEnd,
    OutOfMemory,
};

/// Parse a JSON string into a Value tree.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!Value {
    var pos: usize = 0;
    const result = try parseValue(allocator, input, &pos);
    return result;
}

fn parseValue(alloc: std.mem.Allocator, input: []const u8, pos: *usize) ParseError!Value {
    skipWhitespace(input, pos);
    if (pos.* >= input.len) return ParseError.UnexpectedEnd;

    return switch (input[pos.*]) {
        '{' => parseObject(alloc, input, pos),
        '[' => parseArray(alloc, input, pos),
        '"' => .{ .string = try parseString(alloc, input, pos) },
        't', 'f' => parseBool(input, pos),
        'n' => parseNull(input, pos),
        else => parseNumber(input, pos),
    };
}

fn parseObject(alloc: std.mem.Allocator, input: []const u8, pos: *usize) ParseError!Value {
    pos.* += 1; // skip {
    var fields: std.ArrayList(Field) = .{};
    skipWhitespace(input, pos);

    while (pos.* < input.len and input[pos.*] != '}') {
        skipWhitespace(input, pos);
        if (pos.* >= input.len or input[pos.*] != '"') return ParseError.InvalidJson;
        const key = try parseString(alloc, input, pos);
        skipWhitespace(input, pos);
        if (pos.* >= input.len or input[pos.*] != ':') return ParseError.InvalidJson;
        pos.* += 1;
        const value = try parseValue(alloc, input, pos);
        fields.append(alloc, .{ .key = key, .value = value }) catch return ParseError.OutOfMemory;
        skipWhitespace(input, pos);
        if (pos.* < input.len and input[pos.*] == ',') pos.* += 1;
    }
    if (pos.* < input.len) pos.* += 1; // skip }
    return .{ .object = fields.toOwnedSlice(alloc) catch return ParseError.OutOfMemory };
}

fn parseArray(alloc: std.mem.Allocator, input: []const u8, pos: *usize) ParseError!Value {
    pos.* += 1; // skip [
    var items: std.ArrayList(Value) = .{};
    skipWhitespace(input, pos);

    while (pos.* < input.len and input[pos.*] != ']') {
        const val = try parseValue(alloc, input, pos);
        items.append(alloc, val) catch return ParseError.OutOfMemory;
        skipWhitespace(input, pos);
        if (pos.* < input.len and input[pos.*] == ',') pos.* += 1;
    }
    if (pos.* < input.len) pos.* += 1; // skip ]
    return .{ .array = items.toOwnedSlice(alloc) catch return ParseError.OutOfMemory };
}

fn parseString(alloc: std.mem.Allocator, input: []const u8, pos: *usize) ParseError![]const u8 {
    pos.* += 1; // skip opening "
    var result: std.ArrayList(u8) = .{};
    while (pos.* < input.len and input[pos.*] != '"') {
        if (input[pos.*] == '\\' and pos.* + 1 < input.len) {
            pos.* += 1;
            const ch: u8 = switch (input[pos.*]) {
                'n' => '\n', 't' => '\t', 'r' => '\r', '\\' => '\\', '"' => '"', '/' => '/',
                else => input[pos.*],
            };
            result.append(alloc, ch) catch return ParseError.OutOfMemory;
        } else {
            result.append(alloc, input[pos.*]) catch return ParseError.OutOfMemory;
        }
        pos.* += 1;
    }
    if (pos.* < input.len) pos.* += 1; // skip closing "
    return result.toOwnedSlice(alloc) catch return ParseError.OutOfMemory;
}

fn parseNumber(input: []const u8, pos: *usize) ParseError!Value {
    const start = pos.*;
    if (pos.* < input.len and input[pos.*] == '-') pos.* += 1;
    while (pos.* < input.len and ((input[pos.*] >= '0' and input[pos.*] <= '9') or input[pos.*] == '.' or input[pos.*] == 'e' or input[pos.*] == 'E' or input[pos.*] == '+' or input[pos.*] == '-')) {
        if (pos.* > start + 1 and (input[pos.*] == '-' or input[pos.*] == '+') and input[pos.* - 1] != 'e' and input[pos.* - 1] != 'E') break;
        pos.* += 1;
    }
    const num_str = input[start..pos.*];
    const n = std.fmt.parseFloat(f64, num_str) catch return ParseError.InvalidJson;
    return .{ .number = n };
}

fn parseBool(input: []const u8, pos: *usize) ParseError!Value {
    if (pos.* + 4 <= input.len and std.mem.eql(u8, input[pos.*..][0..4], "true")) {
        pos.* += 4;
        return .{ .boolean = true };
    }
    if (pos.* + 5 <= input.len and std.mem.eql(u8, input[pos.*..][0..5], "false")) {
        pos.* += 5;
        return .{ .boolean = false };
    }
    return ParseError.InvalidJson;
}

fn parseNull(input: []const u8, pos: *usize) ParseError!Value {
    if (pos.* + 4 <= input.len and std.mem.eql(u8, input[pos.*..][0..4], "null")) {
        pos.* += 4;
        return .{ .null_val = {} };
    }
    return ParseError.InvalidJson;
}

fn skipWhitespace(input: []const u8, pos: *usize) void {
    while (pos.* < input.len and (input[pos.*] == ' ' or input[pos.*] == '\t' or input[pos.*] == '\n' or input[pos.*] == '\r')) {
        pos.* += 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse string" {
    const v = try parse(std.testing.allocator, "\"hello\"");
    try std.testing.expectEqualStrings("hello", v.string);
    std.testing.allocator.free(v.string);
}

test "parse number" {
    const v = try parse(std.testing.allocator, "42");
    try std.testing.expectEqual(@as(f64, 42), v.number);
}

test "parse object" {
    const v = try parse(std.testing.allocator, "{\"a\": 1, \"b\": \"two\"}");
    try std.testing.expectEqual(@as(usize, 2), v.object.len);
    // Clean up
    for (v.object) |f| {
        std.testing.allocator.free(f.key);
        if (f.value == .string) std.testing.allocator.free(f.value.string);
    }
    std.testing.allocator.free(v.object);
}

test "parse array" {
    const v = try parse(std.testing.allocator, "[1, 2, 3]");
    try std.testing.expectEqual(@as(usize, 3), v.array.len);
    std.testing.allocator.free(v.array);
}

test "getField" {
    const v = try parse(std.testing.allocator, "{\"name\": \"xyron\"}");
    const name = v.getField("name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("xyron", name.?.string);
    for (v.object) |f| {
        std.testing.allocator.free(f.key);
        if (f.value == .string) std.testing.allocator.free(f.value.string);
    }
    std.testing.allocator.free(v.object);
}
