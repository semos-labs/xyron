// cmd_completions_ext.zig — Extended command-specific completion providers.
//
// Additional providers beyond the core set (git, docker, npm, make, ssh).
// Covers: kubectl, brew, pip, docker compose, go test, zig build, systemctl.

const std = @import("std");
const complete = @import("complete.zig");
const cmd = @import("cmd_completions.zig");

/// Dispatch to extended providers based on cmd_name.
pub fn provide(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (std.mem.eql(u8, ctx.cmd_name, "kubectl") or std.mem.eql(u8, ctx.cmd_name, "k")) {
        provideKubectl(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "brew")) {
        provideBrew(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "pip") or std.mem.eql(u8, ctx.cmd_name, "pip3")) {
        providePip(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "go")) {
        provideGo(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "zig")) {
        provideZig(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "systemctl")) {
        provideSystemctl(out, ctx);
    } else if (std.mem.eql(u8, ctx.cmd_name, "cargo")) {
        provideCargo(out, ctx);
    }
}

// ---------------------------------------------------------------------------
// kubectl
// ---------------------------------------------------------------------------

fn provideKubectl(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) return;
    const subcmd = ctx.cmd_args[0];
    const alloc = std.heap.page_allocator;

    // Commands that take resource names
    const resource_cmds = [_][]const u8{
        "get", "describe", "delete", "edit", "logs", "exec", "port-forward", "top",
    };
    var is_resource_cmd = false;
    for (resource_cmds) |rc| {
        if (std.mem.eql(u8, subcmd, rc)) { is_resource_cmd = true; break; }
    }
    if (!is_resource_cmd) return;

    // Position 0 after subcommand = resource type (pods, services, etc.)
    // Position 1 = resource name
    const pos = ctx.cmd_args_len - 1;

    if (pos == 0) {
        // Suggest resource types
        const types = [_]struct { name: []const u8, desc: []const u8 }{
            .{ .name = "pods", .desc = "Pod resources" },
            .{ .name = "po", .desc = "Pod resources (short)" },
            .{ .name = "services", .desc = "Service resources" },
            .{ .name = "svc", .desc = "Service resources (short)" },
            .{ .name = "deployments", .desc = "Deployment resources" },
            .{ .name = "deploy", .desc = "Deployment resources (short)" },
            .{ .name = "nodes", .desc = "Node resources" },
            .{ .name = "namespaces", .desc = "Namespace resources" },
            .{ .name = "ns", .desc = "Namespace resources (short)" },
            .{ .name = "configmaps", .desc = "ConfigMap resources" },
            .{ .name = "cm", .desc = "ConfigMap resources (short)" },
            .{ .name = "secrets", .desc = "Secret resources" },
            .{ .name = "ingress", .desc = "Ingress resources" },
            .{ .name = "ing", .desc = "Ingress resources (short)" },
            .{ .name = "statefulsets", .desc = "StatefulSet resources" },
            .{ .name = "sts", .desc = "StatefulSet resources (short)" },
            .{ .name = "daemonsets", .desc = "DaemonSet resources" },
            .{ .name = "ds", .desc = "DaemonSet resources (short)" },
            .{ .name = "jobs", .desc = "Job resources" },
            .{ .name = "cronjobs", .desc = "CronJob resources" },
            .{ .name = "cj", .desc = "CronJob resources (short)" },
            .{ .name = "pvc", .desc = "PersistentVolumeClaim" },
            .{ .name = "pv", .desc = "PersistentVolume" },
        };
        for (types) |t| {
            if (ctx.prefix.len == 0 or std.mem.startsWith(u8, t.name, ctx.prefix)) {
                out.addWithDesc(t.name, t.desc, .external_cmd);
            }
        }
        // For `logs` and `exec`, jump straight to pod names
        if (std.mem.eql(u8, subcmd, "logs") or std.mem.eql(u8, subcmd, "exec")) {
            addKubectlResources(out, "pods", ctx.prefix, alloc);
        }
    } else if (pos == 1) {
        // Resource name — query kubectl
        const resource_type = ctx.cmd_args[1];
        addKubectlResources(out, resource_type, ctx.prefix, alloc);
    }
}

