// cmd_completions.zig — Built-in command-specific completion providers.
//
// Provides context-aware completions for popular commands by running
// them and parsing their output (e.g., git branch names, docker
// containers, npm scripts).

const std = @import("std");
const posix = std.posix;
const complete = @import("complete.zig");
const project = @import("project/mod.zig");

const TIMEOUT_MS: i32 = 500;
const MAX_OUTPUT: usize = 32768;

/// Main dispatch: call the right provider based on cmd_name.
pub fn provide(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_name.len == 0) return;

    if (std.mem.eql(u8, ctx.cmd_name, "git")) {
        if (ctx.cmd_args_len == 0) {
            // Supplement git subcommands that --help doesn't list
            provideGitSubcommands(out, ctx.prefix);
        }
        provideGit(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "docker") or std.mem.eql(u8, ctx.cmd_name, "podman")) {
        provideDocker(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "npm") or std.mem.eql(u8, ctx.cmd_name, "bun") or std.mem.eql(u8, ctx.cmd_name, "yarn") or std.mem.eql(u8, ctx.cmd_name, "pnpm")) {
        provideNpmScripts(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "xyron") or std.mem.eql(u8, ctx.cmd_name, "xy")) {
        provideXyron(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "make") or std.mem.eql(u8, ctx.cmd_name, "gmake")) {
        provideMakeTargets(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "ssh") or std.mem.eql(u8, ctx.cmd_name, "scp")) {
        provideSshHosts(out, ctx);
    } else {
        // Delegate to extended providers (kubectl, brew, pip, etc.)
        const ext = @import("cmd_completions_ext.zig");
        ext.provide(out, ctx);
    }
}

// ---------------------------------------------------------------------------
// xyron / xy — subcommands and project commands/services
// ---------------------------------------------------------------------------

fn provideXyron(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) {
        // Complete subcommands
        const subcmds = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "run", .desc = "Run a project command" },
            .{ .name = "up", .desc = "Start project services" },
            .{ .name = "down", .desc = "Stop project services" },
            .{ .name = "restart", .desc = "Restart a service" },
            .{ .name = "ps", .desc = "Show service status" },
            .{ .name = "logs", .desc = "Show service logs" },
            .{ .name = "init", .desc = "Initialize xyron.toml" },
            .{ .name = "new", .desc = "Create new project" },
            .{ .name = "reload", .desc = "Reload config" },
            .{ .name = "doctor", .desc = "Diagnose project issues" },
            .{ .name = "context", .desc = "Show/explain context" },
            .{ .name = "project", .desc = "Project info" },
            .{ .name = "secrets", .desc = "Manage secrets" },
        };
        for (subcmds) |cmd| {
            if (ctx.prefix.len == 0 or std.mem.startsWith(u8, cmd.name, ctx.prefix)) {
                out.addWithDesc(cmd.name, cmd.desc, .builtin);
            }
        }
        return;
    }

    const subcmd = ctx.cmd_args[0];

    // "xyron run <TAB>" — complete project command names
    if (std.mem.eql(u8, subcmd, "run")) {
        addProjectCommands(out, ctx.prefix);
        return;
    }

    // "xyron up/restart/logs <TAB>" — complete service names
    if (std.mem.eql(u8, subcmd, "up") or std.mem.eql(u8, subcmd, "restart") or std.mem.eql(u8, subcmd, "logs")) {
        addProjectServices(out, ctx.prefix);
        return;
    }

    // "xyron secrets <TAB>" — complete secrets subcommands
    if (std.mem.eql(u8, subcmd, "secrets") and ctx.cmd_args_len == 1) {
        const secrets_cmds = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "init", .desc = "Set up GPG key" },
            .{ .name = "open", .desc = "Browse secrets (TUI)" },
            .{ .name = "get", .desc = "Get a secret value" },
            .{ .name = "add", .desc = "Add a secret" },
            .{ .name = "list", .desc = "List secrets" },
        };
        for (secrets_cmds) |cmd| {
            if (ctx.prefix.len == 0 or std.mem.startsWith(u8, cmd.name, ctx.prefix)) {
                out.addWithDesc(cmd.name, cmd.desc, .builtin);
            }
        }
        return;
    }

    // "xyron context <TAB>"
    if (std.mem.eql(u8, subcmd, "context") and ctx.cmd_args_len == 1) {
        if (ctx.prefix.len == 0 or std.mem.startsWith(u8, "explain", ctx.prefix)) {
            out.addWithDesc("explain", "Explain context/value origin", .builtin);
        }
        return;
    }
}

