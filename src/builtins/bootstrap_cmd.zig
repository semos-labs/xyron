// builtins/bootstrap_cmd.zig — `xyron init` and `xyron new` commands.
//
// init: detect ecosystem, infer config, generate xyron.toml
// new: invoke native scaffolding tool, then run init pipeline

const std = @import("std");
const bootstrap = @import("../project/bootstrap.zig");
const term = @import("../term.zig");
const Result = @import("mod.zig").BuiltinResult;

fn write(f: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    f.writeAll(std.fmt.bufPrint(&buf, fmt, args) catch return) catch {};
}

// =============================================================================
// xyron init
// =============================================================================

pub fn runInit(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len > 0 and (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help"))) {
        stdout.writeAll(
            \\xyron init — initialize a project
            \\
            \\Detects the project ecosystem from existing files and generates
            \\a baseline xyron.toml with inferred commands and env sources.
            \\
            \\Usage:
            \\  xyron init              Generate xyron.toml in current directory
            \\
            \\Supported ecosystems:
            \\  package.json + bun.lock    Bun (scripts from package.json)
            \\  package.json               Node (scripts from package.json)
            \\  Cargo.toml                 Rust (build, test, run)
            \\  go.mod                     Go (run, test)
            \\  build.zig / build.zig.zon  Zig (build, test)
            \\  pyproject.toml / setup.py  Python (test)
            \\
            \\If xyron.toml already exists, init will refuse to overwrite it.
            \\
        ) catch {};
        return .{};
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Get cwd
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        stderr.writeAll("Cannot determine current directory\n") catch {};
        return .{ .exit_code = 1 };
    };

    // Check if xyron.toml already exists
    if (bootstrap.fileExists(cwd, "xyron.toml")) {
        stderr.writeAll("xyron.toml already exists. Remove it first to reinitialize.\n") catch {};
        return .{ .exit_code = 1 };
    }

    // Detect and infer
    const detected = bootstrap.detect(allocator, cwd);

    // Generate manifest
    const manifest = bootstrap.generateManifest(allocator, &detected);
    if (manifest.len == 0) {
        stderr.writeAll("Failed to generate manifest\n") catch {};
        return .{ .exit_code = 1 };
    }

    // Write xyron.toml
    var toml_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const toml_path = std.fmt.bufPrint(&toml_path_buf, "{s}/xyron.toml", .{cwd}) catch {
        stderr.writeAll("Path too long\n") catch {};
        return .{ .exit_code = 1 };
    };

    const file = std.fs.createFileAbsolute(toml_path, .{}) catch {
        stderr.writeAll("Cannot create xyron.toml\n") catch {};
        return .{ .exit_code = 1 };
    };
    defer file.close();
    file.writeAll(manifest) catch {
        stderr.writeAll("Cannot write xyron.toml\n") catch {};
        return .{ .exit_code = 1 };
    };

    // Print summary
    const eco_label = detected.ecosystem.label();
    if (detected.ecosystem != .unknown) {
        write(stdout, "\x1b[32m✓\x1b[0m Initialized \x1b[1m{s}\x1b[0m project  \x1b[2m({s}, detected via {s})\x1b[0m\n", .{
            detected.name, eco_label, detected.evidence,
        });
    } else {
        write(stdout, "\x1b[32m✓\x1b[0m Initialized \x1b[1m{s}\x1b[0m project\n", .{detected.name});
    }

    if (detected.scripts.len > 0) {
        write(stdout, "  \x1b[2mcommands:\x1b[0m ", .{});
        for (detected.scripts, 0..) |script, i| {
            if (i > 0) stdout.writeAll(", ") catch {};
            stdout.writeAll(script.name) catch {};
        }
        stdout.writeAll("\n") catch {};
    }

    write(stdout, "  \x1b[2menv:\x1b[0m ", .{});
    for (detected.env_sources, 0..) |src, i| {
        if (i > 0) stdout.writeAll(", ") catch {};
        stdout.writeAll(src) catch {};
    }
    stdout.writeAll("\n") catch {};

    stdout.writeAll("\n  \x1b[2mCreated xyron.toml\x1b[0m\n") catch {};
    return .{};
}

// =============================================================================
// xyron new <ecosystem> [name]
// =============================================================================

