// complete_providers.zig — Completion candidate providers.
//
// Each provider adds matching candidates to a shared buffer.
// Providers: builtins, lua commands, PATH executables, filesystem,
// environment variables, and help-derived flags.

const std = @import("std");
const posix = std.posix;
const builtins = @import("builtins.zig");
const lua_commands = @import("lua_commands.zig");
const environ_mod = @import("environ.zig");
const highlight = @import("highlight.zig");
const complete = @import("complete.zig");
const help_mod = @import("complete_help.zig");
const aliases_mod = @import("aliases.zig");

/// Gather candidates based on context.
pub fn gather(
    out: *complete.CandidateBuffer,
    ctx: *const complete.CompletionContext,
    env: *const environ_mod.Environ,
    cmd_cache: *highlight.CommandCache,
    help_cache: ?*help_mod.HelpCache,
) void {
    switch (ctx.kind) {
        .command => {
            provideBuiltins(out, ctx.prefix);
            provideAliases(out, ctx.prefix);
            provideLuaCommands(out, ctx.prefix);
            providePathCommands(out, ctx.prefix, env, cmd_cache);
        },
        .argument => {
            // Help-derived flags and subcommands first, then filesystem
            if (help_cache) |hc| provideHelpFlags(out, ctx.cmd_name, ctx.prefix, hc, env);
            provideFilesystem(out, ctx.prefix, env);
        },
        .redirect_target => {
            provideFilesystem(out, ctx.prefix, env);
        },
        .flag => {
            if (help_cache) |hc| provideHelpFlags(out, ctx.cmd_name, ctx.prefix, hc, env);
            provideFilesystem(out, ctx.prefix, env);
        },
        .env_var => {
            provideEnvVars(out, ctx.prefix, env);
        },
        .none => {},
    }
}

// ---------------------------------------------------------------------------
// Builtin provider
// ---------------------------------------------------------------------------

fn provideBuiltins(out: *complete.CandidateBuffer, prefix: []const u8) void {
    const entries = [_]struct { name: []const u8, desc: []const u8 }{
        .{ .name = "cd", .desc = "Change directory" },
        .{ .name = "pwd", .desc = "Print working directory" },
        .{ .name = "exit", .desc = "Exit the shell" },
        .{ .name = "export", .desc = "Set environment variable" },
        .{ .name = "unset", .desc = "Remove environment variable" },
        .{ .name = "env", .desc = "Print environment" },
        .{ .name = "which", .desc = "Locate a command" },
        .{ .name = "type", .desc = "Identify command type" },
        .{ .name = "history", .desc = "Show command history" },
        .{ .name = "jobs", .desc = "List background jobs" },
        .{ .name = "fg", .desc = "Bring job to foreground" },
        .{ .name = "bg", .desc = "Resume job in background" },
        .{ .name = "alias", .desc = "Define or list aliases" },
        .{ .name = "exec", .desc = "Run a command via sh" },
        .{ .name = "ls", .desc = "List directory contents" },
        .{ .name = "ps", .desc = "List processes" },
        .{ .name = "json", .desc = "Parse and render JSON as table" },
        .{ .name = "query", .desc = "SQL-like query for JSON data" },
        .{ .name = "select", .desc = "Pick columns from structured data" },
        .{ .name = "where", .desc = "Filter structured data" },
        .{ .name = "sort", .desc = "Sort structured data" },
        .{ .name = "csv", .desc = "Parse CSV/TSV as structured data" },
        .{ .name = "fz", .desc = "Fuzzy finder" },
        .{ .name = "migrate", .desc = "Analyze/convert bash scripts" },
        .{ .name = "popup", .desc = "Show content in popup" },
        .{ .name = "inspect", .desc = "Inspect runtime objects" },
    };
    for (entries) |e| {
        if (prefix.len == 0 or std.mem.startsWith(u8, e.name, prefix)) {
            out.addWithDesc(e.name, e.desc, .builtin);
        }
    }
}

// ---------------------------------------------------------------------------
// Alias provider
// ---------------------------------------------------------------------------

fn provideAliases(out: *complete.CandidateBuffer, prefix: []const u8) void {
    for (0..aliases_mod.aliasCount()) |i| {
        const name = aliases_mod.nameAt(i);
        if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
            out.addWithDesc(name, aliases_mod.expansionAt(i), .alias);
        }
    }
}

// ---------------------------------------------------------------------------
// Lua command provider
// ---------------------------------------------------------------------------

fn provideLuaCommands(out: *complete.CandidateBuffer, prefix: []const u8) void {
    for (0..lua_commands.commandCount()) |i| {
        const name = lua_commands.commandNameAt(i);
        if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
            out.add(name, .lua_cmd);
        }
    }
}

// ---------------------------------------------------------------------------
// PATH executable provider
// ---------------------------------------------------------------------------

fn providePathCommands(
    out: *complete.CandidateBuffer,
    prefix: []const u8,
    env: *const environ_mod.Environ,
    cmd_cache: *highlight.CommandCache,
) void {
    _ = cmd_cache;
    if (prefix.len == 0) return; // don't list all PATH commands on empty prefix

    const path_val = env.get("PATH") orelse return;
    var path_iter = std.mem.splitScalar(u8, path_val, ':');

    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;
        scanDirectory(out, dir, prefix, .external_cmd) catch continue;
        if (out.count >= complete.MAX_CANDIDATES / 2) break; // don't flood
    }
}

