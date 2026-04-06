// lua_api.zig — Lua VM wrapper and xyron.* API surface.
//
// Manages the Lua state lifecycle and registers the xyron global table
// with functions for environment access, command execution, hook
// registration, custom command definition, and Attyx queries.
//
// All Lua C API macros that don't translate to Zig are called through
// their underlying C functions directly.

const std = @import("std");
pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});
const environ_mod = @import("environ.zig");
const lua_hooks = @import("lua_hooks.zig");
const lua_commands = @import("lua_commands.zig");
const lua_completions = @import("lua_completions.zig");

pub const LuaState = ?*c.lua_State;

/// Pointers to shell state, stored in Lua registry for API callbacks.
var global_env: ?*environ_mod.Environ = null;
var global_attyx_enabled: bool = false;

/// Update the environment pointer (must be called after Shell is at its final location).
pub fn setEnv(env: *environ_mod.Environ) void {
    global_env = env;
}

/// Initialize the Lua VM and register the xyron API.
pub fn init(env: *environ_mod.Environ, attyx_enabled: bool) LuaState {
    global_env = env;
    global_attyx_enabled = attyx_enabled;

    const L = c.luaL_newstate() orelse return null;
    c.luaL_openlibs(L);

    // Create xyron global table
    c.lua_createtable(L, 0, 16);

    // Register API functions
    registerFn(L, "getenv", apiGetenv);
    registerFn(L, "setenv", apiSetenv);
    registerFn(L, "unsetenv", apiUnsetenv);
    registerFn(L, "cwd", apiCwd);
    registerFn(L, "is_attyx", apiIsAttyx);
    registerFn(L, "on", apiOn);
    registerFn(L, "command", apiCommand);
    registerFn(L, "exec", apiExec);
    registerFn(L, "capture", apiCapture);
    // xyron.prompt = { register = fn, configure = fn, init = fn }
    c.lua_createtable(L, 0, 3);
    registerFn(L, "register", apiPromptRegister);
    registerFn(L, "configure", apiPromptConfigure);
    registerFn(L, "init", apiPromptInit);
    c.lua_setfield(L, -2, "prompt");
    // xyron.config = { vim_mode = fn, block_ui = fn, completion = fn }
    c.lua_createtable(L, 0, 3);
    registerFn(L, "vim_mode", apiVimMode);
    registerFn(L, "block_ui", apiBlockUi);
    registerFn(L, "completion", apiCompletion);
    c.lua_setfield(L, -2, "config");
    // Keep old top-level names working for backward compat
    registerFn(L, "vim_mode", apiVimMode);
    registerFn(L, "block_ui", apiBlockUi);
    registerFn(L, "completion", apiCompletion);
    registerFn(L, "alias", apiAlias);
    registerFn(L, "history_query", apiHistoryQuery);
    registerFn(L, "history_replay", apiHistoryReplay);
    registerFn(L, "last_block", apiLastBlock);
    registerFn(L, "popup", apiPopup);
    registerFn(L, "pick", apiPick);
    registerFn(L, "has_attyx_ui", apiHasAttyxUi);
    registerFn(L, "project_info", apiProjectInfo);
    registerFn(L, "complete", apiComplete);

    // Set as global "xyron"
    c.lua_setglobal(L, "xyron");

    // xyron.lazy_command(name, module_name) — register a command that
    // defers require(module_name) until first invocation.
    // xyron.defer(fn) — queue a function to run after the first prompt renders.
    const lazy_code =
        \\xyron._deferred = {}
        \\function xyron.lazy_command(name, mod)
        \\  xyron.command(name, function(args)
        \\    local m = require(mod)
        \\    local fn = type(m) == "function" and m or (type(m) == "table" and m.run)
        \\    if fn then
        \\      xyron.command(name, fn)
        \\      return fn(args)
        \\    end
        \\  end)
        \\end
        \\function xyron.defer(fn)
        \\  table.insert(xyron._deferred, fn)
        \\end
        \\function xyron.source(script, opts)
        \\  opts = opts or {}
        \\  local vars = opts.vars
        \\  local run_cmd = opts.run
        \\  local export_parts = {}
        \\  if vars then
        \\    for _, v in ipairs(vars) do
        \\      export_parts[#export_parts+1] = string.format('echo "::xyron_env::%s=${%s}"', v, v)
        \\    end
        \\  else
        \\    export_parts[#export_parts+1] = 'env -0 | tr "\\0" "\\n" | while IFS= read -r line; do echo "::xyron_env::$line"; done'
        \\  end
        \\  local export = table.concat(export_parts, " && ")
        \\  local inner
        \\  if run_cmd then
        \\    inner = string.format('source %q && %s && echo "::xyron_env_marker::" && %s', script, run_cmd, export)
        \\  else
        \\    inner = string.format('source %q && %s', script, export)
        \\  end
        \\  local result = xyron.capture("bash -c '" .. inner:gsub("'", "'\\''") .. "'")
        \\  if result.exit_code ~= 0 then
        \\    if run_cmd then io.write(result.output) end
        \\    return false
        \\  end
        \\  local output = result.output
        \\  local user_output, env_section
        \\  if run_cmd then
        \\    local marker = "::xyron_env_marker::\n"
        \\    local pos = output:find(marker, 1, true)
        \\    if pos then
        \\      user_output = output:sub(1, pos - 1)
        \\      env_section = output:sub(pos + #marker)
        \\    else
        \\      user_output = output
        \\      env_section = ""
        \\    end
        \\    io.write(user_output)
        \\  else
        \\    env_section = output
        \\  end
        \\  for line in env_section:gmatch("::xyron_env::([^\n]+)") do
        \\    local k, v = line:match("^([^=]+)=(.*)")
        \\    if k and #k > 0 then
        \\      local cur = xyron.getenv(k)
        \\      if cur ~= v then xyron.setenv(k, v) end
        \\    end
        \\  end
        \\  return true
        \\end
    ;
    if (c.luaL_loadstring(L, lazy_code) == 0) {
        _ = pcall(L, 0, 0);
    } else {
        c.lua_settop(L, -2);
    }

    // Disable io.popen — it calls fork() which is unsafe with background
    // threads (deadlocks on inherited mutexes → SIGABRT).
    // Use xyron.capture() instead.
    if (c.luaL_loadstring(L, "io.popen = nil") == 0) {
        _ = pcall(L, 0, 0);
    } else {
        c.lua_settop(L, -2);
    }

    return L;
}

pub fn deinit(L: LuaState) void {
    if (L) |state| c.lua_close(state);
}

/// Set package.path so require() resolves from the config directory.
pub fn setPackagePath(L: LuaState, config_dir: []const u8) void {
    const state = L orelse return;
    // package.path = config_dir.."/?.lua;"..config_dir.."/?/init.lua;"..default
    var code_buf: [1024]u8 = undefined;
    const code = std.fmt.bufPrintZ(&code_buf,
        "package.path = \"{s}/?.lua;{s}/?/init.lua;\" .. package.path",
        .{ config_dir, config_dir },
    ) catch return;
    if (c.luaL_loadstring(state, code) == 0) {
        _ = pcall(state, 0, 0);
    } else {
        c.lua_settop(state, -2); // pop error
    }
}

/// Run all functions queued via xyron.defer(), then clear the queue.
pub fn runDeferred(L: LuaState) void {
    const state = L orelse return;
    const code =
        \\for _, fn in ipairs(xyron._deferred or {}) do
        \\  local ok, err = pcall(fn)
        \\  if not ok then
        \\    io.stderr:write("xyron: deferred: " .. tostring(err) .. "\n")
        \\  end
        \\end
        \\xyron._deferred = {}
    ;
    if (c.luaL_loadstring(state, code) == 0) {
        _ = pcall(state, 0, 0);
    } else {
        c.lua_settop(state, -2);
    }
}

/// Clear user module cache so require() re-executes on reload.
/// Preserves built-in modules (anything not in the config directory).
pub fn clearModuleCache(L: LuaState) void {
    const state = L orelse return;
    // for k in pairs(package.loaded) do
    //   if type(package.loaded[k]) ~= "boolean" then
    //     package.loaded[k] = nil
    //   end
    // end
    const code =
        \\for k, v in pairs(package.loaded) do
        \\  if type(v) ~= "boolean" and k ~= "_G" and k ~= "string"
        \\     and k ~= "table" and k ~= "math" and k ~= "io"
        \\     and k ~= "os" and k ~= "coroutine" and k ~= "debug"
        \\     and k ~= "package" and k ~= "utf8" then
        \\    package.loaded[k] = nil
        \\  end
        \\end
    ;
    if (c.luaL_loadstring(state, code) == 0) {
        _ = pcall(state, 0, 0);
    } else {
        c.lua_settop(state, -2);
    }
}

/// Load and execute a config file. Returns false on error.
pub fn loadConfig(L: LuaState, path: [*:0]const u8) bool {
    const state = L orelse return false;
    if (c.luaL_loadfilex(state, path, null) != 0) {
        reportError(state);
        return false;
    }
    if (pcall(state, 0, 0) != 0) {
        reportError(state);
        return false;
    }
    return true;
}

/// Call pcall (avoiding the broken macro).
pub fn pcall(L: *c.lua_State, nargs: c_int, nresults: c_int) c_int {
    return c.lua_pcallk(L, nargs, nresults, 0, 0, null);
}

/// Pop and print the error message from the Lua stack.
fn reportError(L: *c.lua_State) void {
    const msg = c.lua_tolstring(L, -1, null);
    if (msg) |m| {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("xyron: lua: ") catch {};
        stderr.writeAll(std.mem.span(m)) catch {};
        stderr.writeAll("\n") catch {};
    }
    pop(L, 1);
}

// ---------------------------------------------------------------------------
// API implementations
// ---------------------------------------------------------------------------

/// xyron.getenv(name) -> string|nil
fn apiGetenv(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const name = c.lua_tolstring(state, 1, null) orelse return 0;
    const env = global_env orelse return 0;

    if (env.get(std.mem.span(name))) |val| {
        _ = c.lua_pushlstring(state, val.ptr, val.len);
        return 1;
    }
    c.lua_pushnil(state);
    return 1;
}

/// xyron.setenv(name, value)
fn apiSetenv(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const name = c.lua_tolstring(state, 1, null) orelse return 0;
    const val = c.lua_tolstring(state, 2, null) orelse return 0;
    const env = global_env orelse return 0;
    env.set(std.mem.span(name), std.mem.span(val)) catch {};
    return 0;
}

/// xyron.unsetenv(name)
fn apiUnsetenv(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const name = c.lua_tolstring(state, 1, null) orelse return 0;
    const env = global_env orelse return 0;
    env.unset(std.mem.span(name));
    return 0;
}

/// xyron.cwd() -> string
fn apiCwd(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&buf) catch {
        c.lua_pushnil(state);
        return 1;
    };
    _ = c.lua_pushlstring(state, cwd.ptr, cwd.len);
    return 1;
}

/// xyron.is_attyx() -> boolean
fn apiIsAttyx(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    c.lua_pushboolean(state, if (global_attyx_enabled) 1 else 0);
    return 1;
}

/// xyron.on(event_name, callback) — register a hook
fn apiOn(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const name = c.lua_tolstring(state, 1, null) orelse return 0;

    if (c.lua_type(state, 2) != c.LUA_TFUNCTION) return 0;

    // Store the callback as a registry reference
    c.lua_pushvalue(state, 2);
    const ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);
    lua_hooks.registerHook(std.mem.span(name), ref);
    return 0;
}

/// xyron.command(name, callback) — register a custom command
fn apiCommand(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const name = c.lua_tolstring(state, 1, null) orelse return 0;

    if (c.lua_type(state, 2) != c.LUA_TFUNCTION) return 0;

    c.lua_pushvalue(state, 2);
    const ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);
    lua_commands.registerCommand(std.mem.span(name), ref);
    return 0;
}

