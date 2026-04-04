// project/dotenv.zig — .env file parser.
//
// Parses KEY=VALUE format used by env files. Supports:
// - bare values: KEY=value
// - double-quoted values: KEY="value with spaces"
// - single-quoted values: KEY='literal value'
// - comments: # this is a comment
// - blank lines
// - export prefix: export KEY=value (stripped)

const std = @import("std");

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

pub const ParseResult = struct {
    entries: []const Entry,
    errors: []const []const u8,
};

/// Parse a .env file content string into key-value entries.
/// All returned slices point into `source` or are allocated with `allocator`.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseResult {
    var entries: std.ArrayListUnmanaged(Entry) = .{};
    var errors: std.ArrayListUnmanaged([]const u8) = .{};
    var line_num: usize = 0;

    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |raw_line| {
        line_num += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Skip blank lines and comments
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Strip optional "export " prefix
        const effective = if (std.mem.startsWith(u8, line, "export "))
            std.mem.trimLeft(u8, line["export ".len..], " \t")
        else
            line;

        // Find the = separator
        const eq_pos = std.mem.indexOfScalar(u8, effective, '=') orelse {
            errors.append(allocator, std.fmt.allocPrint(
                allocator,
                "line {d}: missing '='",
                .{line_num},
            ) catch "missing '='") catch {};
            continue;
        };

        const key = std.mem.trimRight(u8, effective[0..eq_pos], " \t");
        if (key.len == 0) {
            errors.append(allocator, std.fmt.allocPrint(
                allocator,
                "line {d}: empty key",
                .{line_num},
            ) catch "empty key") catch {};
            continue;
        }

        const raw_value = std.mem.trimLeft(u8, effective[eq_pos + 1 ..], " \t");

        // Parse the value — handle quoting
        const value = parseValue(allocator, raw_value);

        entries.append(allocator, .{ .key = key, .value = value }) catch {};
    }

    return .{
        .entries = entries.toOwnedSlice(allocator) catch &.{},
        .errors = errors.toOwnedSlice(allocator) catch &.{},
    };
}

/// Parse a value, stripping quotes if present. Handles:
/// - "double quoted" (with basic escape support)
/// - 'single quoted' (literal)
/// - bare values (trimmed at inline comment)
fn parseValue(allocator: std.mem.Allocator, raw: []const u8) []const u8 {
    if (raw.len == 0) return "";

    // Double-quoted value
    if (raw[0] == '"') {
        if (std.mem.indexOfScalarPos(u8, raw, 1, '"')) |end| {
            const inner = raw[1..end];
            // Check for escape sequences
            if (std.mem.indexOfScalar(u8, inner, '\\')) |_| {
                return unescape(allocator, inner);
            }
            return inner;
        }
        // Unterminated quote — return as-is minus opening quote
        return raw[1..];
    }

    // Single-quoted value (literal, no escapes)
    if (raw[0] == '\'') {
        if (std.mem.indexOfScalarPos(u8, raw, 1, '\'')) |end| {
            return raw[1..end];
        }
        return raw[1..];
    }

    // Bare value — trim trailing inline comment
    const value = if (std.mem.indexOf(u8, raw, " #")) |comment_start|
        std.mem.trimRight(u8, raw[0..comment_start], " \t")
    else
        std.mem.trimRight(u8, raw, " \t\r");

    return value;
}

/// Process basic escape sequences in double-quoted values.
fn unescape(allocator: std.mem.Allocator, input: []const u8) []const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => buf.append(allocator, '\n') catch {},
                't' => buf.append(allocator, '\t') catch {},
                'r' => buf.append(allocator, '\r') catch {},
                '\\' => buf.append(allocator, '\\') catch {},
                '"' => buf.append(allocator, '"') catch {},
                else => {
                    buf.append(allocator, '\\') catch {};
                    buf.append(allocator, next) catch {};
                },
            }
            i += 2;
        } else {
            buf.append(allocator, input[i]) catch {};
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator) catch input;
}

/// Load and parse a .env file from the filesystem.
/// Returns null if the file doesn't exist.
pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) ?ParseResult {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    return parse(allocator, content);
}

// =============================================================================
// Tests
// =============================================================================

test "parse basic entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = parse(a, "FOO=bar\nBAZ=qux\n");
    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
    try std.testing.expectEqualStrings("FOO", result.entries[0].key);
    try std.testing.expectEqualStrings("bar", result.entries[0].value);
    try std.testing.expectEqualStrings("BAZ", result.entries[1].key);
    try std.testing.expectEqualStrings("qux", result.entries[1].value);
}

test "parse skips comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = parse(arena.allocator(),
        \\# comment
        \\
        \\KEY=value
        \\# another comment
    );
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("KEY", result.entries[0].key);
}

test "parse double-quoted values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = parse(arena.allocator(), "MSG=\"hello world\"\n");
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("hello world", result.entries[0].value);
}

test "parse single-quoted values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = parse(arena.allocator(), "PATH='/usr/bin'\n");
    try std.testing.expectEqualStrings("/usr/bin", result.entries[0].value);
}

test "parse export prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = parse(arena.allocator(), "export API_KEY=secret123\n");
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("API_KEY", result.entries[0].key);
    try std.testing.expectEqualStrings("secret123", result.entries[0].value);
}

test "parse inline comments in bare values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = parse(arena.allocator(), "KEY=value # comment\n");
    try std.testing.expectEqualStrings("value", result.entries[0].value);
}

test "parse empty value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = parse(arena.allocator(), "EMPTY=\n");
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualStrings("", result.entries[0].value);
}

test "parse escape sequences in double quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = parse(arena.allocator(), "MSG=\"line1\\nline2\"\n");
    try std.testing.expectEqualStrings("line1\nline2", result.entries[0].value);
}

test "parse reports missing equals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = parse(arena.allocator(), "BADLINE\n");
    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
}
