// lua_commands.zig — Custom Lua-defined shell commands.
//
// Lua scripts register commands via xyron.command(name, fn). When the
// user types that command, the Lua function is called with an args table.
// Resolution order: builtins → lua commands → external commands.

const std = @import("std");
const lua_api = @import("lua_api.zig");
const c = lua_api.c;

const MAX_COMMANDS: usize = 128;
const MAX_NAME: usize = 64;

const CommandEntry = struct {
    name: [MAX_NAME]u8,
    name_len: usize,
    lua_ref: c_int,
};

var commands: [MAX_COMMANDS]CommandEntry = undefined;
var command_count: usize = 0;

/// Register a custom Lua command.
pub fn registerCommand(name: []const u8, lua_ref: c_int) void {
    if (command_count >= MAX_COMMANDS) return;
    const len = @min(name.len, MAX_NAME);

    // Replace existing command with same name
    for (commands[0..command_count]) |*cmd| {
        if (std.mem.eql(u8, cmd.name[0..cmd.name_len], name[0..len])) {
            cmd.lua_ref = lua_ref;
            return;
        }
    }

    var entry = &commands[command_count];
    @memcpy(entry.name[0..len], name[0..len]);
    entry.name_len = len;
    entry.lua_ref = lua_ref;
    command_count += 1;
}

/// Number of registered Lua commands.
pub fn commandCount() usize {
    return command_count;
}

/// Get the name of a Lua command by index.
pub fn commandNameAt(index: usize) []const u8 {
    return commands[index].name[0..commands[index].name_len];
}

/// Check if a command name is a registered Lua command.
pub fn isLuaCommand(name: []const u8) bool {
    for (commands[0..command_count]) |*cmd| {
        if (std.mem.eql(u8, cmd.name[0..cmd.name_len], name)) return true;
    }
    return false;
}

/// Execute a Lua command. Returns exit code (0 = success).
pub fn execute(L: lua_api.LuaState, name: []const u8, argv: []const []const u8) u8 {
    const state = L orelse return 127;

    // Find the command
    var ref: c_int = 0;
    var found = false;
    for (commands[0..command_count]) |*cmd| {
        if (std.mem.eql(u8, cmd.name[0..cmd.name_len], name)) {
            ref = cmd.lua_ref;
            found = true;
            break;
        }
    }
    if (!found) return 127;

    // Push the function from registry
    _ = c.lua_rawgeti(state, c.LUA_REGISTRYINDEX, ref);

    // Build args table (argv[1..], skipping the command name)
    const args = if (argv.len > 1) argv[1..] else &[_][]const u8{};
    c.lua_createtable(state, @intCast(args.len), 0);
    for (args, 0..) |arg, i| {
        _ = c.lua_pushlstring(state, arg.ptr, arg.len);
        c.lua_rawseti(state, -2, @intCast(i + 1));
    }

    // Call with 1 arg (the args table), expect 0-1 results
    if (lua_api.pcall(state, 1, 1) != 0) {
        const msg = c.lua_tolstring(state, -1, null);
        if (msg) |m| {
            const stderr = std.fs.File.stderr();
            stderr.writeAll("xyron: ") catch {};
            stderr.writeAll(name) catch {};
            stderr.writeAll(": ") catch {};
            stderr.writeAll(std.mem.span(m)) catch {};
            stderr.writeAll("\n") catch {};
        }
        c.lua_settop(state, -(1) - 1); // pop error
        return 1;
    }

    // Check return value — number = exit code, nil/true = 0, false = 1
    var exit_code: u8 = 0;
    if (c.lua_type(state, -1) == c.LUA_TNUMBER) {
        const n = c.lua_tointegerx(state, -1, null);
        exit_code = @intCast(@as(u8, @truncate(@as(u64, @bitCast(n)))));
    } else if (c.lua_type(state, -1) == c.LUA_TBOOLEAN) {
        if (c.lua_toboolean(state, -1) == 0) exit_code = 1;
    }
    c.lua_settop(state, -(1) - 1); // pop result
    return exit_code;
}
