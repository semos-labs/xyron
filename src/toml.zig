// toml.zig — Minimal TOML parser for xyron project manifests.
//
// Supports: tables, dotted keys, strings (basic + literal),
// integers, booleans, arrays. Enough for xyron.toml.

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    array: []const Value,
    table: Table,
};

pub const Table = struct {
    entries: std.StringArrayHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{ .entries = std.StringArrayHashMap(Value).init(allocator) };
    }

    /// Recursively free all owned memory.
    pub fn deinit(self: *Table) void {
        for (self.entries.values()) |*val| {
            switch (val.*) {
                .table => |*t| t.deinit(),
                .array => |arr| self.entries.allocator.free(arr),
                else => {},
            }
        }
        self.entries.deinit();
    }

    pub fn get(self: *const Table, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    pub fn getString(self: *const Table, key: []const u8) ?[]const u8 {
        if (self.entries.get(key)) |v| {
            switch (v) {
                .string => |s| return s,
                else => return null,
            }
        }
        return null;
    }

    pub fn getTable(self: *const Table, key: []const u8) ?*const Table {
        if (self.entries.getPtr(key)) |v| {
            switch (v.*) {
                .table => |*t| return t,
                else => return null,
            }
        }
        return null;
    }

    pub fn getArray(self: *const Table, key: []const u8) ?[]const Value {
        if (self.entries.get(key)) |v| {
            switch (v) {
                .array => |a| return a,
                else => return null,
            }
        }
        return null;
    }

    pub fn getStringArray(self: *const Table, key: []const u8, allocator: std.mem.Allocator) ?[]const []const u8 {
        const arr = self.getArray(key) orelse return null;
        const result = allocator.alloc([]const u8, arr.len) catch return null;
        for (arr, 0..) |v, i| {
            switch (v) {
                .string => |s| result[i] = s,
                else => {
                    allocator.free(result);
                    return null;
                },
            }
        }
        return result;
    }
};

pub const ParseError = error{
    UnexpectedChar,
    UnterminatedString,
    InvalidEscape,
    InvalidNumber,
    ExpectedEquals,
    ExpectedNewline,
    ExpectedValue,
    ExpectedBracket,
    DuplicateKey,
    OutOfMemory,
};

pub const ParseResult = struct {
    root: Table,
    err_msg: ?[]const u8 = null,
    err_line: usize = 0,
};