/// xyron.complete(cmd_name, callback) — register a completion provider
fn apiComplete(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const name = c.lua_tolstring(state, 1, null) orelse return 0;

    if (c.lua_type(state, 2) != c.LUA_TFUNCTION) return 0;

    c.lua_pushvalue(state, 2);
    const ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);
    lua_completions.registerProvider(std.mem.span(name), ref);
    return 0;
}

/// xyron.exec(cmd_string) -> {exit_code=N}
fn apiExec(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const cmd = c.lua_tolstring(state, 1, null) orelse return 0;
    const cmd_str = std.mem.span(cmd);

    // Drain background threads before fork to avoid deadlocks
    const git_info = @import("git_info.zig");
    git_info.waitForRefresh();

    // Execute via system sh for simplicity
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd_str }, std.heap.page_allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch {
        c.lua_createtable(state, 0, 1);
        c.lua_pushinteger(state, 127);
        c.lua_setfield(state, -2, "exit_code");
        return 1;
    };

    const term = child.wait() catch {
        c.lua_createtable(state, 0, 1);
        c.lua_pushinteger(state, 127);
        c.lua_setfield(state, -2, "exit_code");
        return 1;
    };

    const code: c_int = switch (term) {
        .Exited => |co| @intCast(co),
        else => 1,
    };

    c.lua_createtable(state, 0, 1);
    c.lua_pushinteger(state, code);
    c.lua_setfield(state, -2, "exit_code");
    return 1;
}

