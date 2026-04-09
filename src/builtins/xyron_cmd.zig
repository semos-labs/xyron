// builtins/xyron_cmd.zig — Xyron shell utilities command.
//
// Subcommands:
//   xyron secrets init             Set up GPG key and secrets file
//   xyron secrets open [--local]   TUI browser for secrets
//   xyron secrets get <name>       Query a secret by name
//   xyron secrets add <name> <value> [--description, --local]
//   xyron secrets list [--local]   List all secrets

const std = @import("std");
const posix = std.posix;
const secrets_mod = @import("../secrets.zig");
const style = @import("../style.zig");
const project_cmd = @import("project_cmd.zig");
const doctor_cmd = @import("doctor_cmd.zig");
const explain_cmd = @import("explain_cmd.zig");
const bootstrap_cmd = @import("bootstrap_cmd.zig");
const Result = @import("mod.zig").BuiltinResult;

const environ_mod = @import("../environ.zig");

/// Set by `xyron reload` — shell checks this after executeLine.
pub var reload_pending: bool = false;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File, env_inst: *environ_mod.Environ) Result {
    if (args.len == 0) return runHelp(stdout);
    if (std.mem.eql(u8, args[0], "secrets")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return runSecrets(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "project")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return project_cmd.run(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "run")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return project_cmd.runCommand(sub_args, stdout, stderr, env_inst);
    }
    if (std.mem.eql(u8, args[0], "up")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return project_cmd.serviceUp(sub_args, stdout, stderr, env_inst);
    }
    if (std.mem.eql(u8, args[0], "down")) return project_cmd.serviceDown(stdout, stderr);
    if (std.mem.eql(u8, args[0], "restart")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return project_cmd.serviceRestart(sub_args, stdout, stderr, env_inst);
    }
    if (std.mem.eql(u8, args[0], "ps")) return project_cmd.servicePs(stdout, stderr);
    if (std.mem.eql(u8, args[0], "logs")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return project_cmd.serviceLogs(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "init")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return bootstrap_cmd.runInit(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "new")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return bootstrap_cmd.runNew(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "reload")) {
        reload_pending = true;
        stdout.writeAll("\x1b[2mreloading config...\x1b[0m\n") catch {};
        return .{};
    }
    if (std.mem.eql(u8, args[0], "bookmarks") or std.mem.eql(u8, args[0], "bm")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return @import("bookmarks_cmd.zig").run(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "doctor")) return doctor_cmd.run(stdout);
    if (std.mem.eql(u8, args[0], "context")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        // "xyron context explain [KEY]" or bare "xyron context" → explain summary
        if (sub_args.len == 0) return explain_cmd.run(&.{}, stdout, stderr);
        if (std.mem.eql(u8, sub_args[0], "explain")) {
            const explain_args = if (sub_args.len > 1) sub_args[1..] else &[_][]const u8{};
            return explain_cmd.run(explain_args, stdout, stderr);
        }
        // Fall through to project context for backward compat
        return project_cmd.run(args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) return runHelp(stdout);
    stderr.writeAll("xyron: unknown subcommand. Try `xyron help`\n") catch {};
    return .{ .exit_code = 1 };
}

fn runHelp(stdout: std.fs.File) Result {
    stdout.writeAll(
        \\xyron — shell utilities
        \\
        \\Commands:
        \\  xyron init                             Initialize xyron.toml
        \\  xyron new <ecosystem> <name>          Create new project
        \\  xyron run <command>                   Run a project command
        \\  xyron up [service]                   Start project services
        \\  xyron down                           Stop project services
        \\  xyron restart <service>              Restart a service
        \\  xyron ps                             Show service status
        \\  xyron logs <service>                 Show service logs
        \\  xyron reload                           Reload config and project context
        \\  xyron doctor                          Diagnose project issues
        \\  xyron context explain [KEY]           Explain context/value origin
        \\  xyron project info                   Show project info
        \\  xyron project context                Show resolved context
        \\  xyron secrets init                   Set up GPG key
        \\  xyron secrets open [--local]         Browse secrets (TUI)
        \\  xyron secrets get <name>             Get a secret value
        \\  xyron secrets add <n> <v> [opts]     Add a secret
        \\  xyron secrets list [--local]         List secrets
        \\
        \\Add options:
        \\  --description "text"    Description
        \\  --local                 Scope to current directory
        \\  --password              Store as password (not env)
        \\
    ) catch {};
    return .{};
}

fn runSecrets(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) return @import("secrets_open.zig").run(args, stdout, stderr);
    const subcmd = args[0];
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
    if (std.mem.eql(u8, subcmd, "init")) return @import("secrets_init.zig").run(stdout, stderr);
    if (std.mem.eql(u8, subcmd, "open")) return @import("secrets_open.zig").run(sub_args, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "get")) return runSecretsGet(sub_args, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "add")) return runSecretsAdd(sub_args, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "list")) return runSecretsList(sub_args, stdout, stderr);
    stderr.writeAll("xyron secrets: unknown subcommand\n") catch {};
    return .{ .exit_code = 1 };
}

