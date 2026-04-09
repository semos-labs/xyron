// expand.zig — Variable and tilde expansion.
//
// Operates on parsed AST between parse and plan phases. Produces
// new argv slices with $NAME expanded from the shell environment
// and ~ expanded to $HOME. Single-quoted strings are left as-is.

const std = @import("std");
const ast = @import("ast.zig");
const environ_mod = @import("environ.zig");
const glob = @import("glob.zig");
const brace = @import("brace.zig");

/// Shell state needed for special variable expansion ($?, $$, $!).
pub const SpecialVars = struct {
    exit_code: u8 = 0,
    shell_pid: i32 = 0,
    last_bg_pid: i32 = 0,
};

/// Callback for command substitution — executes a command and returns its output.
/// The caller owns the returned slice.
pub const CmdSubFn = *const fn (allocator: std.mem.Allocator, cmd: []const u8) ?[]const u8;

/// Expansion context passed through all expansion phases.
const ExpandCtx = struct {
    env: *const environ_mod.Environ,
    special: SpecialVars,
    cmd_sub: ?CmdSubFn = null,
};

/// Expand all commands in a pipeline.
/// Returns a new Pipeline with expanded arguments. Caller owns the result.
pub fn expandPipeline(
    allocator: std.mem.Allocator,
    pipeline: *const ast.Pipeline,
    env: *const environ_mod.Environ,
) !ast.Pipeline {
    return expandPipelineWithVars(allocator, pipeline, env, .{}, null);
}

/// Expand all commands in a pipeline with special variable context.
pub fn expandPipelineWithVars(
    allocator: std.mem.Allocator,
    pipeline: *const ast.Pipeline,
    env: *const environ_mod.Environ,
    special: SpecialVars,
    cmd_sub: ?CmdSubFn,
) !ast.Pipeline {
    const ctx = ExpandCtx{ .env = env, .special = special, .cmd_sub = cmd_sub };
    const commands = try allocator.alloc(ast.SimpleCommand, pipeline.commands.len);
    errdefer allocator.free(commands);

    for (pipeline.commands, 0..) |cmd, i| {
        commands[i] = try expandCommand(allocator, &cmd, ctx);
    }

    return .{ .commands = commands, .background = pipeline.background };
}

/// Expand a single command's argv and redirect paths.
/// Glob expansion can turn one argument into many, so argv length may grow.
fn expandCommand(
    allocator: std.mem.Allocator,
    cmd: *const ast.SimpleCommand,
    ctx: ExpandCtx,
) !ast.SimpleCommand {
    // Expand argv — use ArrayList because globs can produce multiple entries
    var argv_list: std.ArrayList([]const u8) = .{};
    errdefer {
        for (argv_list.items) |a| allocator.free(a);
        argv_list.deinit(allocator);
    }

    for (cmd.argv, 0..) |arg, i| {
        const is_quoted = if (cmd.quoted.len > i) cmd.quoted[i] else false;
        if (is_quoted) {
            try argv_list.append(allocator, try allocator.dupe(u8, arg));
        } else {
            const expanded_word = try expandWord(allocator, arg, ctx);

            // Phase: brace expansion (one word → many words)
            const brace_words = if (brace.containsBrace(expanded_word)) blk: {
                const bw = try brace.expand(allocator, expanded_word);
                allocator.free(expanded_word);
                break :blk bw;
            } else blk: {
                // Wrap single word in a slice for uniform processing
                const single = try allocator.alloc([]const u8, 1);
                single[0] = expanded_word;
                break :blk single;
            };
            defer allocator.free(brace_words);

            // Phase: glob expansion (each brace result may contain globs)
            for (brace_words) |bw| {
                if (glob.containsGlob(bw)) {
                    const matches = try glob.expand(allocator, bw);
                    defer allocator.free(matches);
                    allocator.free(bw);
                    for (matches) |match| {
                        try argv_list.append(allocator, match);
                    }
                } else {
                    try argv_list.append(allocator, bw);
                }
            }
        }
    }

    // Expand redirect paths
    const redirects = try allocator.alloc(ast.Redirect, cmd.redirects.len);
    for (cmd.redirects, 0..) |redir, i| {
        redirects[i] = .{
            .kind = redir.kind,
            .path = try expandWord(allocator, redir.path, ctx),
        };
    }

    return .{
        .argv = try argv_list.toOwnedSlice(allocator),
        .redirects = redirects,
        .env_overrides = cmd.env_overrides,
        .quoted = &.{}, // expanded pipeline doesn't need quoted flags
    };
}