/// xyron.capture(cmd_string) -> {output=string, exit_code=N}
/// Like exec, but captures stdout and returns it as a string.
fn apiCapture(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const cmd = c.lua_tolstring(state, 1, null) orelse return 0;
    const cmd_str = std.mem.span(cmd);

    // Drain background threads before fork to avoid deadlocks
    const git_info = @import("git_info.zig");
    git_info.waitForRefresh();

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd_str }, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch {
        c.lua_createtable(state, 0, 2);
        _ = c.lua_pushlstring(state, "", 0);
        c.lua_setfield(state, -2, "output");
        c.lua_pushinteger(state, 127);
        c.lua_setfield(state, -2, "exit_code");
        return 1;
    };

    // Read stdout with poll timeout
    var output_buf: [65536]u8 = undefined;
    var total: usize = 0;

    const stdout_fd = if (child.stdout) |f| f.handle else {
        _ = child.wait() catch {};
        c.lua_createtable(state, 0, 2);
        _ = c.lua_pushlstring(state, "", 0);
        c.lua_setfield(state, -2, "output");
        c.lua_pushinteger(state, 127);
        c.lua_setfield(state, -2, "exit_code");
        return 1;
    };

    const posix = std.posix;
    var fds = [_]posix.pollfd{.{
        .fd = stdout_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    var deadline: i32 = 5000; // 5s timeout
    while (total < output_buf.len and deadline > 0) {
        const start = std.time.milliTimestamp();
        const ready = posix.poll(&fds, deadline) catch break;
        const elapsed: i32 = @intCast(@min(std.time.milliTimestamp() - start, 5000));
        deadline -= elapsed;
        if (ready == 0) break;
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(stdout_fd, output_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        } else break;
    }

    const term = child.wait() catch {
        c.lua_createtable(state, 0, 2);
        _ = c.lua_pushlstring(state, &output_buf, total);
        c.lua_setfield(state, -2, "output");
        c.lua_pushinteger(state, 127);
        c.lua_setfield(state, -2, "exit_code");
        return 1;
    };

    const code: c_int = switch (term) {
        .Exited => |co| @intCast(co),
        else => 1,
    };

    c.lua_createtable(state, 0, 2);
    _ = c.lua_pushlstring(state, &output_buf, total);
    c.lua_setfield(state, -2, "output");
    c.lua_pushinteger(state, code);
    c.lua_setfield(state, -2, "exit_code");
    return 1;
}

const aliases = @import("aliases.zig");
const bridge = @import("attyx_bridge.zig");

const history_db_mod = @import("history_db.zig");

/// Global vim mode flag — set by Lua config, applied to editor when created.
pub var vim_mode_enabled: bool = false;
var global_hdb: ?*history_db_mod.HistoryDb = null;

pub fn setHistoryDb(hdb: *history_db_mod.HistoryDb) void {
    global_hdb = hdb;
}

/// xyron.block_ui(enabled) — enable/disable block UI
fn apiBlockUi(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    if (c.lua_type(state, 1) == c.LUA_TBOOLEAN) {
        @import("block_ui.zig").enabled = c.lua_toboolean(state, 1) != 0;
    }
    return 0;
}

/// xyron.overlay(enabled) — enable/disable floating overlay for completions
/// xyron.completion(enabled, opts?) — configure completion behavior
/// enabled: boolean — enable/disable completions entirely
/// opts: optional table { on_demand = bool } — when true, no as-you-type; only Tab/Ctrl+Space
fn apiCompletion(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const ov = @import("overlay.zig");

    if (c.lua_type(state, 1) == c.LUA_TBOOLEAN) {
        ov.enabled = c.lua_toboolean(state, 1) != 0;
    }

    // Parse optional opts table
    if (c.lua_type(state, 2) == c.LUA_TTABLE) {
        _ = c.lua_getfield(state, 2, "on_demand");
        if (c.lua_type(state, -1) == c.LUA_TBOOLEAN) {
            ov.on_demand = c.lua_toboolean(state, -1) != 0;
        }
        c.lua_pop(state, 1);
    }

    return 0;
}

/// xyron.vim_mode(enabled) — enable/disable vim mode
fn apiVimMode(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    if (c.lua_type(state, 1) == c.LUA_TBOOLEAN) {
        vim_mode_enabled = c.lua_toboolean(state, 1) != 0;
    }
    return 0;
}

/// xyron.has_attyx_ui() -> boolean
fn apiHasAttyxUi(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    c.lua_pushboolean(state, if (bridge.isAvailable()) 1 else 0);
    return 1;
}

/// xyron.popup(text, title?) — show content in popup/terminal
fn apiPopup(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const text = c.lua_tolstring(state, 1, null) orelse return 0;
    const title_raw = c.lua_tolstring(state, 2, null);
    const title = if (title_raw) |t| std.mem.span(t) else "popup";
    bridge.popup(std.mem.span(text), title, std.fs.File.stdout(), std.heap.page_allocator);
    return 0;
}

/// xyron.pick(items, title?) -> string|nil
/// items = {"a", "b"} or {{label="a", desc="..."}, ...}
fn apiPick(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    if (c.lua_type(state, 1) != c.LUA_TTABLE) return 0;

    // Build items from Lua table
    var items: [128]bridge.PickerItem = undefined;
    var item_count: usize = 0;
    const len = c.lua_rawlen(state, 1);
    var i: usize = 1;

    while (i <= len and item_count < 128) : (i += 1) {
        _ = c.lua_rawgeti(state, 1, @intCast(i));
        if (c.lua_type(state, -1) == c.LUA_TSTRING) {
            const s = c.lua_tolstring(state, -1, null);
            if (s) |str| {
                items[item_count] = .{ .label = std.mem.span(str) };
                item_count += 1;
            }
        }
        c.lua_settop(state, -(1) - 1);
    }

    if (item_count == 0) { c.lua_pushnil(state); return 1; }

    const title_raw = c.lua_tolstring(state, 2, null);
    const title = if (title_raw) |t| std.mem.span(t) else "Pick";

    const result = bridge.picker(items[0..item_count], title, std.fs.File.stdout(), std.heap.page_allocator);

    if (result.selected) |sel| {
        _ = c.lua_pushlstring(state, sel.ptr, sel.len);
    } else {
        c.lua_pushnil(state);
    }
    return 1;
}

/// Global ref to block table for last_block
var global_blocks: ?*@import("block.zig").BlockTable = null;

pub fn setBlockTable(bt: *@import("block.zig").BlockTable) void {
    global_blocks = bt;
}

/// xyron.last_block() -> table with block metadata
fn apiLastBlock(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const bt = global_blocks orelse { c.lua_pushnil(state); return 1; };
    const blk = bt.last() orelse { c.lua_pushnil(state); return 1; };

    c.lua_createtable(state, 0, 6);

    c.lua_pushinteger(state, @intCast(blk.id));
    c.lua_setfield(state, -2, "id");

    _ = c.lua_pushlstring(state, blk.rawSlice().ptr, blk.raw_len);
    c.lua_setfield(state, -2, "input");

    c.lua_pushinteger(state, @intCast(blk.exit_code));
    c.lua_setfield(state, -2, "exit_code");

    c.lua_pushinteger(state, blk.durationMs());
    c.lua_setfield(state, -2, "duration_ms");

    _ = c.lua_pushlstring(state, blk.status.label().ptr, blk.status.label().len);
    c.lua_setfield(state, -2, "status");

    _ = c.lua_pushlstring(state, blk.cwdSlice().ptr, blk.cwd_len);
    c.lua_setfield(state, -2, "cwd");

    return 1;
}

// ---------------------------------------------------------------------------
// Project info — exposes active project state to Lua
// ---------------------------------------------------------------------------

/// Cached project info for Lua access. Updated by shell on context changes.
pub const ProjectInfoCache = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    root: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    status: enum { none, valid, invalid } = .none,
    commands_count: usize = 0,
    services_count: usize = 0,
    env_loaded: usize = 0,
    missing_secrets: usize = 0,
};