// ---------------------------------------------------------------------------
// CLI subcommands
// ---------------------------------------------------------------------------

fn runSecretsGet(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) { stderr.writeAll("Usage: xyron secrets get <name>\n") catch {}; return .{ .exit_code = 1 }; }
    var store = secrets_mod.SecretsStore.init();
    if (!store.isInitialized()) { stderr.writeAll("Run `xyron secrets init` first.\n") catch {}; return .{ .exit_code = 1 }; }
    store.load() catch { stderr.writeAll("Failed to decrypt secrets.\n") catch {}; return .{ .exit_code = 1 }; };
    if (store.findByName(args[0])) |idx| {
        stdout.writeAll(store.secrets[idx].valueSlice()) catch {};
        stdout.writeAll("\n") catch {};
        return .{};
    }
    stderr.writeAll("Secret not found: ") catch {};
    stderr.writeAll(args[0]) catch {};
    stderr.writeAll("\n") catch {};
    return .{ .exit_code = 1 };
}

fn runSecretsAdd(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len < 2) {
        stderr.writeAll("Usage: xyron secrets add <name> <value> [--description \"...\"] [--local] [--password]\n") catch {};
        return .{ .exit_code = 1 };
    }
    const name = args[0];
    const value = args[1];
    var desc: []const u8 = "";
    var kind: secrets_mod.SecretKind = .env;
    var dir: []const u8 = "";

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--description") and i + 1 < args.len) { i += 1; desc = args[i]; }
        else if (std.mem.eql(u8, args[i], "--local")) {
            kind = .local;
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            dir = std.posix.getcwd(&cwd_buf) catch "";
        } else if (std.mem.eql(u8, args[i], "--password")) { kind = .password; }
    }

    var store = secrets_mod.SecretsStore.init();
    if (!store.isInitialized()) { stderr.writeAll("Run `xyron secrets init` first.\n") catch {}; return .{ .exit_code = 1 }; }
    store.load() catch {};
    if (store.findByName(name) != null) {
        stderr.writeAll("Secret already exists: ") catch {};
        stderr.writeAll(name) catch {};
        stderr.writeAll(". Remove it first.\n") catch {};
        return .{ .exit_code = 1 };
    }
    if (!store.add(name, value, desc, dir, kind)) { stderr.writeAll("Too many secrets.\n") catch {}; return .{ .exit_code = 1 }; }
    store.save() catch { stderr.writeAll("Failed to save secrets.\n") catch {}; return .{ .exit_code = 1 }; };
    stdout.writeAll("Added: ") catch {};
    stdout.writeAll(name) catch {};
    stdout.writeAll("\n") catch {};
    return .{};
}

fn runSecretsList(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    var store = secrets_mod.SecretsStore.init();
    if (!store.isInitialized()) { stderr.writeAll("Run `xyron secrets init` first.\n") catch {}; return .{ .exit_code = 1 }; }
    store.load() catch { stderr.writeAll("Failed to decrypt secrets.\n") catch {}; return .{ .exit_code = 1 }; };

    var local_only = false;
    for (args) |a| { if (std.mem.eql(u8, a, "--local")) local_only = true; }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch ".";
    var count: usize = 0;
    for (0..store.count) |i| {
        const s = &store.secrets[i];
        if (local_only and (s.kind != .local or !std.mem.eql(u8, s.dirSlice(), cwd))) continue;
        var buf: [1024]u8 = undefined;
        var pos: usize = 0;
        pos += style.cp(buf[pos..], "  ");
        switch (s.kind) {
            .env => pos += style.colored(buf[pos..], .green, "env"),
            .local => pos += style.colored(buf[pos..], .blue, "local"),
            .password => pos += style.colored(buf[pos..], .yellow, "pass"),
        }
        pos += style.cp(buf[pos..], "  ");
        pos += style.boldText(buf[pos..], s.nameSlice());
        if (s.desc_len > 0) { pos += style.cp(buf[pos..], "  "); pos += style.dimText(buf[pos..], s.descSlice()); }
        pos += style.cp(buf[pos..], "\n");
        stdout.writeAll(buf[0..pos]) catch {};
        count += 1;
    }
    if (count == 0) stdout.writeAll("  No secrets found.\n") catch {};
    return .{};
}