fn addKubectlResources(out: *complete.CandidateBuffer, resource_type: []const u8, prefix: []const u8, alloc: std.mem.Allocator) void {
    const output = cmd.runCommand(&.{
        "kubectl", "get", resource_type, "--no-headers", "-o", "custom-columns=NAME:.metadata.name",
    }, alloc) orelse return;
    defer alloc.free(output);

    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len == 0) continue;
        if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) continue;
        out.add(name, .external_cmd);
    }
}

// ---------------------------------------------------------------------------
// brew
// ---------------------------------------------------------------------------

fn provideBrew(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) return;
    const subcmd = ctx.cmd_args[0];
    const alloc = std.heap.page_allocator;

    // uninstall/upgrade/reinstall/info → installed packages
    if (std.mem.eql(u8, subcmd, "uninstall") or std.mem.eql(u8, subcmd, "remove") or
        std.mem.eql(u8, subcmd, "upgrade") or std.mem.eql(u8, subcmd, "reinstall") or
        std.mem.eql(u8, subcmd, "info") or std.mem.eql(u8, subcmd, "pin") or
        std.mem.eql(u8, subcmd, "unpin"))
    {
        const output = cmd.runCommand(&.{ "brew", "list", "--formula", "-1" }, alloc) orelse return;
        defer alloc.free(output);
        addLines(out, output, ctx.prefix);

        const casks = cmd.runCommand(&.{ "brew", "list", "--cask", "-1" }, alloc) orelse return;
        defer alloc.free(casks);
        addLines(out, casks, ctx.prefix);
    }

    // services subcommand
    if (std.mem.eql(u8, subcmd, "services")) {
        if (ctx.cmd_args_len >= 2) {
            const svc_subcmd = ctx.cmd_args[1];
            if (std.mem.eql(u8, svc_subcmd, "start") or std.mem.eql(u8, svc_subcmd, "stop") or
                std.mem.eql(u8, svc_subcmd, "restart") or std.mem.eql(u8, svc_subcmd, "info"))
            {
                const output = cmd.runCommand(&.{ "brew", "services", "list" }, alloc) orelse return;
                defer alloc.free(output);
                var iter = std.mem.splitScalar(u8, output, '\n');
                var first = true;
                while (iter.next()) |line| {
                    if (first) { first = false; continue; } // skip header
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len == 0) continue;
                    // First column is the service name
                    const name_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
                    const name = trimmed[0..name_end];
                    if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, name, ctx.prefix)) continue;
                    out.add(name, .external_cmd);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// pip / pip3
// ---------------------------------------------------------------------------

fn providePip(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) return;
    const subcmd = ctx.cmd_args[0];
    const alloc = std.heap.page_allocator;

    // uninstall/show → installed packages
    if (std.mem.eql(u8, subcmd, "uninstall") or std.mem.eql(u8, subcmd, "show")) {
        const output = cmd.runCommand(&.{ ctx.cmd_name, "list", "--format=freeze" }, alloc) orelse return;
        defer alloc.free(output);

        var iter = std.mem.splitScalar(u8, output, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            // Format: "package==version"
            const eq = std.mem.indexOf(u8, trimmed, "==") orelse trimmed.len;
            const name = trimmed[0..eq];
            if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, name, ctx.prefix)) continue;
            out.add(name, .external_cmd);
        }
    }
}

// ---------------------------------------------------------------------------
// go
// ---------------------------------------------------------------------------

fn provideGo(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) return;
    const subcmd = ctx.cmd_args[0];

    // go test -run → test function names from *_test.go files in cwd
    if (std.mem.eql(u8, subcmd, "test")) {
        addGoTestNames(out, ctx.prefix);
    }
}

