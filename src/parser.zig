// parser.zig — Transforms a token stream into an AST.
//
// Handles pipe operators, redirect attachment, and inline environment
// assignments (FOO=bar before a command).

const std = @import("std");
const ast = @import("ast.zig");
const environ_mod = @import("environ.zig");
const token_mod = @import("token.zig");
const Token = token_mod.Token;
const TokenKind = token_mod.TokenKind;

pub const ParseError = error{
    EmptyInput,
    UnexpectedPipe,
    MissingRedirectTarget,
    EmptyPipelineSegment,
    OutOfMemory,
};

/// Parse a raw input line into a Pipeline AST.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!ast.Pipeline {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len == 0) return ParseError.EmptyInput;

    const tokens = token_mod.tokenize(allocator, trimmed) catch return ParseError.OutOfMemory;
    defer token_mod.freeTokens(allocator, tokens);

    if (tokens.len == 0) return ParseError.EmptyInput;

    return parsePipeline(allocator, tokens);
}

/// Check if the last token is an ampersand (background operator).
/// If so, return the tokens without it and set background flag.
fn stripBackground(tokens: []const Token) struct { tokens: []const Token, background: bool } {
    if (tokens.len > 0 and tokens[tokens.len - 1].kind == .ampersand) {
        return .{ .tokens = tokens[0 .. tokens.len - 1], .background = true };
    }
    return .{ .tokens = tokens, .background = false };
}

fn parsePipeline(allocator: std.mem.Allocator, tokens: []const Token) ParseError!ast.Pipeline {
    // Check for trailing & (background operator)
    const bg = stripBackground(tokens);
    const effective_tokens = bg.tokens;

    if (effective_tokens.len == 0) return ParseError.EmptyInput;

    var commands: std.ArrayList(ast.SimpleCommand) = .{};
    errdefer {
        for (commands.items) |cmd| freeCmd(allocator, cmd);
        commands.deinit(allocator);
    }

    var seg_start: usize = 0;
    var i: usize = 0;

    while (i <= effective_tokens.len) {
        const at_pipe = (i < effective_tokens.len and effective_tokens[i].kind == .pipe);
        const at_end = (i == effective_tokens.len);

        if (at_pipe or at_end) {
            if (seg_start == i) return ParseError.EmptyPipelineSegment;
            const cmd = try parseSimpleCommand(allocator, effective_tokens[seg_start..i]);
            commands.append(allocator, cmd) catch return ParseError.OutOfMemory;
            seg_start = i + 1;
        }
        i += 1;
    }

    if (commands.items.len == 0) return ParseError.EmptyInput;

    return .{
        .commands = commands.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .background = bg.background,
    };
}

fn parseSimpleCommand(allocator: std.mem.Allocator, tokens: []const Token) ParseError!ast.SimpleCommand {
    var argv: std.ArrayList([]const u8) = .{};
    errdefer argv.deinit(allocator);
    var quoted_flags: std.ArrayList(bool) = .{};
    errdefer quoted_flags.deinit(allocator);
    var redirects: std.ArrayList(ast.Redirect) = .{};
    errdefer redirects.deinit(allocator);
    var env_overrides: std.ArrayList(environ_mod.EnvOverride) = .{};
    errdefer env_overrides.deinit(allocator);

    var i: usize = 0;
    var past_assignments = false;

    while (i < tokens.len) {
        switch (tokens[i].kind) {
            .word => {
                // Check for inline env assignment (only before first non-assignment word)
                if (!past_assignments and !tokens[i].single_quoted and isAssignment(tokens[i].value)) {
                    const eq_pos = std.mem.indexOf(u8, tokens[i].value, "=").?;
                    env_overrides.append(allocator, .{
                        .key = tokens[i].value[0..eq_pos],
                        .value = tokens[i].value[eq_pos + 1 ..],
                    }) catch return ParseError.OutOfMemory;
                    i += 1;
                    continue;
                }
                past_assignments = true;
                argv.append(allocator, tokens[i].value) catch return ParseError.OutOfMemory;
                quoted_flags.append(allocator, tokens[i].single_quoted) catch return ParseError.OutOfMemory;
                i += 1;
            },
            .redirect_in, .redirect_out, .redirect_err => {
                past_assignments = true;
                const kind: ast.RedirectKind = switch (tokens[i].kind) {
                    .redirect_in => .stdin,
                    .redirect_out => .stdout,
                    .redirect_err => .stderr,
                    else => unreachable,
                };
                i += 1;
                if (i >= tokens.len or tokens[i].kind != .word)
                    return ParseError.MissingRedirectTarget;
                redirects.append(allocator, .{ .kind = kind, .path = tokens[i].value }) catch return ParseError.OutOfMemory;
                i += 1;
            },
            .redirect_dup => {
                past_assignments = true;
                redirects.append(allocator, .{ .kind = .dup, .path = tokens[i].value }) catch return ParseError.OutOfMemory;
                i += 1;
            },
            .pipe, .ampersand => return ParseError.UnexpectedPipe,
        }
    }

    // Allow bare assignments (FOO=bar with no command) — argv will be empty
    return .{
        .argv = argv.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .redirects = redirects.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .env_overrides = env_overrides.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
        .quoted = quoted_flags.toOwnedSlice(allocator) catch return ParseError.OutOfMemory,
    };
}