/// Parse a TOML string. Returns root table.
/// All returned slices point into `source` or are allocated with `allocator`.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseResult {
    var parser = Parser{
        .allocator = allocator,
        .source = source,
        .pos = 0,
        .line = 1,
    };
    return parser.parseRoot();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize,
    line: usize,

    fn parseRoot(self: *Parser) ParseResult {
        var root = Table.init(self.allocator);
        var current_table: *Table = &root;

        while (self.pos < self.source.len) {
            self.skipWhitespaceAndNewlines();
            if (self.pos >= self.source.len) break;

            const ch = self.source[self.pos];

            // Comment
            if (ch == '#') {
                self.skipLine();
                continue;
            }

            // Table header
            if (ch == '[') {
                const tbl = self.parseTableHeader(&root) catch |e| {
                    return .{ .root = root, .err_msg = self.errorMessage(e), .err_line = self.line };
                };
                current_table = tbl;
                continue;
            }

            // Key-value pair
            if (isKeyChar(ch) or ch == '"' or ch == '\'') {
                self.parseKeyValue(current_table) catch |e| {
                    return .{ .root = root, .err_msg = self.errorMessage(e), .err_line = self.line };
                };
                continue;
            }

            // Skip empty lines
            if (ch == '\n' or ch == '\r') {
                self.advance();
                continue;
            }

            return .{ .root = root, .err_msg = "unexpected character", .err_line = self.line };
        }

        return .{ .root = root };
    }

    fn parseTableHeader(self: *Parser, root: *Table) ParseError!*Table {
        self.pos += 1; // skip [

        // Read dotted key path: [a.b.c]
        var path: std.ArrayListUnmanaged([]const u8) = .{};
        defer path.deinit(self.allocator);

        while (true) {
            self.skipSpaces();
            const key = try self.parseKey();
            path.append(self.allocator, key) catch return ParseError.OutOfMemory;
            self.skipSpaces();
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                self.pos += 1;
                continue;
            }
            break;
        }

        if (self.pos >= self.source.len or self.source[self.pos] != ']')
            return ParseError.ExpectedBracket;
        self.pos += 1;

        self.skipSpaces();
        self.skipComment();
        self.skipNewline();

        // Navigate/create path in root
        var table = root;
        for (path.items) |segment| {
            if (table.entries.getPtr(segment)) |existing| {
                switch (existing.*) {
                    .table => |*t| table = t,
                    else => return ParseError.DuplicateKey,
                }
            } else {
                table.entries.put(segment, .{ .table = Table.init(self.allocator) }) catch return ParseError.OutOfMemory;
                const ptr = table.entries.getPtr(segment).?;
                table = &ptr.table;
            }
        }

        return table;
    }

    fn parseKeyValue(self: *Parser, table: *Table) ParseError!void {
        // Parse potentially dotted key
        var path: std.ArrayListUnmanaged([]const u8) = .{};
        defer path.deinit(self.allocator);

        const first_key = try self.parseKey();
        path.append(self.allocator, first_key) catch return ParseError.OutOfMemory;

        while (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.pos += 1;
            const key = try self.parseKey();
            path.append(self.allocator, key) catch return ParseError.OutOfMemory;
        }

        self.skipSpaces();
        if (self.pos >= self.source.len or self.source[self.pos] != '=')
            return ParseError.ExpectedEquals;
        self.pos += 1;
        self.skipSpaces();

        const value = try self.parseValue();

        self.skipSpaces();
        self.skipComment();

        // Navigate dotted path, creating intermediate tables
        var target = table;
        for (path.items[0 .. path.items.len - 1]) |segment| {
            if (target.entries.getPtr(segment)) |existing| {
                switch (existing.*) {
                    .table => |*t| target = t,
                    else => return ParseError.DuplicateKey,
                }
            } else {
                target.entries.put(segment, .{ .table = Table.init(self.allocator) }) catch return ParseError.OutOfMemory;
                const ptr = target.entries.getPtr(segment).?;
                target = &ptr.table;
            }
        }

        const final_key = path.items[path.items.len - 1];
        if (target.entries.contains(final_key))
            return ParseError.DuplicateKey;
        target.entries.put(final_key, value) catch return ParseError.OutOfMemory;
    }

    fn parseKey(self: *Parser) ParseError![]const u8 {
        if (self.pos >= self.source.len) return ParseError.UnexpectedChar;

        // Quoted key
        if (self.source[self.pos] == '"') return self.parseBasicString();
        if (self.source[self.pos] == '\'') return self.parseLiteralString();

        // Bare key: A-Za-z0-9_-
        const start = self.pos;
        while (self.pos < self.source.len and isKeyChar(self.source[self.pos])) {
            self.pos += 1;
        }
        if (self.pos == start) return ParseError.UnexpectedChar;
        return self.source[start..self.pos];
    }

    fn parseValue(self: *Parser) ParseError!Value {
        if (self.pos >= self.source.len) return ParseError.ExpectedValue;

        const ch = self.source[self.pos];

        if (ch == '"') return .{ .string = try self.parseBasicString() };
        if (ch == '\'') return .{ .string = try self.parseLiteralString() };
        if (ch == '[') return self.parseArray();
        if (ch == 't' or ch == 'f') return self.parseBool();
        if (ch == '-' or ch == '+' or isDigit(ch)) return self.parseNumber();

        return ParseError.ExpectedValue;
    }

    fn parseBasicString(self: *Parser) ParseError![]const u8 {
        self.pos += 1; // skip opening "
        var buf: std.ArrayListUnmanaged(u8) = .{};
        var needs_alloc = false;

        const start = self.pos;

        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == '"') {
                self.pos += 1;
                if (needs_alloc) {
                    return buf.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
                }
                buf.deinit(self.allocator);
                return self.source[start..self.pos - 1];
            }
            if (ch == '\\') {
                // Copy everything before this escape if we haven't started buffering
                if (!needs_alloc) {
                    buf.appendSlice(self.allocator, self.source[start..self.pos]) catch return ParseError.OutOfMemory;
                    needs_alloc = true;
                }
                self.pos += 1;
                if (self.pos >= self.source.len) return ParseError.InvalidEscape;
                const esc = self.source[self.pos];
                const replacement: u8 = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    else => return ParseError.InvalidEscape,
                };
                buf.append(self.allocator, replacement) catch return ParseError.OutOfMemory;
                self.pos += 1;
                continue;
            }
            if (ch == '\n') return ParseError.UnterminatedString;
            if (needs_alloc) {
                buf.append(self.allocator, ch) catch return ParseError.OutOfMemory;
            }
            self.pos += 1;
        }
        return ParseError.UnterminatedString;
    }

    fn parseLiteralString(self: *Parser) ParseError![]const u8 {
        self.pos += 1; // skip opening '
        const start = self.pos;
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '\'') {
                const result = self.source[start..self.pos];
                self.pos += 1;
                return result;
            }
            if (self.source[self.pos] == '\n') return ParseError.UnterminatedString;
            self.pos += 1;
        }
        return ParseError.UnterminatedString;
    }

    fn parseArray(self: *Parser) ParseError!Value {
        self.pos += 1; // skip [
        var items: std.ArrayListUnmanaged(Value) = .{};

        while (true) {
            self.skipWhitespaceAndNewlines();
            if (self.pos >= self.source.len) return ParseError.ExpectedBracket;
            if (self.source[self.pos] == ']') {
                self.pos += 1;
                return .{ .array = items.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory };
            }
            // Skip comments inside arrays
            if (self.source[self.pos] == '#') {
                self.skipLine();
                continue;
            }
            const val = try self.parseValue();
            items.append(self.allocator, val) catch return ParseError.OutOfMemory;
            self.skipWhitespaceAndNewlines();
            // Optional comma
            if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
            }
        }
    }

    fn parseBool(self: *Parser) ParseError!Value {
        if (self.remaining() >= 4 and std.mem.eql(u8, self.source[self.pos .. self.pos + 4], "true")) {
            self.pos += 4;
            return .{ .boolean = true };
        }
        if (self.remaining() >= 5 and std.mem.eql(u8, self.source[self.pos .. self.pos + 5], "false")) {
            self.pos += 5;
            return .{ .boolean = false };
        }
        return ParseError.ExpectedValue;
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        var negative = false;
        if (self.source[self.pos] == '-') {
            negative = true;
            self.pos += 1;
        } else if (self.source[self.pos] == '+') {
            self.pos += 1;
        }

        if (self.pos >= self.source.len or !isDigit(self.source[self.pos]))
            return ParseError.InvalidNumber;

        var value: i64 = 0;
        while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
            if (self.source[self.pos] == '_') {
                self.pos += 1;
                continue;
            }
            value = value * 10 + @as(i64, self.source[self.pos] - '0');
            self.pos += 1;
        }

        if (negative) value = -value;
        return .{ .integer = value };
    }

    // --- Helpers ---

    fn advance(self: *Parser) void {
        if (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') self.line += 1;
            self.pos += 1;
        }
    }

    fn remaining(self: *Parser) usize {
        return self.source.len - self.pos;
    }

    fn skipSpaces(self: *Parser) void {
        while (self.pos < self.source.len and (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn skipWhitespaceAndNewlines(self: *Parser) void {
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                if (ch == '\n') self.line += 1;
                self.pos += 1;
            } else break;
        }
    }

    fn skipNewline(self: *Parser) void {
        if (self.pos < self.source.len and self.source[self.pos] == '\r') self.pos += 1;
        if (self.pos < self.source.len and self.source[self.pos] == '\n') {
            self.line += 1;
            self.pos += 1;
        }
    }

    fn skipComment(self: *Parser) void {
        if (self.pos < self.source.len and self.source[self.pos] == '#') {
            self.skipLine();
        }
    }

    fn skipLine(self: *Parser) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) {
            self.line += 1;
            self.pos += 1;
        }
    }

    fn errorMessage(self: *Parser, err: ParseError) []const u8 {
        _ = self;
        return switch (err) {
            ParseError.UnexpectedChar => "unexpected character",
            ParseError.UnterminatedString => "unterminated string",
            ParseError.InvalidEscape => "invalid escape sequence",
            ParseError.InvalidNumber => "invalid number",
            ParseError.ExpectedEquals => "expected '='",
            ParseError.ExpectedNewline => "expected newline",
            ParseError.ExpectedValue => "expected value",
            ParseError.ExpectedBracket => "expected ']'",
            ParseError.DuplicateKey => "duplicate key",
            ParseError.OutOfMemory => "out of memory",
        };
    }
};

