// dir_env.zig — Per-directory environment management.
//
// On cd, automatically loads `.xyron.lua` (Lua config) or `.env` (KEY=VALUE)
// from the target directory. When leaving a directory, restores any
// environment variables that were set by the dir config.
//
// Security: only loads from directories the user has explicitly visited
// (via cd/jump). A confirmation prompt is shown on first load for a new dir.
// Trusted dirs are stored in SQLite.

const std = @import("std");
const lua_api = @import("lua_api.zig");
const environ_mod = @import("environ.zig");
const sqlite = @import("sqlite.zig");

const MAX_TRACKED_VARS = 32;

/// A set of env vars that were set by a directory config.
const DirState = struct {
    path: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    /// Keys of vars set (so we can unset on leave)
    keys: [MAX_TRACKED_VARS][64]u8 = undefined,
    key_lens: [MAX_TRACKED_VARS]usize = .{0} ** MAX_TRACKED_VARS,
    /// Previous values (for restore)
    prev_vals: [MAX_TRACKED_VARS][256]u8 = undefined,
    prev_val_lens: [MAX_TRACKED_VARS]usize = .{0} ** MAX_TRACKED_VARS,
    had_prev: [MAX_TRACKED_VARS]bool = .{false} ** MAX_TRACKED_VARS,
    count: usize = 0,
    lua_loaded: bool = false,
};

var current: ?DirState = null;
var trusted_db: ?sqlite.Db = null;

pub fn initTrustDb(db: ?sqlite.Db) void {
    trusted_db = db;
    if (trusted_db) |*d| {
        d.exec(
            "CREATE TABLE IF NOT EXISTS trusted_dirs (" ++
                "path TEXT PRIMARY KEY," ++
                "trusted_at INTEGER NOT NULL" ++
                ")",
        ) catch {};
    }
}

/// Called after every cd. Checks for .xyron.lua or .env in the new directory.
pub fn onCwdChange(
    old_cwd: []const u8,
    new_cwd: []const u8,
    env: *environ_mod.Environ,
    lua: lua_api.LuaState,
    stdout: std.fs.File,
) void {
    _ = old_cwd;

    // Unload previous dir env if we left that directory
    if (current) |*state| {
        const was_in = state.path[0..state.path_len];
        if (!std.mem.startsWith(u8, new_cwd, was_in)) {
            unloadDirEnv(state, env, stdout);
            current = null;
        }
    }

    // Check for .xyron.lua
    var lua_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lua_path = std.fmt.bufPrint(&lua_path_buf, "{s}/.xyron.lua", .{new_cwd}) catch return;
    if (std.fs.cwd().access(lua_path, .{})) |_| {
        if (isTrusted(new_cwd) or trustPrompt(new_cwd, ".xyron.lua", stdout)) {
            loadLuaConfig(lua_path, lua, new_cwd, stdout);
        }
        return;
    } else |_| {}

    // Check for .env
    var env_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const env_path = std.fmt.bufPrint(&env_path_buf, "{s}/.env", .{new_cwd}) catch return;
    if (std.fs.cwd().access(env_path, .{})) |_| {
        if (isTrusted(new_cwd) or trustPrompt(new_cwd, ".env", stdout)) {
            loadDotEnv(env_path, new_cwd, env, stdout);
        }
    } else |_| {}
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

fn loadLuaConfig(path: []const u8, lua: lua_api.LuaState, dir: []const u8, stdout: std.fs.File) void {
    const state = lua orelse return;
    const c_api = lua_api.c;

    // Null-terminate path for C API
    var path_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_z.len) return;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const path_ptr: [*:0]const u8 = path_z[0..path.len :0];
    if (c_api.luaL_loadfilex(state, path_ptr, null) != 0) {
        const err = c_api.lua_tolstring(state, -1, null);
        if (err) |e| {
            var buf: [512]u8 = undefined;
            stdout.writeAll(std.fmt.bufPrint(&buf, "\x1b[33mdir-env: error loading {s}: {s}\x1b[0m\n", .{ path, std.mem.span(e) }) catch "") catch {};
        }
        c_api.lua_settop(state, -(1) - 1);
        return;
    }

    if (lua_api.pcall(state, 0, 0) != 0) {
        const err = c_api.lua_tolstring(state, -1, null);
        if (err) |e| {
            var buf: [512]u8 = undefined;
            stdout.writeAll(std.fmt.bufPrint(&buf, "\x1b[33mdir-env: {s}\x1b[0m\n", .{std.mem.span(e)}) catch "") catch {};
        }
        c_api.lua_settop(state, -(1) - 1);
        return;
    }

    var state_val = DirState{};
    state_val.lua_loaded = true;
    const len = @min(dir.len, state_val.path.len);
    @memcpy(state_val.path[0..len], dir[0..len]);
    state_val.path_len = len;
    current = state_val;

    var buf: [512]u8 = undefined;
    stdout.writeAll(std.fmt.bufPrint(&buf, "\x1b[2mdir-env: loaded .xyron.lua\x1b[0m\n", .{}) catch "") catch {};
}

