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

    // Expand redirect paths (skip expansion for heredoc/herestring — content is pre-set)
    const redirects = try allocator.alloc(ast.Redirect, cmd.redirects.len);
    for (cmd.redirects, 0..) |redir, i| {
        if (redir.kind == .heredoc or redir.kind == .herestring) {
            redirects[i] = .{
                .kind = redir.kind,
                .path = try allocator.dupe(u8, redir.path),
                .content = redir.content,
            };
        } else {
            redirects[i] = .{
                .kind = redir.kind,
                .path = try expandWord(allocator, redir.path, ctx),
            };
        }
    }

    return .{
        .argv = try argv_list.toOwnedSlice(allocator),
        .redirects = redirects,
        .env_overrides = cmd.env_overrides,
        .quoted = &.{}, // expanded pipeline doesn't need quoted flags
    };
}

/// Expand a single word: process substitution, tilde expansion, then variable/command substitution.
fn expandWord(
    allocator: std.mem.Allocator,
    word: []const u8,
    ctx: ExpandCtx,
) ![]const u8 {
    // Phase 0: process substitution <(cmd) or >(cmd)
    if (word.len > 3 and (word[0] == '<' or word[0] == '>') and word[1] == '(' and word[word.len - 1] == ')') {
        const cmd_str = word[2 .. word.len - 1];
        const is_input = word[0] == '<'; // <(cmd) = read from cmd's stdout
        return processSubstitution(allocator, cmd_str, is_input);
    }

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

/// Fork a subprocess for process substitution and return /dev/fd/N.
/// For <(cmd): cmd's stdout is connected to the returned FD (read from it).
/// For >(cmd): cmd's stdin is connected to the returned FD (write to it).
fn processSubstitution(allocator: std.mem.Allocator, cmd: []const u8, is_input: bool) ![]const u8 {
    const posix = std.posix;
    const pipe_fds = try posix.pipe2(.{});

    const pid = try posix.fork();
    if (pid == 0) {
        // Child process
        if (is_input) {
            // <(cmd): child writes to pipe, parent reads
            posix.close(pipe_fds[0]); // close read end
            posix.dup2(pipe_fds[1], posix.STDOUT_FILENO) catch std.process.exit(126);
            posix.close(pipe_fds[1]);
        } else {
            // >(cmd): child reads from pipe, parent writes
            posix.close(pipe_fds[1]); // close write end
            posix.dup2(pipe_fds[0], posix.STDIN_FILENO) catch std.process.exit(126);
            posix.close(pipe_fds[0]);
        }

        // Exec via /bin/sh -c
        var cmd_buf: [4096]u8 = undefined;
        if (cmd.len < cmd_buf.len) {
            @memcpy(cmd_buf[0..cmd.len], cmd);
            cmd_buf[cmd.len] = 0;
            const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);
            const sh: [*:0]const u8 = "/bin/sh";
            const c_flag: [*:0]const u8 = "-c";
            const argv2 = [_:null]?[*:0]const u8{ sh, c_flag, cmd_z, null };
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            _ = posix.execvpeZ(sh, @ptrCast(&argv2), envp) catch {};
        }
        std.process.exit(127);
    }

    // Parent
    if (is_input) {
        posix.close(pipe_fds[1]); // close write end — child writes
        // Return /dev/fd/N for the read end
        var buf: [24]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/dev/fd/{d}", .{pipe_fds[0]}) catch return error.OutOfMemory;
        return allocator.dupe(u8, path);
    } else {
        posix.close(pipe_fds[0]); // close read end — child reads
        var buf: [24]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/dev/fd/{d}", .{pipe_fds[1]}) catch return error.OutOfMemory;
        return allocator.dupe(u8, path);
    }
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
            // Parameter expansion: ${var}, ${var:-default}, ${var%pattern}, etc.
            else if (next == '{') {
                if (std.mem.indexOf(u8, input[i + 2 ..], "}")) |rel_close| {
                    const close = i + 2 + rel_close;
                    const inner = input[i + 2 .. close];
                    const expanded = paramExpand(inner, ctx.env);
                    try result.appendSlice(allocator, expanded);
                    i = close + 1;
                } else {
                    // Unmatched ${ — pass through
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

/// Expand a parameter expression inside ${...}.
/// Supports: ${var}, ${var:-default}, ${var:=default}, ${var:+alternate},
/// ${var#pattern}, ${var##pattern}, ${var%pattern}, ${var%%pattern}.
fn paramExpand(inner: []const u8, env: *const environ_mod.Environ) []const u8 {
    if (inner.len == 0) return "";

    // Find the operator position — scan for :, #, or %
    var name_end: usize = 0;
    while (name_end < inner.len and isVarChar(inner[name_end])) : (name_end += 1) {}

    // Handle first char specially for isVarStart
    if (name_end == 0 or !isVarStart(inner[0])) return "";

    const name = inner[0..name_end];
    const value = env.get(name);
    const is_set = value != null;
    const val = value orelse "";
    const is_empty = val.len == 0;

    // ${var} — bare expansion
    if (name_end == inner.len) return val;

    const op_start = name_end;
    const rest = inner[op_start..];

    // ${var:-default} / ${var:=default} / ${var:+alternate}
    if (rest.len >= 2 and rest[0] == ':') {
        const rhs = rest[2..];
        return switch (rest[1]) {
            '-' => if (!is_set or is_empty) rhs else val,
            '=' => if (!is_set or is_empty) rhs else val,
            '+' => if (is_set and !is_empty) rhs else "",
            else => val,
        };
    }

    // ${var#pattern} / ${var##pattern} — remove prefix
    if (rest.len >= 1 and rest[0] == '#') {
        const greedy = rest.len >= 2 and rest[1] == '#';
        const pattern = if (greedy) rest[2..] else rest[1..];
        return stripPrefix(val, pattern, greedy);
    }

    // ${var%pattern} / ${var%%pattern} — remove suffix
    if (rest.len >= 1 and rest[0] == '%') {
        const greedy = rest.len >= 2 and rest[1] == '%';
        const pattern = if (greedy) rest[2..] else rest[1..];
        return stripSuffix(val, pattern, greedy);
    }

    return val;
}

/// Remove prefix matching pattern from value.
/// Pattern supports trailing * (match anything after literal) and leading * (match anything before literal).
fn stripPrefix(val: []const u8, pattern: []const u8, greedy: bool) []const u8 {
    if (val.len == 0 or pattern.len == 0) return val;

    // Pattern with leading * — e.g. ##*/ means "longest prefix ending with /"
    if (pattern.len > 0 and pattern[0] == '*') {
        const literal = pattern[1..];
        if (literal.len == 0) {
            // ##* removes everything, #* removes first char
            return if (greedy) "" else if (val.len > 0) val[1..] else val;
        }
        if (greedy) {
            // ##*X — find last occurrence of X, strip up to and including it
            var last: ?usize = null;
            var pos: usize = 0;
            while (pos + literal.len <= val.len) {
                if (std.mem.eql(u8, val[pos..][0..literal.len], literal)) last = pos + literal.len;
                pos += 1;
            }
            if (last) |l| return val[l..];
        } else {
            // #*X — find first occurrence of X, strip up to and including it
            if (std.mem.indexOf(u8, val, literal)) |pos| return val[pos + literal.len ..];
        }
        return val;
    }

    // Pattern with trailing * — e.g. #X* means "strip prefix starting with X"
    if (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
        const literal = pattern[0 .. pattern.len - 1];
        if (std.mem.startsWith(u8, val, literal)) {
            if (greedy) return "" else return val[literal.len..];
        }
        return val;
    }

    // Exact prefix match
    if (std.mem.startsWith(u8, val, pattern)) return val[pattern.len..];
    return val;
}

/// Remove suffix matching pattern from value.
/// Supports leading * (e.g. `*.txt`) and trailing * (e.g. `/*`).
fn stripSuffix(val: []const u8, pattern: []const u8, greedy: bool) []const u8 {
    if (val.len == 0 or pattern.len == 0) return val;

    // Pattern with leading * — e.g. %*.txt means "suffix ending with .txt"
    if (pattern[0] == '*') {
        const literal = pattern[1..];
        if (literal.len == 0) {
            return if (greedy) "" else if (val.len > 0) val[0 .. val.len - 1] else val;
        }
        if (greedy) {
            // %%*.txt — find first .txt, strip from there
            if (std.mem.indexOf(u8, val, literal)) |pos| return val[0..pos];
        } else {
            // %*.txt — find last .txt, strip from there
            var last: ?usize = null;
            var pos: usize = 0;
            while (pos + literal.len <= val.len) {
                if (std.mem.eql(u8, val[pos..][0..literal.len], literal)) last = pos;
                pos += 1;
            }
            if (last) |l| return val[0..l];
        }
        return val;
    }

    // Pattern with trailing * — e.g. %/* means "suffix starting with /"
    if (pattern[pattern.len - 1] == '*') {
        const literal = pattern[0 .. pattern.len - 1];
        if (literal.len == 0) {
            return if (greedy) "" else if (val.len > 0) val[0 .. val.len - 1] else val;
        }
        if (greedy) {
            // %%/* — find first /, strip from there to end
            if (std.mem.indexOf(u8, val, literal)) |pos| return val[0..pos];
        } else {
            // %/* — find last /, strip from there to end
            var last: ?usize = null;
            var pos: usize = 0;
            while (pos + literal.len <= val.len) {
                if (std.mem.eql(u8, val[pos..][0..literal.len], literal)) last = pos;
                pos += 1;
            }
            if (last) |l| return val[0..l];
        }
        return val;
    }

    // Exact suffix match
    if (std.mem.endsWith(u8, val, pattern)) return val[0 .. val.len - pattern.len];
    return val;
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

test "param expansion ${var}" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("FOO", "bar");
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "${FOO}", .{ .env = &env, .special = .{} });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("bar", result);
}

test "param expansion ${var:-default}" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "${MISSING:-fallback}", .{ .env = &env, .special = .{} });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("fallback", result);
}

test "param expansion ${var:-default} when set" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("FOO", "bar");
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "${FOO:-fallback}", .{ .env = &env, .special = .{} });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("bar", result);
}

test "param expansion ${var:+alternate}" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("FOO", "bar");
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const r1 = try varExpand(std.testing.allocator, "${FOO:+yes}", .{ .env = &env, .special = .{} });
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("yes", r1);

    const r2 = try varExpand(std.testing.allocator, "${MISSING:+yes}", .{ .env = &env, .special = .{} });
    defer std.testing.allocator.free(r2);
    try std.testing.expectEqualStrings("", r2);
}

test "param expansion ${var%pattern}" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/home/user/docs/file.txt");
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "${PATH%/*}", .{ .env = &env, .special = .{} });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/docs", result);
}

test "param expansion ${var##pattern}" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/home/user/docs/file.txt");
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    const result = try varExpand(std.testing.allocator, "${PATH##*/}", .{ .env = &env, .special = .{} });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("file.txt", result);
}
