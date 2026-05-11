// source — run a script via `sh` and import its env changes.
//
// Not a true POSIX source (xyron isn't POSIX). Instead, runs the file
// under /bin/sh with `. <file>; env -0` and applies the resulting env diff
// to the current shell. Stores a snapshot of pre-source values so
// `deactivate` can undo the changes.
//
// This handles the common case (venv, nvm, rbenv activation scripts —
// anything that mostly exports env vars). Shell functions defined by
// the script are not imported. If the sourced script used to define a
// `deactivate` function, xyron's builtin `deactivate` replaces it.

const std = @import("std");
const environ_mod = @import("../environ.zig");
const source_stack = @import("source_stack.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stderr: std.fs.File, env: *environ_mod.Environ) Result {
    if (args.len == 0) {
        stderr.writeAll(
            \\xyron: source: usage: source <file>
            \\
            \\Runs the file under /bin/sh and imports exported env vars
            \\into the current shell. Use `deactivate` to undo.
            \\
        ) catch {};
        return .{ .exit_code = 1 };
    }

    const file = args[0];
    const allocator = std.heap.page_allocator;

    // Spawn `sh -c '. "<file>"; env -0'`
    // Using `.` (dot) which is POSIX source. Quote the filename to
    // handle spaces. We read env -0 output into a buffer.
    var cmd_buf: [4096]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, ". \"{s}\" && env -0", .{file}) catch {
        stderr.writeAll("xyron: source: path too long\n") catch {};
        return .{ .exit_code = 1 };
    };

    // env.set() syncs vars into the process environment via setenv(),
    // so /bin/sh will inherit our current env by default.
    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |e| {
        var ebuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "xyron: source: spawn failed: {s}\n", .{@errorName(e)}) catch "xyron: source: spawn failed\n";
        stderr.writeAll(msg) catch {};
        return .{ .exit_code = 1 };
    };

    // Read null-separated "KEY=VALUE\0..." output
    var out_list = std.ArrayList(u8).initCapacity(allocator, 8192) catch {
        _ = child.kill() catch {};
        return .{ .exit_code = 1 };
    };
    defer out_list.deinit(allocator);

    if (child.stdout) |f| {
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = f.read(&buf) catch break;
            if (n == 0) break;
            out_list.appendSlice(allocator, buf[0..n]) catch break;
        }
    }

    const term = child.wait() catch return .{ .exit_code = 127 };
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    if (exit_code != 0) {
        var ebuf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "xyron: source: script failed with exit {d}\n", .{exit_code}) catch "xyron: source: script failed\n";
        stderr.writeAll(msg) catch {};
        return .{ .exit_code = exit_code };
    }

    // Parse new env into key/value pairs.
    const new_env = out_list.items;

    // Collect keys that changed or were added. Also capture their current
    // values for the snapshot before we mutate anything.
    var changed_keys_buf: [source_stack.MAX_VARS_PER_SNAPSHOT][]const u8 = undefined;
    var n_changed: usize = 0;

    var it = std.mem.splitScalar(u8, new_env, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        const val = entry[eq + 1 ..];

        // Skip a handful of vars that `sh` sets just for its own run —
        // importing them would pollute the shell.
        if (std.mem.eql(u8, key, "_") or
            std.mem.eql(u8, key, "SHLVL") or
            std.mem.eql(u8, key, "PWD") or
            std.mem.eql(u8, key, "OLDPWD")) continue;

        const existing = env.get(key);
        const changed = existing == null or !std.mem.eql(u8, existing.?, val);
        if (!changed) continue;

        if (n_changed >= source_stack.MAX_VARS_PER_SNAPSHOT) {
            stderr.writeAll("xyron: source: too many env changes (snapshot capacity exceeded)\n") catch {};
            break;
        }
        changed_keys_buf[n_changed] = key;
        n_changed += 1;
    }

    if (n_changed == 0) {
        // Nothing to do — script had no env impact.
        return .{};
    }

    // Snapshot current values for changed keys (before mutation).
    const snap_alloc = std.heap.c_allocator;
    var snap = source_stack.capture(snap_alloc, env, changed_keys_buf[0..n_changed], file) catch {
        stderr.writeAll("xyron: source: failed to snapshot env\n") catch {};
        return .{ .exit_code = 1 };
    };

    // Apply changes: re-iterate the new env and set keys that changed.
    var it2 = std.mem.splitScalar(u8, new_env, 0);
    while (it2.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        const val = entry[eq + 1 ..];

        if (std.mem.eql(u8, key, "_") or
            std.mem.eql(u8, key, "SHLVL") or
            std.mem.eql(u8, key, "PWD") or
            std.mem.eql(u8, key, "OLDPWD")) continue;

        const existing = env.get(key);
        const changed = existing == null or !std.mem.eql(u8, existing.?, val);
        if (!changed) continue;

        env.set(key, val) catch {};
    }

    if (!source_stack.push(snap)) {
        snap.deinit();
        stderr.writeAll("xyron: source: snapshot stack full — applied changes but can't deactivate\n") catch {};
    }

    return .{};
}
