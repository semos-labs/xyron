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
    exe_mod.linkSystemLibrary("lua", .{});
    exe_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    exe_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe_mod.link_libc = true;

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
        "src/history_search.zig",
    };

    for (test_modules) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.linkSystemLibrary("sqlite3", .{});
        mod.linkSystemLibrary("lua", .{});
        mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        mod.link_libc = true;

        const t = b.addTest(.{ .root_module = mod });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
