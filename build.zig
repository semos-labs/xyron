const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Shared module options (link sqlite3 + libc) ---
    const common_opts = std.Build.Module.CreateOptions{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    };
    _ = common_opts;

    // --- Xyron executable ---
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.linkSystemLibrary("sqlite3", .{});
    exe_mod.link_libc = true;

    // Platform-specific include/lib paths
    const resolved = target.result;
    if (resolved.os.tag == .macos) {
        exe_mod.linkSystemLibrary("lua", .{});
        // Homebrew: /opt/homebrew on arm64, /usr/local on x64
        exe_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        exe_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        exe_mod.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
        exe_mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    } else {
        // Linux: liblua5.4-dev — CI creates /usr/include/lua → lua5.4 symlink
        exe_mod.linkSystemLibrary("lua5.4", .{});
    }

    // C sources
    exe_mod.addCSourceFile(.{ .file = b.path("src/daemon_spawn.c") });

    const exe = b.addExecutable(.{ .name = "xyron", .root_module = exe_mod });
    b.installArtifact(exe);

    // Run step: `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Xyron shell");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---
    const test_step = b.step("test", "Run all unit tests");

    const test_modules = [_][]const u8{
        "src/types.zig",
        "src/token.zig",
        "src/parser.zig",
        "src/planner.zig",
        "src/builtins.zig",
        "src/attyx.zig",
        "src/prompt.zig",
        "src/executor.zig",
        "src/term.zig",
        "src/keys.zig",
        "src/editor.zig",
        "src/environ.zig",
        "src/expand.zig",
        "src/path_search.zig",
        "src/sqlite.zig",
        "src/history_db.zig",
        "src/history.zig",
        "src/jobs.zig",
        "src/lua_api.zig",
        "src/lua_hooks.zig",
        "src/lua_commands.zig",
        "src/highlight.zig",
        "src/complete.zig",
        "src/complete_providers.zig",
        "src/complete_help.zig",
        "src/fuzzy.zig",
        "src/aliases.zig",
        "src/attyx_bridge.zig",
        "src/protocol.zig",
        "src/rich_output.zig",
        "src/json_parser.zig",
        "src/migrate.zig",
        "src/block.zig",
        "src/block_ui.zig",
        "src/history_search.zig",
        "src/project_test.zig",
    };

    for (test_modules) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.linkSystemLibrary("sqlite3", .{});
        mod.link_libc = true;
        if (resolved.os.tag == .macos) {
            mod.linkSystemLibrary("lua", .{});
            mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
            mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
            mod.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
            mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
        } else {
            mod.linkSystemLibrary("lua5.4", .{});
        }

        const t = b.addTest(.{ .root_module = mod });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
