const std = @import("std");

/// Lua library C sources (everything except lua.c and luac.c which are standalone programs)
const lua_lib_sources = [_][]const u8{
    "lapi.c",
    "lauxlib.c",
    "lbaselib.c",
    "lcode.c",
    "lcorolib.c",
    "lctype.c",
    "ldblib.c",
    "ldebug.c",
    "ldo.c",
    "ldump.c",
    "lfunc.c",
    "lgc.c",
    "linit.c",
    "liolib.c",
    "llex.c",
    "lmathlib.c",
    "lmem.c",
    "loadlib.c",
    "lobject.c",
    "lopcodes.c",
    "loslib.c",
    "lparser.c",
    "lstate.c",
    "lstring.c",
    "lstrlib.c",
    "ltable.c",
    "ltablib.c",
    "ltm.c",
    "lundump.c",
    "lutf8lib.c",
    "lvm.c",
    "lzio.c",
};

fn addLuaDep(mod: *std.Build.Module, b: *std.Build) void {
    const lua_dep = b.dependency("lua", .{});
    const lua_src = lua_dep.path("src");

    // Add Lua headers to the include path
    mod.addIncludePath(lua_src);

    // Compile Lua C sources and statically link them
    mod.addCSourceFiles(.{
        .root = lua_src,
        .files = &lua_lib_sources,
        .flags = &.{"-std=c99"},
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Xyron executable ---
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.linkSystemLibrary("sqlite3", .{});
    exe_mod.link_libc = true;

    // Lua: compiled from source via Zig package manager
    addLuaDep(exe_mod, b);

    // Platform-specific include/lib paths (sqlite3 only now)
    const resolved = target.result;
    if (resolved.os.tag == .macos) {
        exe_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        exe_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        exe_mod.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
        exe_mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
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
        "src/cmd_completions.zig",
    };

    for (test_modules) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.linkSystemLibrary("sqlite3", .{});
        mod.link_libc = true;

        // Lua: same as exe
        addLuaDep(mod, b);

        if (resolved.os.tag == .macos) {
            mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
            mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
            mod.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
            mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
        }

        const t = b.addTest(.{ .root_module = mod });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