pub fn runNew(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0 or (args.len > 0 and (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")))) {
        const out = if (args.len > 0) stdout else stderr;
        out.writeAll(
            \\xyron new — create a new project
            \\
            \\Invokes the ecosystem's native scaffolding tool, then generates
            \\a xyron.toml with inferred commands and env sources.
            \\
            \\Usage:
            \\  xyron new <ecosystem> <name>
            \\
            \\Ecosystems:
            \\  bun       bun init
            \\  node      npm init -y
            \\  rust      cargo new / cargo init
            \\  go        go mod init
            \\  zig       zig init
            \\
            \\Examples:
            \\  xyron new bun my-app
            \\  xyron new rust my-crate
            \\  xyron new zig my-project
            \\
        ) catch {};
        return .{ .exit_code = if (args.len > 0) 0 else 1 };
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const eco_name = args[0];

    if (args.len < 2) {
        write(stderr, "Project name is required: xyron new {s} <name>\n", .{eco_name});
        return .{ .exit_code = 1 };
    }
    const project_name = args[1];

    // Resolve ecosystem
    const eco = parseEcosystem(eco_name) orelse {
        write(stderr, "Unknown ecosystem: {s}\n", .{eco_name});
        stderr.writeAll("Supported: bun, node, rust, go, zig\n") catch {};
        return .{ .exit_code = 1 };
    };

    // Build native command
    var cmd_buf: [4096]u8 = undefined;
    const native_cmd = buildNativeCommand(&cmd_buf, eco, project_name) orelse {
        write(stderr, "No scaffolding command for ecosystem: {s}\n", .{eco_name});
        return .{ .exit_code = 1 };
    };

    write(stdout, "\x1b[2mRunning:\x1b[0m {s}\n", .{native_cmd});

    // Run native tool
    term.suspendRawMode();
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", native_cmd }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch {
        term.resumeRawMode();
        write(stderr, "Failed to run: {s}\n", .{native_cmd});
        stderr.writeAll("Is the tool installed?\n") catch {};
        return .{ .exit_code = 1 };
    };

    const wait_result = child.wait() catch {
        term.resumeRawMode();
        stderr.writeAll("Failed to wait for scaffolding tool\n") catch {};
        return .{ .exit_code = 1 };
    };
    term.resumeRawMode();

    const code: u8 = switch (wait_result) { .Exited => |c| c, else => 1 };
    if (code != 0) {
        write(stderr, "Scaffolding tool exited with code {d}\n", .{code});
        return .{ .exit_code = code };
    }

    // Determine project directory (created as subdirectory of cwd)
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_dir = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ cwd, project_name }) catch cwd;

    // Run init pipeline on the new project
    if (bootstrap.fileExists(project_dir, "xyron.toml")) {
        stdout.writeAll("\n\x1b[2mxyron.toml already present — skipping init\x1b[0m\n") catch {};
        return .{};
    }

    const detected = bootstrap.detect(allocator, project_dir);
    const manifest = bootstrap.generateManifest(allocator, &detected);

    var toml_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const toml_path = std.fmt.bufPrint(&toml_path_buf, "{s}/xyron.toml", .{project_dir}) catch {
        stderr.writeAll("Path too long\n") catch {};
        return .{ .exit_code = 1 };
    };

    const file = std.fs.createFileAbsolute(toml_path, .{}) catch {
        stderr.writeAll("Cannot create xyron.toml\n") catch {};
        return .{ .exit_code = 1 };
    };
    defer file.close();
    file.writeAll(manifest) catch {
        stderr.writeAll("Cannot write xyron.toml\n") catch {};
        return .{ .exit_code = 1 };
    };

    stdout.writeAll("\n") catch {};
    write(stdout, "\x1b[32m✓\x1b[0m Created \x1b[1m{s}\x1b[0m with xyron.toml  \x1b[2m({s})\x1b[0m\n", .{
        detected.name, detected.ecosystem.label(),
    });
    return .{};
}

// =============================================================================
// Helpers
// =============================================================================

fn parseEcosystem(name: []const u8) ?bootstrap.Ecosystem {
    if (std.mem.eql(u8, name, "bun")) return .bun;
    if (std.mem.eql(u8, name, "node")) return .node;
    if (std.mem.eql(u8, name, "rust") or std.mem.eql(u8, name, "cargo")) return .rust;
    if (std.mem.eql(u8, name, "go")) return .go;
    if (std.mem.eql(u8, name, "zig")) return .zig_lang;
    if (std.mem.eql(u8, name, "python") or std.mem.eql(u8, name, "py")) return .python;
    return null;
}

fn buildNativeCommand(buf: []u8, eco: bootstrap.Ecosystem, name: []const u8) ?[]const u8 {
    // Create the directory and run the ecosystem's native tool inside it.
    // Tools like cargo new create the dir themselves; others need mkdir + cd.
    return switch (eco) {
        .bun => std.fmt.bufPrintZ(buf, "mkdir -p {s} && cd {s} && bun init", .{ name, name }) catch null,
        .node => std.fmt.bufPrintZ(buf, "mkdir -p {s} && cd {s} && npm init -y", .{ name, name }) catch null,
        .rust => std.fmt.bufPrintZ(buf, "cargo new {s}", .{name}) catch null,
        .go => std.fmt.bufPrintZ(buf, "mkdir -p {s} && cd {s} && go mod init {s}", .{ name, name, name }) catch null,
        .zig_lang => std.fmt.bufPrintZ(buf, "mkdir -p {s} && cd {s} && zig init", .{ name, name }) catch null,
        .python, .unknown => null,
    };
}

// Make fileExists accessible for the check in runNew
const fileExists = bootstrap.fileExists;