var global_project_info: ProjectInfoCache = .{};

pub fn setProjectInfo(info: ProjectInfoCache) void {
    global_project_info = info;
}

pub fn getProjectInfo() *const ProjectInfoCache {
    return &global_project_info;
}

/// xyron.project_info() -> table { name, root, status, commands, services, env_loaded, missing_secrets } or nil
fn apiProjectInfo(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const info = &global_project_info;

    if (info.status == .none) {
        c.lua_pushnil(state);
        return 1;
    }

    c.lua_createtable(state, 0, 7);

    if (info.name_len > 0) {
        _ = c.lua_pushlstring(state, &info.name, info.name_len);
        c.lua_setfield(state, -2, "name");
    }

    if (info.root_len > 0) {
        _ = c.lua_pushlstring(state, &info.root, info.root_len);
        c.lua_setfield(state, -2, "root");
    }

    const status_str: []const u8 = switch (info.status) {
        .valid => "valid",
        .invalid => "invalid",
        .none => "none",
    };
    _ = c.lua_pushlstring(state, status_str.ptr, status_str.len);
    c.lua_setfield(state, -2, "status");

    c.lua_pushinteger(state, @intCast(info.commands_count));
    c.lua_setfield(state, -2, "commands");

    c.lua_pushinteger(state, @intCast(info.services_count));
    c.lua_setfield(state, -2, "services");

    c.lua_pushinteger(state, @intCast(info.env_loaded));
    c.lua_setfield(state, -2, "env_loaded");

    c.lua_pushinteger(state, @intCast(info.missing_secrets));
    c.lua_setfield(state, -2, "missing_secrets");

    return 1;
}