fn addGoTestNames(out: *complete.CandidateBuffer, prefix: []const u8) void {
    var d = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return;
    defer d.close();

    var iter = d.iterate();
    while (iter.next() catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, "_test.go")) continue;

        const file = std.fs.cwd().openFile(entry.name, .{}) catch continue;
        defer file.close();

        var buf: [16384]u8 = undefined;
        const n = file.readAll(&buf) catch continue;
        const content = buf[0..n];

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (!std.mem.startsWith(u8, trimmed, "func Test")) continue;
            const after = trimmed[9..]; // after "func Test"
            // Find opening paren
            const paren = std.mem.indexOf(u8, after, "(") orelse continue;
            const name = std.mem.trim(u8, after[0..paren], " ");
            if (name.len == 0) continue;
            // Full test name is "Test" + name
            var full_buf: [128]u8 = undefined;
            if (4 + name.len > full_buf.len) continue;
            @memcpy(full_buf[0..4], "Test");
            @memcpy(full_buf[4..][0..name.len], name);
            const full = full_buf[0 .. 4 + name.len];
            if (prefix.len > 0 and !std.mem.startsWith(u8, full, prefix)) continue;
            out.add(full, .external_cmd);
        }
    }
}

// ---------------------------------------------------------------------------
// zig
// ---------------------------------------------------------------------------

fn provideZig(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) return;
    const subcmd = ctx.cmd_args[0];

    // zig build <step> — parse build.zig for step names
    if (std.mem.eql(u8, subcmd, "build")) {
        addZigBuildSteps(out, ctx.prefix);
    }
}

fn addZigBuildSteps(out: *complete.CandidateBuffer, prefix: []const u8) void {
    const alloc = std.heap.page_allocator;
    // `zig build --help` lists available steps
    const output = cmd.runCommand(&.{ "zig", "build", "-l" }, alloc) orelse return;
    defer alloc.free(output);

    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // Format: "  step_name   Description text"
        const name_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        const name = trimmed[0..name_end];
        if (name.len == 0) continue;
        if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) continue;
        // Extract description
        const desc_start = std.mem.trimLeft(u8, trimmed[name_end..], " \t");
        out.addWithDesc(name, desc_start, .external_cmd);
    }
}

// ---------------------------------------------------------------------------
// systemctl
// ---------------------------------------------------------------------------

fn provideSystemctl(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) return;
    const subcmd = ctx.cmd_args[0];
    const alloc = std.heap.page_allocator;

    const unit_cmds = [_][]const u8{
        "start", "stop", "restart", "reload", "enable", "disable",
        "status", "is-active", "is-enabled", "mask", "unmask",
    };
    var is_unit_cmd = false;
    for (unit_cmds) |uc| {
        if (std.mem.eql(u8, subcmd, uc)) { is_unit_cmd = true; break; }
    }
    if (!is_unit_cmd) return;

    const output = cmd.runCommand(&.{
        "systemctl", "list-units", "--no-legend", "--no-pager", "--plain", "-t", "service,timer,socket",
    }, alloc) orelse return;
    defer alloc.free(output);

    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // First column is unit name
        const name_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        const name = trimmed[0..name_end];
        if (ctx.prefix.len > 0 and !std.mem.startsWith(u8, name, ctx.prefix)) continue;
        out.add(name, .external_cmd);
    }
}

// ---------------------------------------------------------------------------
// cargo
// ---------------------------------------------------------------------------

fn provideCargo(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    if (ctx.cmd_args_len == 0) return;
    const subcmd = ctx.cmd_args[0];

    // cargo run/test/bench → binary target names from Cargo.toml
    if (std.mem.eql(u8, subcmd, "run") or std.mem.eql(u8, subcmd, "test") or
        std.mem.eql(u8, subcmd, "bench"))
    {
        addCargoTargets(out, ctx.prefix);
    }
}

