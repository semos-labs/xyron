// token.zig — Lexer for shell input.
//
// Tokenizes a line of input into a sequence of tokens: words, pipe
// operators, and redirect operators. Supports basic single/double
// quoting. Single-quoted tokens are flagged so the expander can skip
// variable expansion on them.

const std = @import("std");

// ---------------------------------------------------------------------------
// Token types
// ---------------------------------------------------------------------------

pub const TokenKind = enum {
    word,
    pipe,
    redirect_in,
    redirect_out,
    redirect_err,
    ampersand, // &
};

pub const Token = struct {
    kind: TokenKind,
    value: []const u8,
    /// True if this token was single-quoted (no expansion).
    single_quoted: bool = false,
};

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

pub fn tokenize(allocator: std.mem.Allocator, input: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .{};
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    // Track if current pipe segment starts with a command that uses
    // > < as comparison operators (where, query), not redirects.
    var in_comparison_context = isComparisonCmd(input);

    while (i < input.len) {
        if (input[i] == ' ' or input[i] == '\t') {
            i += 1;
            continue;
        }

        if (input[i] == '|') {
            try tokens.append(allocator, .{ .kind = .pipe, .value = input[i .. i + 1] });
            i += 1;
            in_comparison_context = false;
            // Check if next word is a comparison command
            var peek = i;
            while (peek < input.len and (input[peek] == ' ' or input[peek] == '\t')) : (peek += 1) {}
            if (isComparisonCmd(input[peek..])) in_comparison_context = true;
            continue;
        }

        if (input[i] == '2' and i + 1 < input.len and input[i + 1] == '>' and !in_comparison_context) {
            try tokens.append(allocator, .{ .kind = .redirect_err, .value = input[i .. i + 2] });
            i += 2;
            continue;
        }

        if (input[i] == '>' and !in_comparison_context) {
            // Check for >=
            if (i + 1 < input.len and input[i + 1] == '=') {
                try tokens.append(allocator, .{ .kind = .redirect_out, .value = input[i .. i + 2] });
                i += 2;
            } else {
                try tokens.append(allocator, .{ .kind = .redirect_out, .value = input[i .. i + 1] });
                i += 1;
            }
            continue;
        }

        if (input[i] == '<' and !in_comparison_context) {
            if (i + 1 < input.len and input[i + 1] == '=') {
                try tokens.append(allocator, .{ .kind = .redirect_in, .value = input[i .. i + 2] });
                i += 2;
            } else {
                try tokens.append(allocator, .{ .kind = .redirect_in, .value = input[i .. i + 1] });
                i += 1;
            }
            continue;
        }

        // In comparison context, treat > < >= <= as words
        if (in_comparison_context and (input[i] == '>' or input[i] == '<')) {
            var end = i + 1;
            if (end < input.len and input[end] == '=') end += 1;
            try tokens.append(allocator, .{ .kind = .word, .value = input[i..end] });
            i = end;
            continue;
        }

        // Background operator
        if (input[i] == '&') {
            try tokens.append(allocator, .{ .kind = .ampersand, .value = input[i .. i + 1] });
            i += 1;
            continue;
        }

        // Single-quoted string — no expansion
        if (input[i] == '\'') {
            i += 1;
            const start = i;
            while (i < input.len and input[i] != '\'') : (i += 1) {}
            try tokens.append(allocator, .{
                .kind = .word,
                .value = input[start..i],
                .single_quoted = true,
            });
            if (i < input.len) i += 1;
            continue;
        }

        // Double-quoted string — allows expansion
        if (input[i] == '"') {
            i += 1;
            const start = i;
            while (i < input.len and input[i] != '"') : (i += 1) {}
            try tokens.append(allocator, .{
                .kind = .word,
                .value = input[start..i],
                .single_quoted = false,
            });
            if (i < input.len) i += 1;
            continue;
        }

        // Bare word
        const start = i;
        while (i < input.len) {
            const c = input[i];
            if (c == ' ' or c == '\t' or c == '|' or c == '>' or c == '<') break;
            i += 1;
        }
        if (i > start) {
            try tokens.append(allocator, .{ .kind = .word, .value = input[start..i] });
        }
    }

    return tokens.toOwnedSlice(allocator);
}

pub fn freeTokens(allocator: std.mem.Allocator, tokens: []Token) void {
    allocator.free(tokens);
}

/// Check if a string starts with a command that uses > < as comparison ops.
fn isComparisonCmd(s: []const u8) bool {
    // Skip leading whitespace
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    const rest = s[i..];
    return std.mem.startsWith(u8, rest, "where ") or
        std.mem.startsWith(u8, rest, "query ") or
        std.mem.eql(u8, rest, "where") or
        std.mem.eql(u8, rest, "query");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "empty input" {
    const tokens = try tokenize(std.testing.allocator, "");
    defer freeTokens(std.testing.allocator, tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "simple command" {
    const tokens = try tokenize(std.testing.allocator, "ls -la");
    defer freeTokens(std.testing.allocator, tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("ls", tokens[0].value);
}

test "pipeline" {
    const tokens = try tokenize(std.testing.allocator, "cat file | grep foo");
    defer freeTokens(std.testing.allocator, tokens);
    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqual(TokenKind.pipe, tokens[2].kind);
}

test "single-quoted token is flagged" {
    const tokens = try tokenize(std.testing.allocator, "echo '$HOME'");
    defer freeTokens(std.testing.allocator, tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expect(tokens[1].single_quoted);
    try std.testing.expectEqualStrings("$HOME", tokens[1].value);
}

test "double-quoted token is not flagged" {
    const tokens = try tokenize(std.testing.allocator, "echo \"$HOME\"");
    defer freeTokens(std.testing.allocator, tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expect(!tokens[1].single_quoted);
}

test "stderr redirect" {
    const tokens = try tokenize(std.testing.allocator, "cmd 2> err.txt");
    defer freeTokens(std.testing.allocator, tokens);
    try std.testing.expectEqual(TokenKind.redirect_err, tokens[1].kind);
}

test "adjacent redirect" {
    const tokens = try tokenize(std.testing.allocator, "echo>file");
    defer freeTokens(std.testing.allocator, tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(TokenKind.redirect_out, tokens[1].kind);
}