fn addProjectCommands(out: *complete.CandidateBuffer, prefix: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const load_result = project.loadFromCwd(arena.allocator());
    if (load_result.status != .valid) return;
    const mdl = load_result.model orelse return;
    for (mdl.commands) |cmd| {
        if (prefix.len == 0 or std.mem.startsWith(u8, cmd.name, prefix)) {
            out.addWithDesc(cmd.name, cmd.command, .builtin);
        }
    }
}

fn addProjectServices(out: *complete.CandidateBuffer, prefix: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const load_result = project.loadFromCwd(arena.allocator());
    if (load_result.status != .valid) return;
    const mdl = load_result.model orelse return;
    for (mdl.services) |svc| {
        if (prefix.len == 0 or std.mem.startsWith(u8, svc.name, prefix)) {
            out.addWithDesc(svc.name, svc.command, .builtin);
        }
    }
}

// ---------------------------------------------------------------------------
// Git
// ---------------------------------------------------------------------------

/// Supplement git subcommands that `git --help` doesn't list (e.g., checkout).
fn provideGitSubcommands(out: *complete.CandidateBuffer, prefix: []const u8) void {
    const extra_cmds = [_]struct { name: []const u8, desc: []const u8 }{
        .{ .name = "checkout", .desc = "Switch branches or restore files" },
        .{ .name = "cherry-pick", .desc = "Apply changes from existing commits" },
        .{ .name = "stash", .desc = "Stash changes in a dirty working directory" },
        .{ .name = "remote", .desc = "Manage set of tracked repositories" },
        .{ .name = "submodule", .desc = "Initialize, update, or inspect submodules" },
        .{ .name = "worktree", .desc = "Manage multiple working trees" },
        .{ .name = "reflog", .desc = "Manage reflog information" },
        .{ .name = "clean", .desc = "Remove untracked files" },
        .{ .name = "apply", .desc = "Apply a patch to files" },
        .{ .name = "am", .desc = "Apply patches from a mailbox" },
    };
    for (extra_cmds) |cmd| {
        if (prefix.len == 0 or std.mem.startsWith(u8, cmd.name, prefix)) {
            out.addWithDesc(cmd.name, cmd.desc, .external_cmd);
        }
    }
}

fn provideGit(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) return;
    const subcmd = ctx.cmd_args[0];
    const pos = ctx.cmd_args_len - 1; // argument position after subcommand

    // Subcommands that take a branch at position 0
    const branch_cmds = [_][]const u8{
        "checkout", "switch", "merge", "rebase", "cherry-pick", "diff", "log",
    };
    for (branch_cmds) |bc| {
        if (std.mem.eql(u8, subcmd, bc) and pos == 0) {
            addGitBranches(out, ctx.prefix);
            return;
        }
    }

    // git branch -d/-D <branch>
    if (std.mem.eql(u8, subcmd, "branch")) {
        addGitBranches(out, ctx.prefix);
        return;
    }

    // push/pull/fetch: position 0 = remote, position 1 = branch
    const remote_cmds = [_][]const u8{ "push", "pull", "fetch" };
    for (remote_cmds) |rc| {
        if (std.mem.eql(u8, subcmd, rc)) {
            if (pos == 0) {
                addGitRemotes(out, ctx.prefix);
            } else if (pos == 1) {
                addGitBranches(out, ctx.prefix);
            }
            return;
        }
    }

    // git stash <subcommand>
    if (std.mem.eql(u8, subcmd, "stash") and pos == 0) {
        const stash_cmds = [_][]const u8{ "pop", "apply", "drop", "list", "show", "push", "clear" };
        for (stash_cmds) |sc| {
            if (ctx.prefix.len == 0 or std.mem.startsWith(u8, sc, ctx.prefix)) {
                out.add(sc, .external_cmd);
            }
        }
        return;
    }
}