fn isKeyChar(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or
        (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or
        ch == '_' or ch == '-';
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

// =============================================================================
// Tests
// =============================================================================

test "parse basic key-value" {
    const source = "name = \"hello\"\n";
    var result = parse(std.testing.allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg == null);
    try std.testing.expectEqualStrings("hello", result.root.getString("name").?);
}

test "parse integer" {
    const source = "port = 8080\n";
    var result = parse(std.testing.allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg == null);
    const val = result.root.get("port").?;
    try std.testing.expectEqual(@as(i64, 8080), val.integer);
}

test "parse boolean" {
    const source = "enabled = true\ndisabled = false\n";
    var result = parse(std.testing.allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg == null);
    try std.testing.expectEqual(true, result.root.get("enabled").?.boolean);
    try std.testing.expectEqual(false, result.root.get("disabled").?.boolean);
}

test "parse array" {
    const source = "items = [\"a\", \"b\", \"c\"]\n";
    var result = parse(std.testing.allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg == null);
    const arr = result.root.getArray("items").?;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualStrings("a", arr[0].string);
    try std.testing.expectEqualStrings("c", arr[2].string);
}

test "parse table" {
    const source =
        \\[project]
        \\name = "test"
        \\
        \\[commands]
        \\dev = "npm run dev"
    ;
    var result = parse(std.testing.allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg == null);
    const project_tbl = result.root.getTable("project").?;
    try std.testing.expectEqualStrings("test", project_tbl.getString("name").?);
    const commands = result.root.getTable("commands").?;
    try std.testing.expectEqualStrings("npm run dev", commands.getString("dev").?);
}

test "parse dotted table" {
    const source =
        \\[commands.test]
        \\command = "npm test"
        \\cwd = "./packages/core"
    ;
    var result = parse(std.testing.allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg == null);
    const commands = result.root.getTable("commands").?;
    const test_cmd = commands.getTable("test").?;
    try std.testing.expectEqualStrings("npm test", test_cmd.getString("command").?);
    try std.testing.expectEqualStrings("./packages/core", test_cmd.getString("cwd").?);
}

test "parse comments" {
    const source =
        \\# This is a comment
        \\name = "hello" # inline comment
    ;
    var result = parse(std.testing.allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg == null);
    try std.testing.expectEqualStrings("hello", result.root.getString("name").?);
}

test "parse literal string" {
    const source = "path = 'C:\\Users\\test'\n";
    var result = parse(std.testing.allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg == null);
    try std.testing.expectEqualStrings("C:\\Users\\test", result.root.getString("path").?);
}

test "parse escape sequences" {
    const allocator = std.testing.allocator;
    const source = "msg = \"hello\\nworld\"\n";
    var result = parse(allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg == null);
    const s = result.root.getString("msg").?;
    try std.testing.expectEqualStrings("hello\nworld", s);
    allocator.free(s);
}

test "error on invalid toml" {
    const source = "= bad\n";
    var result = parse(std.testing.allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg != null);
}

test "parse full project manifest" {
    const source =
        \\[project]
        \\name = "my-app"
        \\
        \\[commands]
        \\dev = "npm run dev"
        \\build = "npm run build"
        \\
        \\[commands.test]
        \\command = "npm test"
        \\cwd = "./packages/core"
        \\
        \\[env]
        \\sources = [".env", ".env.local"]
        \\
        \\[secrets]
        \\required = ["API_KEY", "DB_URL"]
        \\
        \\[services.db]
        \\command = "docker compose up db"
        \\
        \\[services.redis]
        \\command = "docker compose up redis"
        \\cwd = "./infra"
    ;
    var result = parse(std.testing.allocator, source);
    defer result.root.deinit();
    try std.testing.expect(result.err_msg == null);

    // project
    const project_tbl = result.root.getTable("project").?;
    try std.testing.expectEqualStrings("my-app", project_tbl.getString("name").?);

    // commands
    const commands = result.root.getTable("commands").?;
    try std.testing.expectEqualStrings("npm run dev", commands.getString("dev").?);
    const test_cmd = commands.getTable("test").?;
    try std.testing.expectEqualStrings("npm test", test_cmd.getString("command").?);

    // env
    const env_tbl = result.root.getTable("env").?;
    const sources = env_tbl.getArray("sources").?;
    try std.testing.expectEqual(@as(usize, 2), sources.len);

    // secrets
    const secrets = result.root.getTable("secrets").?;
    const required = secrets.getArray("required").?;
    try std.testing.expectEqual(@as(usize, 2), required.len);

    // services
    const services = result.root.getTable("services").?;
    const db = services.getTable("db").?;
    try std.testing.expectEqualStrings("docker compose up db", db.getString("command").?);
}
