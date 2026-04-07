// lua_completions.zig — User-defined Lua completion providers.
//
// Users register providers via xyron.complete(cmd_name, fn). When tab
// completion runs for that command, the Lua function is called with a
// context table and should return an array of completions.

const std = @import("std");
const lua_api = @import("lua_api.zig");
const complete = @import("complete.zig");
const c = lua_api.c;

const MAX_PROVIDERS: usize = 64;
const MAX_NAME: usize = 64;

const ProviderEntry = struct {
    name: [MAX_NAME]u8,
    name_len: usize,
    lua_ref: c_int,
};

var providers: [MAX_PROVIDERS]ProviderEntry = undefined;
var provider_count: usize = 0;

/// Register a Lua completion provider for a command.
pub fn registerProvider(name: []const u8, lua_ref: c_int) void {
    if (provider_count >= MAX_PROVIDERS) return;
    const len = @min(name.len, MAX_NAME);

    // Replace existing provider for same command
    for (providers[0..provider_count]) |*p| {
        if (std.mem.eql(u8, p.name[0..p.name_len], name[0..len])) {
            p.lua_ref = lua_ref;
            return;
        }
    }

    var entry = &providers[provider_count];
    @memcpy(entry.name[0..len], name[0..len]);
    entry.name_len = len;
    entry.lua_ref = lua_ref;
    provider_count += 1;
}

/// Call registered Lua providers for the given command and add results
/// to the candidate buffer.
pub fn provide(
    L: lua_api.LuaState,
    out: *complete.CandidateBuffer,
    ctx: *const complete.CompletionContext,
) void {
    const state = L orelse return;
    if (ctx.cmd_name.len == 0) return;

    // Find provider for this command
    var ref: c_int = 0;
    var found = false;
    for (providers[0..provider_count]) |*p| {
        if (std.mem.eql(u8, p.name[0..p.name_len], ctx.cmd_name)) {
            ref = p.lua_ref;
            found = true;
            break;
        }
    }
    if (!found) return;

    // Push function from registry
    _ = c.lua_rawgeti(state, c.LUA_REGISTRYINDEX, ref);

    // Build context table: { cmd_name, args, prefix, kind }
    c.lua_createtable(state, 0, 4);

    _ = c.lua_pushlstring(state, ctx.cmd_name.ptr, ctx.cmd_name.len);
    c.lua_setfield(state, -2, "cmd_name");

    // args = non-flag arguments after the command
    c.lua_createtable(state, @intCast(ctx.cmd_args_len), 0);
    for (0..ctx.cmd_args_len) |i| {
        const arg = ctx.cmd_args[i];
        _ = c.lua_pushlstring(state, arg.ptr, arg.len);
        c.lua_rawseti(state, -2, @intCast(i + 1));
    }
    c.lua_setfield(state, -2, "args");

    _ = c.lua_pushlstring(state, ctx.prefix.ptr, ctx.prefix.len);
    c.lua_setfield(state, -2, "prefix");

    const kind_str: []const u8 = switch (ctx.kind) {
        .command => "command",
        .argument => "argument",
        .flag => "flag",
        .env_var => "env_var",
        .redirect_target => "redirect_target",
        .none => "none",
    };
    _ = c.lua_pushlstring(state, kind_str.ptr, kind_str.len);
    c.lua_setfield(state, -2, "kind");

    // Call with 1 arg, expect 1 result
    if (lua_api.pcall(state, 1, 1) != 0) {
        // Report error and continue
        const msg = c.lua_tolstring(state, -1, null);
        if (msg) |m| {
            const stderr = std.fs.File.stderr();
            stderr.writeAll("xyron: completion: ") catch {};
            stderr.writeAll(std.mem.span(m)) catch {};
            stderr.writeAll("\n") catch {};
        }
        c.lua_settop(state, -(1) - 1);
        return;
    }

    // Parse result: expect table (array of strings or {text, desc} tables)
    if (c.lua_type(state, -1) != c.LUA_TTABLE) {
        c.lua_settop(state, -(1) - 1);
        return;
    }

    // Iterate array
    const tbl_len = c.lua_rawlen(state, -1);
    var i: usize = 1;
    while (i <= tbl_len) : (i += 1) {
        _ = c.lua_rawgeti(state, -1, @intCast(i));

        if (c.lua_type(state, -1) == c.LUA_TSTRING) {
            // Simple string completion
            const s = c.lua_tolstring(state, -1, null);
            if (s) |text_ptr| {
                const text = std.mem.span(text_ptr);
                out.add(text, .external_cmd);
            }
        } else if (c.lua_type(state, -1) == c.LUA_TTABLE) {
            // {text = "...", desc = "..."}
            _ = c.lua_getfield(state, -1, "text");
            const text_ptr = c.lua_tolstring(state, -1, null);
            c.lua_settop(state, -(1) - 1);

            if (text_ptr) |tp| {
                const text = std.mem.span(tp);
                _ = c.lua_getfield(state, -1, "desc");
                const desc_ptr = c.lua_tolstring(state, -1, null);
                c.lua_settop(state, -(1) - 1);

                const desc = if (desc_ptr) |d| std.mem.span(d) else "";
                out.addWithDesc(text, desc, .external_cmd);
            }
        }

        c.lua_settop(state, -(1) - 1); // pop element
    }

    c.lua_settop(state, -(1) - 1); // pop result table
}