fn addGitBranches(out: *complete.CandidateBuffer, prefix: []const u8) void {
    const alloc = std.heap.page_allocator;
    // Local branches
    const local = runCommand(&.{ "git", "branch", "--list", "--no-color" }, alloc) orelse "";
    defer if (local.len > 0) alloc.free(local);
    parseBranches(out, local, prefix, false);

    // Remote branches
    const remote = runCommand(&.{ "git", "branch", "-r", "--no-color" }, alloc) orelse "";
    defer if (remote.len > 0) alloc.free(remote);
    parseBranches(out, remote, prefix, true);
}

fn parseBranches(out: *complete.CandidateBuffer, output: []const u8, prefix: []const u8, is_remote: bool) void {
    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        var name = std.mem.trim(u8, line, " \t\r");
        // Skip current branch marker
        if (std.mem.startsWith(u8, name, "* ")) name = std.mem.trim(u8, name[2..], " ");
        // Skip HEAD pointer
        if (std.mem.indexOf(u8, name, "->") != null) continue;
        if (name.len == 0) continue;

        // Strip remote prefix (e.g., "origin/main" → "main")
        if (is_remote) {
            if (std.mem.indexOf(u8, name, "/")) |slash| {
                name = name[slash + 1 ..];
            }
        }

        if (name.len == 0) continue;
        if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) continue;
        const desc: []const u8 = if (is_remote) "remote" else "branch";
        out.addWithDesc(name, desc, .external_cmd);
    }
}

fn addGitRemotes(out: *complete.CandidateBuffer, prefix: []const u8) void {
    const alloc = std.heap.page_allocator;
    const output = runCommand(&.{ "git", "remote" }, alloc) orelse return;
    defer alloc.free(output);

    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len == 0) continue;
        if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) continue;
        out.addWithDesc(name, "remote", .external_cmd);
    }
}

// ---------------------------------------------------------------------------
// Docker
// ---------------------------------------------------------------------------

fn provideDocker(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) return;
    const subcmd = ctx.cmd_args[0];

    // Commands that take container names
    const container_cmds = [_][]const u8{
        "exec", "stop", "start", "restart", "rm", "logs", "inspect", "attach", "kill", "top", "port",
    };
    for (container_cmds) |cc| {
        if (std.mem.eql(u8, subcmd, cc)) {
            addDockerContainers(out, ctx.prefix);
            return;
        }
    }

    // Commands that take image names
    if (std.mem.eql(u8, subcmd, "run") or std.mem.eql(u8, subcmd, "pull") or std.mem.eql(u8, subcmd, "rmi")) {
        addDockerImages(out, ctx.prefix);
        return;
    }

    // docker compose <subcmd> <service>
    if (std.mem.eql(u8, subcmd, "compose")) {
        const ext = @import("cmd_completions_ext.zig");
        ext.provideDockerCompose(out, ctx);
        return;
    }
}

fn addDockerContainers(out: *complete.CandidateBuffer, prefix: []const u8) void {
    const alloc = std.heap.page_allocator;
    const output = runCommand(&.{ "docker", "ps", "-a", "--format", "{{.Names}}\t{{.Status}}" }, alloc) orelse return;
    defer alloc.free(output);

    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, "\t")) |tab| {
            const name = trimmed[0..tab];
            const status = trimmed[tab + 1 ..];
            if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) continue;
            out.addWithDesc(name, status, .external_cmd);
        } else {
            if (prefix.len > 0 and !std.mem.startsWith(u8, trimmed, prefix)) continue;
            out.add(trimmed, .external_cmd);
        }
    }
}