/// xyron.history_query({text="...", failed=true, limit=N}) -> array of entries
fn apiHistoryQuery(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const hdb = global_hdb orelse { c.lua_pushnil(state); return 1; };

    var q = history_db_mod.HistoryQuery{};

    // Parse query table if provided
    if (c.lua_type(state, 1) == c.LUA_TTABLE) {
        _ = c.lua_getfield(state, 1, "text");
        if (c.lua_type(state, -1) == c.LUA_TSTRING) {
            const s = c.lua_tolstring(state, -1, null);
            if (s) |str| q.text_contains = std.mem.span(str);
        }
        c.lua_settop(state, -(1) - 1);

        _ = c.lua_getfield(state, 1, "cwd");
        if (c.lua_type(state, -1) == c.LUA_TSTRING) {
            const s = c.lua_tolstring(state, -1, null);
            if (s) |str| q.cwd_filter = std.mem.span(str);
        }
        c.lua_settop(state, -(1) - 1);

        _ = c.lua_getfield(state, 1, "failed");
        if (c.lua_toboolean(state, -1) != 0) q.only_failed = true;
        c.lua_settop(state, -(1) - 1);

        _ = c.lua_getfield(state, 1, "limit");
        if (c.lua_type(state, -1) == c.LUA_TNUMBER) {
            const n = c.lua_tointegerx(state, -1, null);
            if (n > 0) q.limit = @intCast(@min(n, 100));
        }
        c.lua_settop(state, -(1) - 1);
    }

    var entries: [100]history_db_mod.HistoryEntry = undefined;
    var str_buf: [100 * 256]u8 = undefined;
    const count = hdb.query(&q, entries[0..q.limit], &str_buf);

    // Return as Lua array of tables
    c.lua_createtable(state, @intCast(count), 0);
    for (0..count) |i| {
        c.lua_createtable(state, 0, 5);
        c.lua_pushinteger(state, entries[i].id);
        c.lua_setfield(state, -2, "id");
        _ = c.lua_pushlstring(state, entries[i].raw_input.ptr, entries[i].raw_input.len);
        c.lua_setfield(state, -2, "input");
        c.lua_pushinteger(state, entries[i].exit_code);
        c.lua_setfield(state, -2, "exit_code");
        c.lua_pushinteger(state, entries[i].duration_ms);
        c.lua_setfield(state, -2, "duration_ms");
        _ = c.lua_pushlstring(state, entries[i].cwd.ptr, entries[i].cwd.len);
        c.lua_setfield(state, -2, "cwd");
        c.lua_rawseti(state, -2, @intCast(i + 1));
    }
    return 1;
}