/// Check if a token value looks like NAME=VALUE.
fn isAssignment(value: []const u8) bool {
    const eq_pos = std.mem.indexOf(u8, value, "=") orelse return false;
    if (eq_pos == 0) return false;
    // Check that part before = is a valid identifier
    for (value[0..eq_pos], 0..) |c, j| {
        if (j == 0) {
            if (!isVarStart(c)) return false;
        } else {
            if (!isVarChar(c)) return false;
        }
    }
    return true;
}

fn isVarStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isVarChar(c: u8) bool {
    return isVarStart(c) or (c >= '0' and c <= '9');
}

fn freeCmd(allocator: std.mem.Allocator, cmd: ast.SimpleCommand) void {
    if (cmd.redirects.len > 0) allocator.free(cmd.redirects);
    if (cmd.argv.len > 0) allocator.free(cmd.argv);
    if (cmd.env_overrides.len > 0) allocator.free(cmd.env_overrides);
    if (cmd.quoted.len > 0) allocator.free(cmd.quoted);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse simple command" {
    var p = try parse(std.testing.allocator, "ls -la /tmp");
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), p.commands.len);
    try std.testing.expectEqual(@as(usize, 3), p.commands[0].argv.len);
}

test "parse pipeline" {
    var p = try parse(std.testing.allocator, "cat file | grep foo");
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), p.commands.len);
    try std.testing.expect(p.isPipe());
}

test "parse inline env assignment" {
    var p = try parse(std.testing.allocator, "FOO=bar ls");
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), p.commands[0].env_overrides.len);
    try std.testing.expectEqualStrings("FOO", p.commands[0].env_overrides[0].key);
    try std.testing.expectEqualStrings("bar", p.commands[0].env_overrides[0].value);
    try std.testing.expectEqual(@as(usize, 1), p.commands[0].argv.len);
}

test "parse bare assignment" {
    var p = try parse(std.testing.allocator, "FOO=bar");
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), p.commands[0].env_overrides.len);
    try std.testing.expectEqual(@as(usize, 0), p.commands[0].argv.len);
}

test "parse multiple assignments" {
    var p = try parse(std.testing.allocator, "A=1 B=2 cmd");
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), p.commands[0].env_overrides.len);
    try std.testing.expectEqual(@as(usize, 1), p.commands[0].argv.len);
}

test "parse redirect" {
    var p = try parse(std.testing.allocator, "echo hello > out.txt");
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), p.commands[0].redirects.len);
}

test "empty input returns EmptyInput" {
    try std.testing.expectError(ParseError.EmptyInput, parse(std.testing.allocator, "   "));
}

test "missing redirect target" {
    try std.testing.expectError(ParseError.MissingRedirectTarget, parse(std.testing.allocator, "echo >"));
}

test "fd dup redirect parsed" {
    var p = try parse(std.testing.allocator, "cmd 2>&1 | grep foo");
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), p.commands.len);
    try std.testing.expectEqual(@as(usize, 1), p.commands[0].redirects.len);
    try std.testing.expectEqual(ast.RedirectKind.dup, p.commands[0].redirects[0].kind);
    try std.testing.expectEqualStrings("2>&1", p.commands[0].redirects[0].path);
}