fn addDockerImages(out: *complete.CandidateBuffer, prefix: []const u8) void {
    const alloc = std.heap.page_allocator;
    const output = runCommand(&.{ "docker", "images", "--format", "{{.Repository}}:{{.Tag}}" }, alloc) orelse return;
    defer alloc.free(output);

    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, "<none>:<none>")) continue;
        if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) continue;
        out.add(name, .external_cmd);
    }
}

// ---------------------------------------------------------------------------
// npm / bun / yarn / pnpm — script names from package.json
// ---------------------------------------------------------------------------

fn provideNpmScripts(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) return;
    if (!std.mem.eql(u8, ctx.cmd_args[0], "run")) return;

    // Read package.json from cwd
    const file = std.fs.cwd().openFile("package.json", .{}) catch return;
    defer file.close();

    var buf: [8192]u8 = undefined;
    const n = file.readAll(&buf) catch return;
    const content = buf[0..n];

    // Simple parser: find "scripts" key and extract keys from the object
    const scripts_key = "\"scripts\"";
    const scripts_pos = std.mem.indexOf(u8, content, scripts_key) orelse return;
    const after_key = content[scripts_pos + scripts_key.len ..];

    // Find opening brace
    const brace = std.mem.indexOf(u8, after_key, "{") orelse return;
    const obj = after_key[brace + 1 ..];

    // Extract keys until closing brace
    var rest = obj;
    while (rest.len > 0) {
        // Find next quoted key
        const q1 = std.mem.indexOf(u8, rest, "\"") orelse break;
        if (rest[0..q1].len > 0 and std.mem.indexOf(u8, rest[0..q1], "}") != null) break;
        const after_q1 = rest[q1 + 1 ..];
        const q2 = std.mem.indexOf(u8, after_q1, "\"") orelse break;
        const key = after_q1[0..q2];

        // Check it's a key (followed by :)
        const after_q2 = after_q1[q2 + 1 ..];
        const colon = std.mem.indexOf(u8, after_q2, ":") orelse break;
        const between = std.mem.trim(u8, after_q2[0..colon], " \t\r\n");
        if (between.len == 0) {
            // It's a key
            if (ctx.prefix.len == 0 or std.mem.startsWith(u8, key, ctx.prefix)) {
                out.add(key, .external_cmd);
            }
        }

        // Skip past the value
        const next_comma = std.mem.indexOf(u8, after_q2[colon + 1 ..], ",");
        const next_brace = std.mem.indexOf(u8, after_q2[colon + 1 ..], "}");
        if (next_brace) |nb| {
            if (next_comma) |nc| {
                if (nc < nb) {
                    rest = after_q2[colon + 1 + nc + 1 ..];
                } else break;
            } else break;
        } else if (next_comma) |nc| {
            rest = after_q2[colon + 1 + nc + 1 ..];
        } else break;
    }
}

// ---------------------------------------------------------------------------
// make — targets from Makefile
// ---------------------------------------------------------------------------

fn provideMakeTargets(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    _ = ctx.cmd_args_len; // make targets are always the first args

    const file = std.fs.cwd().openFile("Makefile", .{}) catch
        std.fs.cwd().openFile("makefile", .{}) catch
        std.fs.cwd().openFile("GNUmakefile", .{}) catch return;
    defer file.close();

    var buf: [16384]u8 = undefined;
    const n = file.readAll(&buf) catch return;
    const content = buf[0..n];

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        // Target lines: "name:" at start of line (not indented, not commented)
        if (line.len == 0) continue;
        if (line[0] == '\t' or line[0] == ' ' or line[0] == '#' or line[0] == '.') continue;

        if (std.mem.indexOf(u8, line, ":")) |colon| {
            if (colon == 0) continue;
            // Skip variable assignments (NAME := or NAME =)
            if (colon > 0 and line[colon - 1] == '=') continue;
            // Skip :: rules double-colon
            const target = std.mem.trim(u8, line[0..colon], " \t");
            if (target.len == 0) continue;
            // Skip targets with $ (variable references)
            if (std.mem.indexOf(u8, target, "$") != null) continue;
            if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, target, ctx.prefix)) continue;
            out.add(target, .external_cmd);
        }
    }
}