/// xyron.history_replay(id) — schedule replay of a history entry
fn apiHistoryReplay(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const hdb = global_hdb orelse { c.lua_pushboolean(state, 0); return 1; };
    const id = c.lua_tointegerx(state, 1, null);

    var str_buf: [256]u8 = undefined;
    const entry = hdb.getById(id, &str_buf) orelse {
        c.lua_pushboolean(state, 0);
        return 1;
    };

    const hist_cmd = @import("builtins/history.zig");
    const n = @min(entry.raw_input.len, hist_cmd.replay_command.len);
    @memcpy(hist_cmd.replay_command[0..n], entry.raw_input[0..n]);
    hist_cmd.replay_len = n;
    hist_cmd.replay_pending = true;
    c.lua_pushboolean(state, 1);
    return 1;
}

/// xyron.alias(name, expansion) — register a shell alias
fn apiAlias(L: ?*c.lua_State) callconv(.c) c_int {
    const state = L orelse return 0;
    const name = c.lua_tolstring(state, 1, null) orelse return 0;
    const expansion = c.lua_tolstring(state, 2, null) orelse return 0;
    aliases.set(std.mem.span(name), std.mem.span(expansion));
    return 0;
}

/// xyron.prompt({segments}) — configure prompt from Lua.
/// Each element is either a string (builtin name or literal) or a function.
/// Builtin names: "cwd", "symbol", "status", "duration", "jobs", "git_branch"
/// xyron.prompt.init({...}) — set up prompt segments (same as old xyron.prompt())
fn apiPromptInit(L: ?*c.lua_State) callconv(.c) c_int {
    const prompt_mod = @import("prompt.zig");
    const state = L orelse return 0;

    if (c.lua_type(state, 1) != c.LUA_TTABLE) return 0;

    var cfg = prompt_mod.PromptConfig{};
    const len = c.lua_rawlen(state, 1);
    var i: usize = 1;

    while (i <= len) : (i += 1) {
        _ = c.lua_rawgeti(state, 1, @intCast(i));
        const t = c.lua_type(state, -1);

        if (t == c.LUA_TSTRING) {
            const s = c.lua_tolstring(state, -1, null);
            if (s) |name| {
                const n = std.mem.span(name);
                if (std.mem.eql(u8, n, "cwd")) { cfg.addBuiltin(.cwd, "\x1b[1;34m"); }
                else if (std.mem.eql(u8, n, "symbol")) { cfg.addBuiltin(.symbol, ""); }
                else if (std.mem.eql(u8, n, "status")) { cfg.addBuiltin(.status, "\x1b[31m"); }
                else if (std.mem.eql(u8, n, "duration")) { cfg.addBuiltin(.duration, "\x1b[33m"); }
                else if (std.mem.eql(u8, n, "jobs")) { cfg.addBuiltin(.jobs, "\x1b[33m"); }
                else if (std.mem.eql(u8, n, "git")) { cfg.addBuiltin(.git_branch, "\x1b[35m"); }
                else if (std.mem.eql(u8, n, "git_branch")) { cfg.addBuiltin(.git_branch, "\x1b[35m"); }
                else if (std.mem.eql(u8, n, "xyron_project")) { cfg.addBuiltin(.xyron_project, ""); }
                else if (std.mem.eql(u8, n, "\n")) { cfg.addNewline(); }
                else if (std.mem.eql(u8, n, "spacer")) { cfg.addBuiltin(.spacer, ""); }
                else {
                    // Check custom widgets
                    if (prompt_mod.findCustomWidget(n)) |ref| {
                        cfg.addLua(ref);
                    } else {
                        cfg.addText(n, ""); // literal text
                    }
                }
            }
        } else if (t == c.LUA_TFUNCTION) {
            const ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX);
            cfg.addLua(ref);
            continue; // ref consumed the value, don't pop
        }

        c.lua_settop(state, -(1) - 1); // pop
    }

    prompt_mod.setConfig(cfg);
    return 0;
}