fn loadDotEnv(path: []const u8, dir: []const u8, env: *environ_mod.Environ, stdout: std.fs.File) void {
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    var state_val = DirState{};
    const dlen = @min(dir.len, state_val.path.len);
    @memcpy(state_val.path[0..dlen], dir[0..dlen]);
    state_val.path_len = dlen;

    var read_buf: [8192]u8 = undefined;
    const n = file.readAll(&read_buf) catch return;
    var line_iter = std.mem.splitScalar(u8, read_buf[0..n], '\n');

    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const eq = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const key = std.mem.trimRight(u8, trimmed[0..eq], " \t");
        var val = std.mem.trimLeft(u8, trimmed[eq + 1 ..], " \t");
        val = std.mem.trimRight(u8, val, " \t\r");
        // Strip quotes
        if (val.len >= 2) {
            if ((val[0] == '"' and val[val.len - 1] == '"') or
                (val[0] == '\'' and val[val.len - 1] == '\''))
            {
                val = val[1 .. val.len - 1];
            }
        }

        if (key.len == 0 or key.len > 63) continue;
        if (state_val.count >= MAX_TRACKED_VARS) break;

        // Save previous value for restore
        const idx = state_val.count;
        const kl = @min(key.len, 64);
        @memcpy(state_val.keys[idx][0..kl], key[0..kl]);
        state_val.key_lens[idx] = kl;

        if (env.get(key)) |prev| {
            state_val.had_prev[idx] = true;
            const pl = @min(prev.len, 256);
            @memcpy(state_val.prev_vals[idx][0..pl], prev[0..pl]);
            state_val.prev_val_lens[idx] = pl;
        }

        env.set(key, val) catch {};
        state_val.count += 1;
    }

    if (state_val.count > 0) {
        current = state_val;
        var buf: [128]u8 = undefined;
        stdout.writeAll(std.fmt.bufPrint(&buf, "\x1b[2mdir-env: loaded .env ({d} vars)\x1b[0m\n", .{state_val.count}) catch "") catch {};
    }
}

fn unloadDirEnv(state: *const DirState, env: *environ_mod.Environ, stdout: std.fs.File) void {
    // Restore previous env vars
    for (0..state.count) |i| {
        const key = state.keys[i][0..state.key_lens[i]];
        if (state.had_prev[i]) {
            const prev = state.prev_vals[i][0..state.prev_val_lens[i]];
            env.set(key, prev) catch {};
        } else {
            env.unset(key);
        }
    }
    if (state.count > 0) {
        var buf: [128]u8 = undefined;
        stdout.writeAll(std.fmt.bufPrint(&buf, "\x1b[2mdir-env: unloaded {d} vars\x1b[0m\n", .{state.count}) catch "") catch {};
    }
}

// ---------------------------------------------------------------------------
// Trust management
// ---------------------------------------------------------------------------

fn isTrusted(dir: []const u8) bool {
    var db = &(trusted_db orelse return false);
    var stmt = db.prepare("SELECT 1 FROM trusted_dirs WHERE path = ?1") catch return false;
    defer stmt.deinit();
    stmt.bindText(1, dir);
    return stmt.step() catch false;
}

fn markTrusted(dir: []const u8) void {
    var db = &(trusted_db orelse return);
    var stmt = db.prepare("INSERT OR REPLACE INTO trusted_dirs (path, trusted_at) VALUES (?1, ?2)") catch return;
    defer stmt.deinit();
    stmt.bindText(1, dir);
    stmt.bindInt(2, std.time.timestamp());
    _ = stmt.step() catch {};
}

fn trustPrompt(dir: []const u8, filename: []const u8, stdout: std.fs.File) bool {
    // Show prompt asking user to trust this directory
    var buf: [512]u8 = undefined;
    stdout.writeAll(std.fmt.bufPrint(&buf, "\x1b[33mdir-env: {s} found {s}. Trust this directory? [y/N] \x1b[0m", .{ dir, filename }) catch "") catch {};

    // Read single char from /dev/tty
    const tty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_only }) catch return false;
    defer tty.close();

    var input: [1]u8 = undefined;
    const n = tty.read(&input) catch return false;
    if (n == 0) return false;

    stdout.writeAll("\n") catch {};

    if (input[0] == 'y' or input[0] == 'Y') {
        markTrusted(dir);
        return true;
    }
    return false;
}