// ---------------------------------------------------------------------------
// Filesystem provider
// ---------------------------------------------------------------------------

fn provideFilesystem(out: *complete.CandidateBuffer, prefix: []const u8, env: *const environ_mod.Environ) void {
    // Split prefix into dir_part and name_part at last /
    var dir_part: []const u8 = ".";
    var name_part: []const u8 = prefix;
    var dir_prefix: []const u8 = ""; // what to prepend to results

    if (std.mem.lastIndexOf(u8, prefix, "/")) |last_slash| {
        dir_part = if (last_slash == 0) "/" else prefix[0..last_slash];
        name_part = prefix[last_slash + 1 ..];
        dir_prefix = prefix[0 .. last_slash + 1];
    }

    // Tilde expansion for dir_part
    var expanded_buf: [std.fs.max_path_bytes]u8 = undefined;
    var actual_dir = dir_part;
    if (dir_part.len > 0 and dir_part[0] == '~') {
        if (env.home()) |home| {
            const rest = if (dir_part.len > 1) dir_part[1..] else "";
            const expanded = std.fmt.bufPrint(&expanded_buf, "{s}{s}", .{ home, rest }) catch dir_part;
            actual_dir = expanded;
        }
    }

    // Open directory — use cwd-relative for non-absolute paths
    var d = if (actual_dir.len > 0 and actual_dir[0] == '/')
        std.fs.openDirAbsolute(actual_dir, .{ .iterate = true }) catch return
    else
        std.fs.cwd().openDir(actual_dir, .{ .iterate = true }) catch return;
    defer d.close();

    var iter = d.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.name[0] == '.' and name_part.len == 0) continue; // skip hidden unless prefix starts with .
        if (name_part.len == 0 or std.mem.startsWith(u8, entry.name, name_part)) {
            // Build full candidate: dir_prefix + entry.name [+ /]
            var buf: [complete.MAX_TEXT]u8 = undefined;
            var pos: usize = 0;
            const dp = @min(dir_prefix.len, buf.len);
            @memcpy(buf[0..dp], dir_prefix[0..dp]);
            pos += dp;
            const np = @min(entry.name.len, buf.len - pos);
            @memcpy(buf[pos..][0..np], entry.name[0..np]);
            pos += np;

            const kind: complete.CandidateKind = if (entry.kind == .directory) .directory else .file;
            if (entry.kind == .directory and pos < buf.len) {
                buf[pos] = '/';
                pos += 1;
            }
            out.add(buf[0..pos], kind);
        }
        if (out.count >= complete.MAX_CANDIDATES) break;
    }
}

// ---------------------------------------------------------------------------
// Environment variable provider
// ---------------------------------------------------------------------------

fn provideEnvVars(out: *complete.CandidateBuffer, prefix: []const u8, env: *const environ_mod.Environ) void {
    // prefix includes the $ — strip it for matching
    const name_prefix = if (prefix.len > 0 and prefix[0] == '$') prefix[1..] else prefix;

    var iter = env.map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (name_prefix.len == 0 or std.mem.startsWith(u8, key, name_prefix)) {
            var buf: [complete.MAX_TEXT]u8 = undefined;
            buf[0] = '$';
            const kl = @min(key.len, buf.len - 1);
            @memcpy(buf[1..][0..kl], key[0..kl]);
            out.add(buf[0 .. kl + 1], .env_var);
        }
        if (out.count >= complete.MAX_CANDIDATES) break;
    }
}

// ---------------------------------------------------------------------------
// Help-derived flag provider
// ---------------------------------------------------------------------------

fn provideHelpFlags(
    out: *complete.CandidateBuffer,
    cmd_name: []const u8,
    prefix: []const u8,
    help_cache: *help_mod.HelpCache,
    env: *const environ_mod.Environ,
) void {
    if (cmd_name.len == 0) return;
    // Ensure help is cached for this command
    help_cache.ensureCached(cmd_name, env);
    // Query matching flags
    help_cache.queryFlags(cmd_name, prefix, out);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn scanDirectory(out: *complete.CandidateBuffer, dir_path: []const u8, prefix: []const u8, kind: complete.CandidateKind) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_buf[0..dir_path.len], dir_path);
    path_buf[dir_path.len] = 0;

    var d = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer d.close();

    var iter = d.iterate();
    while (iter.next() catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            out.add(entry.name, kind);
        }
        if (out.count >= complete.MAX_CANDIDATES) break;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "provideBuiltins matches prefix" {
    var buf = complete.CandidateBuffer{};
    provideBuiltins(&buf, "ex");
    try std.testing.expect(buf.count >= 2); // export, exit
}

test "provideBuiltins matches all on empty prefix" {
    var buf = complete.CandidateBuffer{};
    provideBuiltins(&buf, "");
    try std.testing.expect(buf.count >= 10);
}
