// lua_hooks.zig — Hook registration and invocation.
//
// Lua scripts register hooks via xyron.on(event, fn). When the shell
// fires an event, all registered callbacks are invoked with a data table.
// Hook errors are reported to stderr but never crash the shell.

const std = @import("std");
const lua_api = @import("lua_api.zig");
const c = lua_api.c;

const MAX_HOOKS: usize = 64;

const HookEntry = struct {
    event: [32]u8,
    event_len: usize,
    lua_ref: c_int,
};

var hooks: [MAX_HOOKS]HookEntry = undefined;
var hook_count: usize = 0;

/// Register a hook callback for an event name.
pub fn registerHook(event: []const u8, lua_ref: c_int) void {
    if (hook_count >= MAX_HOOKS) return;
    var entry = &hooks[hook_count];
    const len = @min(event.len, 32);
    @memcpy(entry.event[0..len], event[0..len]);
    entry.event_len = len;
    entry.lua_ref = lua_ref;
    hook_count += 1;
}

/// Fire all hooks for a given event with a data-building callback.
pub fn fireHook(L: lua_api.LuaState, event: []const u8, buildData: *const fn (?*c.lua_State) void) void {
    const state = L orelse return;

    for (hooks[0..hook_count]) |*entry| {
        if (!std.mem.eql(u8, entry.event[0..entry.event_len], event)) continue;

        // Push the registered function
        _ = c.lua_rawgeti(state, c.LUA_REGISTRYINDEX, entry.lua_ref);

        // Build the data table argument
        buildData(state);

        // Call with 1 arg, 0 results
        if (lua_api.pcall(state, 1, 0) != 0) {
            // Report error and continue
            const msg = c.lua_tolstring(state, -1, null);
            if (msg) |m| {
                const stderr = std.fs.File.stderr();
                stderr.writeAll("xyron: hook error (") catch {};
                stderr.writeAll(event) catch {};
                stderr.writeAll("): ") catch {};
                stderr.writeAll(std.mem.span(m)) catch {};
                stderr.writeAll("\n") catch {};
            }
            c.lua_settop(state, -(1) - 1); // pop error
        }
    }
}

// ---------------------------------------------------------------------------
// Data builders for each hook type
// ---------------------------------------------------------------------------

/// Shared state for passing data to hook builders.
var cmd_group_id: u64 = 0;
var cmd_raw: []const u8 = "";
var cmd_cwd: []const u8 = "";
var cmd_exit_code: u8 = 0;
var cmd_duration_ms: i64 = 0;
var cmd_timestamp: i64 = 0;
var cwd_old: []const u8 = "";
var cwd_new: []const u8 = "";
var job_id_val: u32 = 0;
var job_old_state: []const u8 = "";
var job_new_state: []const u8 = "";
var job_raw: []const u8 = "";

pub fn fireCommandStart(L: lua_api.LuaState, group_id: u64, raw: []const u8, cwd: []const u8, ts: i64) void {
    cmd_group_id = group_id;
    cmd_raw = raw;
    cmd_cwd = cwd;
    cmd_timestamp = ts;
    fireHook(L, "on_command_start", &buildCommandStartData);
}

fn buildCommandStartData(L: ?*c.lua_State) void {
    const state = L orelse return;
    c.lua_createtable(state, 0, 4);
    pushField(state, "group_id", cmd_group_id);
    pushStrField(state, "raw", cmd_raw);
    pushStrField(state, "cwd", cmd_cwd);
    pushField(state, "timestamp_ms", cmd_timestamp);
}

pub fn fireCommandFinish(L: lua_api.LuaState, group_id: u64, raw: []const u8, cwd: []const u8, exit_code: u8, duration_ms: i64, ts: i64) void {
    cmd_group_id = group_id;
    cmd_raw = raw;
    cmd_cwd = cwd;
    cmd_exit_code = exit_code;
    cmd_duration_ms = duration_ms;
    cmd_timestamp = ts;
    fireHook(L, "on_command_finish", &buildCommandFinishData);
}

fn buildCommandFinishData(L: ?*c.lua_State) void {
    const state = L orelse return;
    c.lua_createtable(state, 0, 6);
    pushField(state, "group_id", cmd_group_id);
    pushStrField(state, "raw", cmd_raw);
    pushStrField(state, "cwd", cmd_cwd);
    pushField(state, "exit_code", @as(i64, cmd_exit_code));
    pushField(state, "duration_ms", cmd_duration_ms);
    pushField(state, "timestamp_ms", cmd_timestamp);
}

pub fn fireCwdChange(L: lua_api.LuaState, old: []const u8, new: []const u8, ts: i64) void {
    cwd_old = old;
    cwd_new = new;
    cmd_timestamp = ts;
    fireHook(L, "on_cwd_change", &buildCwdData);
}

fn buildCwdData(L: ?*c.lua_State) void {
    const state = L orelse return;
    c.lua_createtable(state, 0, 3);
    pushStrField(state, "old_cwd", cwd_old);
    pushStrField(state, "new_cwd", cwd_new);
    pushField(state, "timestamp_ms", cmd_timestamp);
}

pub fn fireJobStateChange(L: lua_api.LuaState, id: u32, group_id: u64, raw: []const u8, old_st: []const u8, new_st: []const u8, ts: i64) void {
    job_id_val = id;
    cmd_group_id = group_id;
    job_raw = raw;
    job_old_state = old_st;
    job_new_state = new_st;
    cmd_timestamp = ts;
    fireHook(L, "on_job_state_change", &buildJobData);
}

fn buildJobData(L: ?*c.lua_State) void {
    const state = L orelse return;
    c.lua_createtable(state, 0, 6);
    pushField(state, "job_id", @as(i64, job_id_val));
    pushField(state, "group_id", cmd_group_id);
    pushStrField(state, "raw", job_raw);
    pushStrField(state, "old_state", job_old_state);
    pushStrField(state, "new_state", job_new_state);
    pushField(state, "timestamp_ms", cmd_timestamp);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn pushField(L: *c.lua_State, name: [*:0]const u8, val: anytype) void {
    c.lua_pushinteger(L, @intCast(val));
    c.lua_setfield(L, -2, name);
}

fn pushStrField(L: *c.lua_State, name: [*:0]const u8, val: []const u8) void {
    _ = c.lua_pushlstring(L, val.ptr, val.len);
    c.lua_setfield(L, -2, name);
}