fn addCargoTargets(out: *complete.CandidateBuffer, prefix: []const u8) void {
    // Parse [[bin]] entries from Cargo.toml
    const file = std.fs.cwd().openFile("Cargo.toml", .{}) catch return;
    defer file.close();

    var buf: [8192]u8 = undefined;
    const n = file.readAll(&buf) catch return;
    const content = buf[0..n];

    // Look for name = "..." under [[bin]] sections
    var iter = std.mem.splitScalar(u8, content, '\n');
    var in_bin = false;
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "[[bin]]")) {
            in_bin = true;
            continue;
        }
        if (trimmed.len > 0 and trimmed[0] == '[') {
            in_bin = false;
            continue;
        }
        if (in_bin and std.mem.startsWith(u8, trimmed, "name")) {
            // name = "target-name"
            const eq = std.mem.indexOf(u8, trimmed, "=") orelse continue;
            const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\"'");
            if (val.len == 0) continue;
            if (prefix.len > 0 and !std.mem.startsWith(u8, val, prefix)) continue;
            out.add(val, .external_cmd);
        }
    }

    // Also infer default binary name from [package] name
    var iter2 = std.mem.splitScalar(u8, content, '\n');
    var in_pkg = false;
    while (iter2.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "[package]")) {
            in_pkg = true;
            continue;
        }
        if (trimmed.len > 0 and trimmed[0] == '[') {
            in_pkg = false;
            continue;
        }
        if (in_pkg and std.mem.startsWith(u8, trimmed, "name")) {
            const eq = std.mem.indexOf(u8, trimmed, "=") orelse continue;
            const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\"'");
            if (val.len == 0) continue;
            if (prefix.len > 0 and !std.mem.startsWith(u8, val, prefix)) continue;
            out.addWithDesc(val, "default binary", .external_cmd);
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// docker compose — service names from compose file
// ---------------------------------------------------------------------------

pub fn provideDockerCompose(out: *complete.CandidateBuffer, ctx: *const complete.CompletionContext) void {
    // Called from cmd_completions.zig for "docker compose <subcmd> <service>"
    if (ctx.cmd_args_len < 2) return;

    // cmd_args = ["compose", subcmd, ...]
    const compose_subcmd = ctx.cmd_args[1];
    const svc_cmds = [_][]const u8{
        "up", "down", "start", "stop", "restart", "logs", "exec", "run",
        "build", "pull", "push", "rm", "ps", "top",
    };
    var is_svc_cmd = false;
    for (svc_cmds) |sc| {
        if (std.mem.eql(u8, compose_subcmd, sc)) { is_svc_cmd = true; break; }
    }
    if (!is_svc_cmd) return;

    addComposeServices(out, ctx.prefix);
}

fn addComposeServices(out: *complete.CandidateBuffer, prefix: []const u8) void {
    // Try common compose file names
    const filenames = [_][]const u8{
        "docker-compose.yml", "docker-compose.yaml",
        "compose.yml", "compose.yaml",
    };

    for (filenames) |fname| {
        const file = std.fs.cwd().openFile(fname, .{}) catch continue;
        defer file.close();

        var buf: [16384]u8 = undefined;
        const n = file.readAll(&buf) catch continue;
        const content = buf[0..n];

        // Simple YAML parsing: find "services:" section, then top-level keys
        const svc_pos = std.mem.indexOf(u8, content, "services:") orelse continue;
        const after = content[svc_pos + 9 ..];

        var iter = std.mem.splitScalar(u8, after, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            // Service names are indented by exactly 2 spaces (top-level under services)
            if (line.len >= 3 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ' and line[2] != '#') {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                // Must end with ':'
                if (trimmed.len > 1 and trimmed[trimmed.len - 1] == ':') {
                    const name = trimmed[0 .. trimmed.len - 1];
                    if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) continue;
                    out.add(name, .external_cmd);
                }
            } else if (line[0] != ' ' and line[0] != '#') {
                // Hit next top-level key, stop
                break;
            }
        }
        return; // found a compose file, done
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn addLines(out: *complete.CandidateBuffer, output: []const u8, prefix: []const u8) void {
    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len == 0) continue;
        if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) continue;
        out.add(name, .external_cmd);
    }
}