/// Expand a single word: tilde expansion, then variable/command substitution expansion.
fn expandWord(
    allocator: std.mem.Allocator,
    word: []const u8,
    ctx: ExpandCtx,
) ![]const u8 {
    // Phase 1: tilde expansion on the raw word
    const tilde_expanded = tildeExpand(allocator, word, ctx.env) catch word;

    // Phase 2: variable + command substitution expansion
    if (std.mem.indexOf(u8, tilde_expanded, "$") == null) {
        // No variables to expand — return as-is (already allocated or original)
        if (tilde_expanded.ptr != word.ptr) return tilde_expanded;
        return try allocator.dupe(u8, word);
    }

    return varExpand(allocator, tilde_expanded, ctx);
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

/// Expand $NAME, special variables, and $(cmd) in a string.
fn varExpand(
    allocator: std.mem.Allocator,
    input: []const u8,
    ctx: ExpandCtx,
) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len) {
            const next = input[i + 1];

            // Command substitution: $(cmd)
            if (next == '(') {
                if (findMatchingParen(input, i + 1)) |end| {
                    const cmd_str = input[i + 2 .. end];
                    if (ctx.cmd_sub) |exec| {
                        if (exec(allocator, cmd_str)) |output| {
                            defer allocator.free(output);
                            // Strip trailing newlines (standard shell behavior)
                            var out = output;
                            while (out.len > 0 and out[out.len - 1] == '\n') out = out[0 .. out.len - 1];
                            try result.appendSlice(allocator, out);
                        }
                    }
                    i = end + 1;
                } else {
                    // Unmatched $( — pass through as literal
                    try result.append(allocator, input[i]);
                    i += 1;
                }
            }
            // Special variables: $?, $$, $!
            else if (next == '?' or next == '!' or next == '$') {
                var buf: [20]u8 = undefined;
                const val: i32 = switch (next) {
                    '?' => @intCast(ctx.special.exit_code),
                    '$' => ctx.special.shell_pid,
                    '!' => ctx.special.last_bg_pid,
                    else => unreachable,
                };
                const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "";
                try result.appendSlice(allocator, s);
                i += 2;
            } else if (isVarStart(next)) {
                // Found $NAME
                i += 1; // skip $
                const name_start = i;
                while (i < input.len and isVarChar(input[i])) : (i += 1) {}
                const name = input[name_start..i];
                const value = ctx.env.get(name) orelse "";
                try result.appendSlice(allocator, value);
            } else {
                try result.append(allocator, input[i]);
                i += 1;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Find the closing ')' for an opening '(' at position `open`, respecting nesting.
fn findMatchingParen(input: []const u8, open: usize) ?usize {
    var depth: u32 = 0;
    var i = open;
    while (i < input.len) {
        if (input[i] == '(') {
            depth += 1;
        } else if (input[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
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

    const result = try varExpand(std.testing.allocator, "hello $FOO world", .{ .env = &env, .special = .{} });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello bar world", result);
}

test "missing variable expands to empty" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "hello $MISSING", .{ .env = &env, .special = .{} });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello ", result);
}

test "no expansion needed" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try expandWord(std.testing.allocator, "plain", .{ .env = &env, .special = .{} });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("plain", result);
}

test "special variable $? expands to exit code" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "code=$?", .{ .env = &env, .special = .{ .exit_code = 42 } });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("code=42", result);
}

test "special variable $$ expands to shell pid" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "pid=$$", .{ .env = &env, .special = .{ .shell_pid = 1234 } });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("pid=1234", result);
}

test "special variable $! expands to last bg pid" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "bg=$!", .{ .env = &env, .special = .{ .last_bg_pid = 5678 } });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("bg=5678", result);
}

fn testCmdSub(_: std.mem.Allocator, cmd: []const u8) ?[]const u8 {
    // Simple mock: return the command itself reversed for testing
    _ = cmd;
    return null;
}

fn testCmdSubEcho(allocator: std.mem.Allocator, cmd: []const u8) ?[]const u8 {
    // Mock that returns the command text (simulates echo)
    return allocator.dupe(u8, cmd) catch null;
}

test "command substitution with mock" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "hello $(world)", .{
        .env = &env,
        .special = .{},
        .cmd_sub = &testCmdSubEcho,
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "command substitution without callback passes through empty" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "hello $(world)", .{
        .env = &env,
        .special = .{},
        .cmd_sub = null,
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello ", result);
}

test "nested command substitution" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    // findMatchingParen should correctly handle nesting
    const result = try varExpand(std.testing.allocator, "$(echo $(inner))", .{
        .env = &env,
        .special = .{},
        .cmd_sub = &testCmdSubEcho,
    });
    defer std.testing.allocator.free(result);
    // The outer $() captures "echo $(inner)" and the mock returns it as-is
    try std.testing.expectEqualStrings("echo $(inner)", result);
}
