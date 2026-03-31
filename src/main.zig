// main.zig — Xyron shell entrypoint.
//
// Supports three modes:
//   (default)        Interactive shell with terminal UI
//   --headless       Headless runtime backend (binary protocol)
//   --headless-json  Headless runtime backend (JSON debug mode)

const std = @import("std");
const shell_mod = @import("shell.zig");
const headless_mod = @import("headless.zig");

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var headless = false;
    var json_mode = false;
    var enable_ipc = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try std.fs.File.stdout().writeAll("xyron " ++ version ++ "\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.fs.File.stdout().writeAll(
                \\xyron — a shell for Attyx
                \\
                \\Usage: xyron [options]
                \\
                \\Options:
                \\  -l, --login          Start as a login shell
                \\  -v, --version        Print version and exit
                \\  -h, --help           Show this help
                \\  --headless           Headless runtime mode (binary protocol)
                \\  --headless-json      Headless runtime mode (JSON debug protocol)
                \\  --ipc                Enable Unix socket IPC for external integration
                \\
            );
            return;
        }
        if (std.mem.eql(u8, arg, "--headless")) headless = true;
        if (std.mem.eql(u8, arg, "--headless-json")) { headless = true; json_mode = true; }
        if (std.mem.eql(u8, arg, "--ipc")) enable_ipc = true;
    }

    // Auto-enable IPC when running inside Attyx
    if (!enable_ipc and !headless) {
        if (std.posix.getenv("ATTYX")) |v| {
            if (std.mem.eql(u8, v, "1")) enable_ipc = true;
        }
    }

    if (headless) {
        var runtime = try headless_mod.HeadlessRuntime.init(allocator, json_mode);
        defer runtime.deinit();
        runtime.run();
        return;
    }

    // Normal interactive shell
    var sh = try shell_mod.Shell.init(allocator);
    defer sh.deinit();
    sh.ipc_enabled = enable_ipc;
    try sh.run();

    std.process.exit(sh.last_exit_code);
}