/// xyron.prompt.register(name, fn(config)) — register a custom widget
fn apiPromptRegister(L: ?*c.lua_State) callconv(.c) c_int {
    const prompt_mod = @import("prompt.zig");
    const state = L orelse return 0;

    if (c.lua_type(state, 1) != c.LUA_TSTRING) return 0;
    if (c.lua_type(state, 2) != c.LUA_TFUNCTION) return 0;

    const name_ptr = c.lua_tolstring(state, 1, null) orelse return 0;
    const name = std.mem.span(name_ptr);
    const ref = c.luaL_ref(state, c.LUA_REGISTRYINDEX); // pops the function

    prompt_mod.registerCustomWidget(name, ref);
    return 0;
}

/// xyron.prompt.configure(name, config_table) — configure a widget
fn apiPromptConfigure(L: ?*c.lua_State) callconv(.c) c_int {
    const prompt_mod = @import("prompt.zig");
    const state = L orelse return 0;

    if (c.lua_type(state, 1) != c.LUA_TSTRING) return 0;
    if (c.lua_type(state, 2) != c.LUA_TTABLE) return 0;

    const name_ptr = c.lua_tolstring(state, 1, null) orelse return 0;
    const name = std.mem.span(name_ptr);

    if (std.mem.eql(u8, name, "git") or std.mem.eql(u8, name, "git_branch")) {
        var cfg = prompt_mod.GitWidgetConfig{};
        readIconField(state, 2, "branch", &cfg.icon_branch, &cfg.icon_branch_len);
        readIconField(state, 2, "staged", &cfg.icon_staged, &cfg.icon_staged_len);
        readIconField(state, 2, "modified", &cfg.icon_modified, &cfg.icon_modified_len);
        readIconField(state, 2, "deleted", &cfg.icon_deleted, &cfg.icon_deleted_len);
        readIconField(state, 2, "untracked", &cfg.icon_untracked, &cfg.icon_untracked_len);
        readIconField(state, 2, "conflicts", &cfg.icon_conflicts, &cfg.icon_conflicts_len);
        readIconField(state, 2, "ahead", &cfg.icon_ahead, &cfg.icon_ahead_len);
        readIconField(state, 2, "behind", &cfg.icon_behind, &cfg.icon_behind_len);
        readIconField(state, 2, "clean", &cfg.icon_clean, &cfg.icon_clean_len);
        readIconField(state, 2, "lines_added", &cfg.icon_lines_added, &cfg.icon_lines_added_len);
        readIconField(state, 2, "lines_removed", &cfg.icon_lines_removed, &cfg.icon_lines_removed_len);
        // Visibility toggles
        readBoolField(state, 2, "show_staged", &cfg.show_staged);
        readBoolField(state, 2, "show_modified", &cfg.show_modified);
        readBoolField(state, 2, "show_deleted", &cfg.show_deleted);
        readBoolField(state, 2, "show_untracked", &cfg.show_untracked);
        readBoolField(state, 2, "show_conflicts", &cfg.show_conflicts);
        readBoolField(state, 2, "show_ahead_behind", &cfg.show_ahead_behind);
        readBoolField(state, 2, "show_loc", &cfg.show_loc);
        readBoolField(state, 2, "show_clean", &cfg.show_clean);
        readBoolField(state, 2, "show_state", &cfg.show_state);
        prompt_mod.setGitWidgetConfig(cfg);
    } else if (std.mem.eql(u8, name, "symbol")) {
        var cfg = prompt_mod.SymbolWidgetConfig{};
        readIconField(state, 2, "icon", &cfg.icon, &cfg.icon_len);
        readIconField(state, 2, "icon_vim", &cfg.icon_vim, &cfg.icon_vim_len);
        prompt_mod.setSymbolWidgetConfig(cfg);
    }

    return 0;
}