// ---------------------------------------------------------------------------
// ssh — hosts from ~/.ssh/config
// ---------------------------------------------------------------------------

fn provideSshHosts(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    // Only complete the first argument (hostname)
    if (ctx.cmd_args_len > 1) return;

    const home = std.posix.getenv("HOME") orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.ssh/config", .{home}) catch return;

    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [8192]u8 = undefined;
    const n = file.readAll(&buf) catch return;
    const content = buf[0..n];

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Match "Host " or "host " (case-insensitive first char)
        if (trimmed.len < 5) continue;
        if (!std.mem.startsWith(u8, trimmed, "Host ") and !std.mem.startsWith(u8, trimmed, "host ")) continue;

        const hosts_str = std.mem.trim(u8, trimmed[5..], " \t");
        // Host line can have multiple hosts separated by spaces
        var host_iter = std.mem.splitScalar(u8, hosts_str, ' ');
        while (host_iter.next()) |host| {
            if (host.len == 0) continue;
            // Skip patterns with wildcards
            if (std.mem.indexOf(u8, host, "*") != null) continue;
            if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, host, ctx.prefix)) continue;
            out.add(host, .external_cmd);
        }
    }
}

// ---------------------------------------------------------------------------
// Shared: run a command and capture stdout
// ---------------------------------------------------------------------------

pub fn runCommand(argv: []const []const u8, alloc: std.mem.Allocator) ?[]const u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    const stdout_fd = if (child.stdout) |f| f.handle else return null;

    var output = std.ArrayList(u8){};
    var fds = [_]posix.pollfd{
        .{ .fd = stdout_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var deadline: i32 = TIMEOUT_MS;
    while (output.items.len < MAX_OUTPUT and deadline > 0) {
        const start = std.time.milliTimestamp();
        const ready = posix.poll(&fds, deadline) catch break;
        const elapsed: i32 = @intCast(@min(std.time.milliTimestamp() - start, 2000));
        deadline -= elapsed;

        if (ready == 0) break;

        if (fds[0].revents & posix.POLL.IN != 0) {
            var buf: [4096]u8 = undefined;
            const n = posix.read(fds[0].fd, &buf) catch 0;
            if (n == 0) break;
            output.appendSlice(alloc, buf[0..n]) catch break;
        }
    }

    _ = child.wait() catch {};
    return if (output.items.len > 0) output.toOwnedSlice(alloc) catch null else null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseBranches local" {
    var buf = complete.CandidateBuffer{};
    parseBranches(&buf, "  main\n* feature/foo\n  develop\n", "", false);
    try std.testing.expect(buf.count >= 3);
}

test "parseBranches remote skips HEAD" {
    var buf = complete.CandidateBuffer{};
    parseBranches(&buf, "  origin/HEAD -> origin/main\n  origin/main\n  origin/dev\n", "", true);
    // Should skip HEAD line, have main and dev
    try std.testing.expect(buf.count >= 2);
}

test "parseBranches prefix filter" {
    var buf = complete.CandidateBuffer{};
    parseBranches(&buf, "  main\n  feature/foo\n  develop\n", "f", false);
    try std.testing.expectEqual(@as(usize, 1), buf.count);
}

test "provideMakeTargets" {
    // This test relies on a Makefile in cwd — skip if not present
    const file = std.fs.cwd().openFile("Makefile", .{}) catch return;
    file.close();

    var buf = complete.CandidateBuffer{};
    const ctx = complete.CompletionContext{
        .kind = .argument,
        .prefix = "",
        .word_start = 0,
        .word_end = 0,
        .cmd_name = "make",
        .cmd_args = .{&.{}} ** 8,
        .cmd_args_len = 0,
    };
    provideMakeTargets(&buf, &ctx);
    // Just verify it doesn't crash
}
