// expand.zig — Variable and tilde expansion.
//
// Operates on parsed AST between parse and plan phases. Produces
// new argv slices with $NAME expanded from the shell environment
// and ~ expanded to $HOME. Single-quoted strings are left as-is.

const std = @import("std");
const ast = @import("ast.zig");
const environ_mod = @import("environ.zig");

/// Expand all commands in a pipeline.
/// Returns a new Pipeline with expanded arguments. Caller owns the result.
pub fn expandPipeline(
    allocator: std.mem.Allocator,
    pipeline: *const ast.Pipeline,
    env: *const environ_mod.Environ,
) !ast.Pipeline {
    const commands = try allocator.alloc(ast.SimpleCommand, pipeline.commands.len);
    errdefer allocator.free(commands);

    for (pipeline.commands, 0..) |cmd, i| {
        commands[i] = try expandCommand(allocator, &cmd, env);
    }

    return .{ .commands = commands, .background = pipeline.background };
}

/// Expand a single command's argv and redirect paths.
fn expandCommand(
    allocator: std.mem.Allocator,
    cmd: *const ast.SimpleCommand,
    env: *const environ_mod.Environ,
) !ast.SimpleCommand {
    // Expand argv
    const argv = try allocator.alloc([]const u8, cmd.argv.len);
    for (cmd.argv, 0..) |arg, i| {
        const is_quoted = if (cmd.quoted.len > i) cmd.quoted[i] else false;
        argv[i] = if (is_quoted) try allocator.dupe(u8, arg) else try expandWord(allocator, arg, env);
    }

    // Expand redirect paths
    const redirects = try allocator.alloc(ast.Redirect, cmd.redirects.len);
    for (cmd.redirects, 0..) |redir, i| {
        redirects[i] = .{
            .kind = redir.kind,
            .path = try expandWord(allocator, redir.path, env),
        };
    }

    return .{
        .argv = argv,
        .redirects = redirects,
        .env_overrides = cmd.env_overrides,
        .quoted = &.{}, // expanded pipeline doesn't need quoted flags
    };
}

/// Expand a single word: tilde expansion then variable expansion.
fn expandWord(
    allocator: std.mem.Allocator,
    word: []const u8,
    env: *const environ_mod.Environ,
) ![]const u8 {
    // Phase 1: tilde expansion on the raw word
    const tilde_expanded = tildeExpand(allocator, word, env) catch word;

    // Phase 2: variable expansion
    if (std.mem.indexOf(u8, tilde_expanded, "$") == null) {
        // No variables to expand — return as-is (already allocated or original)
        if (tilde_expanded.ptr != word.ptr) return tilde_expanded;
        return try allocator.dupe(u8, word);
    }

    return varExpand(allocator, tilde_expanded, env);
}

/// Expand leading ~ to $HOME.
fn tildeExpand(
    allocator: std.mem.Allocator,
    word: []const u8,
    env: *const environ_mod.Environ,
) ![]const u8 {
    if (word.len == 0 or word[0] != '~') return word;

    const home_val = env.home() orelse return word;

    // Bare ~
    if (word.len == 1) return try allocator.dupe(u8, home_val);

    // ~/path
    if (word[1] == '/') {
        const result = try allocator.alloc(u8, home_val.len + word.len - 1);
        @memcpy(result[0..home_val.len], home_val);
        @memcpy(result[home_val.len..], word[1..]);
        return result;
    }

    // ~user form (not supported) — return as-is
    return word;
}

/// Expand $NAME references in a string.
fn varExpand(
    allocator: std.mem.Allocator,
    input: []const u8,
    env: *const environ_mod.Environ,
) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len and isVarStart(input[i + 1])) {
            // Found $NAME
            i += 1; // skip $
            const name_start = i;
            while (i < input.len and isVarChar(input[i])) : (i += 1) {}
            const name = input[name_start..i];
            const value = env.get(name) orelse "";
            try result.appendSlice(allocator, value);
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Valid first character of a variable name: [A-Za-z_]
fn isVarStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

/// Valid subsequent character of a variable name: [A-Za-z0-9_]
fn isVarChar(c: u8) bool {
    return isVarStart(c) or (c >= '0' and c <= '9');
}

/// Free an expanded pipeline's allocations.
pub fn freeExpandedPipeline(allocator: std.mem.Allocator, pipeline: *ast.Pipeline) void {
    for (pipeline.commands) |cmd| {
        for (cmd.argv) |arg| allocator.free(arg);
        allocator.free(cmd.argv);
        for (cmd.redirects) |redir| allocator.free(redir.path);
        allocator.free(cmd.redirects);
    }
    allocator.free(pipeline.commands);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "tilde expansion to HOME" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/home/user");
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try tildeExpand(std.testing.allocator, "~/docs", &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/docs", result);
}

test "bare tilde expands to HOME" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/home/user");
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try tildeExpand(std.testing.allocator, "~", &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/home/user", result);
}

test "variable expansion" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("FOO", "bar");
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "hello $FOO world", &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello bar world", result);
}

test "missing variable expands to empty" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "hello $MISSING", &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello ", result);
}

test "no expansion needed" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try expandWord(std.testing.allocator, "plain", &env);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("plain", result);
}