fn readIconField(state: *c.lua_State, table_idx: c_int, field: [*:0]const u8, out: []u8, out_len: *usize) void {
    _ = c.lua_getfield(state, table_idx, field);
    if (c.lua_type(state, -1) == c.LUA_TSTRING) {
        var len: usize = 0;
        const ptr = c.lua_tolstring(state, -1, &len);
        if (ptr) |p| {
            const n = @min(len, out.len);
            @memcpy(out[0..n], @as([*]const u8, @ptrCast(p))[0..n]);
            out_len.* = n;
        }
    }
    c.lua_settop(state, -(1) - 1); // pop
}

fn readBoolField(state: *c.lua_State, table_idx: c_int, field: [*:0]const u8, out: *bool) void {
    _ = c.lua_getfield(state, table_idx, field);
    if (c.lua_type(state, -1) == c.LUA_TBOOLEAN) {
        out.* = c.lua_toboolean(state, -1) != 0;
    }
    c.lua_settop(state, -(1) - 1);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn registerFn(L: *c.lua_State, name: [*:0]const u8, func: c.lua_CFunction) void {
    c.lua_pushcclosure(L, func, 0);
    c.lua_setfield(L, -2, name);
}

fn pop(L: *c.lua_State, n: c_int) void {
    c.lua_settop(L, -(n) - 1);
}
