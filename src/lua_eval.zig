// lua_eval.zig — Inline Lua evaluation for the shell prompt.
//
// Makes Lua a first-class citizen: users can type Lua code directly at the
// prompt. Supports three modes:
//   1. `=expr` shorthand — evaluate expression, print result
//   2. Pattern detection — unambiguous Lua syntax runs as Lua
//   3. Fallback — on command-not-found, try interpreting as Lua

const std = @import("std");
const lua_api = @import("lua_api.zig");
const c = lua_api.c;
const style = @import("style.zig");

pub const EvalResult = struct {
    success: bool,
    exit_code: u8,
};

/// Check if input starts with `=` (expression shorthand).
/// Returns the expression after `=`, or null if not a `=expr` line.
pub fn expressionShorthand(line: []const u8) ?[]const u8 {
    if (line.len > 1 and line[0] == '=') {
        // `=expr` — skip the `=` and any leading whitespace
        var start: usize = 1;
        while (start < line.len and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
        if (start < line.len) return line[start..];
    }
    return null;
}

/// Detect if a line is unambiguously Lua syntax (not a shell command).
pub fn isLuaCode(line: []const u8) bool {
    // Lua keywords that can't be shell commands
    if (startsWith(line, "local ") or startsWith(line, "local\t")) return true;
    if (startsWith(line, "function ") or startsWith(line, "function\t")) return true;
    if (startsWith(line, "return ") or startsWith(line, "return\t")) return true;
    if (std.mem.eql(u8, line, "return")) return true;
    if (startsWith(line, "repeat")) {
        if (line.len == 6) return true;
        if (line[6] == ' ' or line[6] == '\t' or line[6] == '\n') return true;
    }

    // Lua expressions: lines starting with a number, `(`, `#`, `-<digit>`, `not `
    // No shell command starts with these — safe to treat as Lua
    if (isLuaExpression(line)) return true;

    // Lua assignment: `identifier = value` (not FOO=bar shell syntax)
    // Matches: `x = 5`, `t.x = 5`, `t[k] = 5`
    if (isLuaAssignment(line)) return true;

    // Function calls with `.` or `:` (e.g. `print("hi")`, `xyron.setenv(...)`, `t:method()`)
    if (isLuaFunctionCall(line)) return true;

    return false;
}

/// Evaluate a Lua expression and print the result.
/// Used for `=expr` shorthand.
pub fn evalExpression(L: lua_api.LuaState, expr: []const u8) EvalResult {
    const state = L orelse return .{ .success = false, .exit_code = 1 };

    // Try `return <expr>` to get a printable result
    var buf: [4096]u8 = undefined;
    const code = std.fmt.bufPrintZ(&buf, "return {s}", .{expr}) catch
        return .{ .success = false, .exit_code = 1 };

    if (c.luaL_loadstring(state, code) != 0) {
        reportLuaError(state);
        return .{ .success = false, .exit_code = 1 };
    }

    if (lua_api.pcall(state, 0, 1) != 0) {
        reportLuaError(state);
        return .{ .success = false, .exit_code = 1 };
    }

    // Print result if non-nil
    printStackValue(state);
    c.lua_settop(state, 0);
    return .{ .success = true, .exit_code = 0 };
}

/// Execute a line as Lua code (statement or expression).
/// If the line looks like an expression (no side effects keyword), tries
/// `return <line>` first to print the result, falling back to plain execution.
pub fn evalCode(L: lua_api.LuaState, code: []const u8) EvalResult {
    const state = L orelse return .{ .success = false, .exit_code = 1 };

    var buf: [4096]u8 = undefined;
    const code_z = std.fmt.bufPrintZ(&buf, "{s}", .{code}) catch
        return .{ .success = false, .exit_code = 1 };

    // First try as `return <code>` to auto-print expression results
    var ret_buf: [4096]u8 = undefined;
    const ret_code = std.fmt.bufPrintZ(&ret_buf, "return {s}", .{code}) catch null;

    if (ret_code) |rc| {
        if (c.luaL_loadstring(state, rc) == 0) {
            if (lua_api.pcall(state, 0, 1) == 0) {
                printStackValue(state);
                c.lua_settop(state, 0);
                return .{ .success = true, .exit_code = 0 };
            }
            // pcall failed, fall through to statement execution
        } else {
            // Couldn't parse as expression, pop error and try as statement
            pop(state, 1);
        }
    }

    // Execute as statement
    if (c.luaL_loadstring(state, code_z) != 0) {
        reportLuaError(state);
        return .{ .success = false, .exit_code = 1 };
    }

    if (lua_api.pcall(state, 0, 0) != 0) {
        reportLuaError(state);
        return .{ .success = false, .exit_code = 1 };
    }

    return .{ .success = true, .exit_code = 0 };
}

/// Try to execute a line as Lua. Returns null if it doesn't compile as Lua
/// (meaning it's probably not Lua code). Used as a fallback after command-not-found.
pub fn tryAsLua(L: lua_api.LuaState, code: []const u8) ?EvalResult {
    const state = L orelse return null;

    var buf: [4096]u8 = undefined;
    const code_z = std.fmt.bufPrintZ(&buf, "{s}", .{code}) catch return null;

    // Try as `return <expr>` first
    var ret_buf: [4096]u8 = undefined;
    const ret_code = std.fmt.bufPrintZ(&ret_buf, "return {s}", .{code}) catch null;

    if (ret_code) |rc| {
        if (c.luaL_loadstring(state, rc) == 0) {
            if (lua_api.pcall(state, 0, 1) == 0) {
                printStackValue(state);
                c.lua_settop(state, 0);
                return .{ .success = true, .exit_code = 0 };
            }
        } else {
            pop(state, 1);
        }
    }

    // Try as statement
    if (c.luaL_loadstring(state, code_z) != 0) {
        // Doesn't compile as Lua — not Lua code
        pop(state, 1);
        return null;
    }

    if (lua_api.pcall(state, 0, 0) != 0) {
        // Compiles but runtime error — it IS Lua, just broken
        reportLuaError(state);
        return .{ .success = false, .exit_code = 1 };
    }

    return .{ .success = true, .exit_code = 0 };
}

/// Check if a line compiles as valid Lua (expression or statement).
/// Uses luaL_loadstring to let the Lua parser decide.
pub fn compilesAsLua(L: lua_api.LuaState, code: []const u8) bool {
    const state = L orelse return false;
    var buf: [4096]u8 = undefined;

    // Try as `return <code>` (expression)
    const ret_code = std.fmt.bufPrintZ(&buf, "return {s}", .{code}) catch null;
    if (ret_code) |rc| {
        if (c.luaL_loadstring(state, rc) == 0) {
            pop(state, 1);
            return true;
        }
        pop(state, 1);
    }

    // Try as statement
    const code_z = std.fmt.bufPrintZ(&buf, "{s}", .{code}) catch return false;
    if (c.luaL_loadstring(state, code_z) == 0) {
        pop(state, 1);
        return true;
    }
    pop(state, 1);
    return false;
}

// ---------------------------------------------------------------------------
// Detection helpers
// ---------------------------------------------------------------------------

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, haystack, prefix);
}

/// Detect Lua expressions: math, parenthesized, length operator, negation, `not`.
/// These can't be shell commands — no command name starts with a digit, `(`, or `#`.
fn isLuaExpression(line: []const u8) bool {
    if (line.len == 0) return false;
    const first = line[0];

    // Starts with digit: `2 + 2`, `0xff`, `3.14 * r`
    if (first >= '0' and first <= '9') return true;

    // Starts with `.` followed by digit: `.5 + 1`
    if (first == '.' and line.len > 1 and line[1] >= '0' and line[1] <= '9') return true;

    // Parenthesized expression: `(2 + 3) * 4`
    if (first == '(') return true;

    // Lua length operator: `#t`, `#"hello"`
    if (first == '#') return true;

    // Negative number: `-5`, `-3.14 * 2`
    if (first == '-' and line.len > 1 and (line[1] >= '0' and line[1] <= '9' or line[1] == '.')) return true;

    // `not` unary operator: `not true`, `not x`
    if (startsWith(line, "not ") or startsWith(line, "not\t")) return true;

    // `true`, `false`, `nil` literals
    if (std.mem.eql(u8, line, "true") or std.mem.eql(u8, line, "false") or std.mem.eql(u8, line, "nil")) return true;

    // String literals: `"hello"`, `'world'`
    if (first == '"' or first == '\'') return true;

    // Table constructor: `{1, 2, 3}`
    if (first == '{') return true;

    return false;
}

/// Detect Lua assignment patterns like `x = 5`, `t.x = 5`, `t[k] = 5`.
/// Excludes shell-style `FOO=bar` (no space around `=`) and `==` (comparison).
fn isLuaAssignment(line: []const u8) bool {
    // Look for ` = ` (space-equals-space) which is Lua assignment style
    // Shell doesn't use `x = value` syntax (it's `export X=value` or `X=value`)
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '=' and i > 0 and line[i - 1] == ' ') {
            // Check it's not `==`
            if (i + 1 < line.len and line[i + 1] == '=') continue;
            // Make sure the left side is a valid Lua lvalue (starts with a letter/underscore)
            const left = std.mem.trimRight(u8, line[0 .. i - 1], " \t");
            if (left.len > 0 and isIdentStart(left[0])) return true;
        }
        // Skip quoted strings
        if (line[i] == '"' or line[i] == '\'') {
            const quote = line[i];
            i += 1;
            while (i < line.len and line[i] != quote) : (i += 1) {
                if (line[i] == '\\') i += 1;
            }
        }
    }
    return false;
}

/// Detect Lua-style function calls: `name.path(...)` or `name:method(...)` or `name(...)`.
/// Only matches calls where the function name contains `.` or `:`, or is a known Lua
/// global like `print`, `type`, `tostring`, `tonumber`, `error`, `require`, `pairs`, `ipairs`.
fn isLuaFunctionCall(line: []const u8) bool {
    // Find the opening paren
    const paren = std.mem.indexOfScalar(u8, line, '(') orelse return false;
    if (paren == 0) return false;

    const before = std.mem.trimRight(u8, line[0..paren], " \t");
    if (before.len == 0) return false;

    // Check for `.` or `:` in the function name (e.g. `xyron.cwd()`, `t:method()`)
    if (std.mem.indexOfScalar(u8, before, '.') != null or
        std.mem.indexOfScalar(u8, before, ':') != null)
        return true;

    // Check for known Lua globals
    const lua_globals = [_][]const u8{
        "print",     "type",      "tostring",  "tonumber",
        "error",     "require",   "pairs",     "ipairs",
        "select",    "pcall",     "xpcall",    "assert",
        "rawget",    "rawset",    "rawlen",    "rawequal",
        "setmetatable", "getmetatable",
        "next",      "unpack",    "dofile",    "loadfile",
        "load",      "collectgarbage",
    };
    for (&lua_globals) |g| {
        if (std.mem.eql(u8, before, g)) return true;
    }

    return false;
}

fn isIdentStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

/// Print the value on top of the Lua stack (if non-nil).
fn printStackValue(L: *c.lua_State) void {
    const lua_type = c.lua_type(L, -1);
    if (lua_type == c.LUA_TNIL) return;

    const stdout = std.fs.File.stdout();

    switch (lua_type) {
        c.LUA_TBOOLEAN => {
            const val = c.lua_toboolean(L, -1);
            stdout.writeAll(if (val != 0) "true\n" else "false\n") catch {};
        },
        c.LUA_TNUMBER => {
            // Use tostring for proper formatting
            _ = c.lua_tolstring(L, -1, null);
            const s = c.lua_tolstring(L, -1, null);
            if (s) |str| {
                stdout.writeAll(std.mem.span(str)) catch {};
                stdout.writeAll("\n") catch {};
            }
        },
        c.LUA_TSTRING => {
            var len: usize = 0;
            const s = c.lua_tolstring(L, -1, &len);
            if (s) |str| {
                stdout.writeAll(str[0..len]) catch {};
                stdout.writeAll("\n") catch {};
            }
        },
        c.LUA_TTABLE => {
            // Use tostring() for tables (calls __tostring metamethod if available)
            printViaTostring(L);
        },
        else => {
            printViaTostring(L);
        },
    }
}

/// Call tostring() on the value at the top of the stack and print it.
fn printViaTostring(L: *c.lua_State) void {
    _ = c.lua_getglobal(L, "tostring");
    c.lua_pushvalue(L, -2); // copy the value
    if (lua_api.pcall(L, 1, 1) == 0) {
        const s = c.lua_tolstring(L, -1, null);
        if (s) |str| {
            const stdout = std.fs.File.stdout();
            stdout.writeAll(std.mem.span(str)) catch {};
            stdout.writeAll("\n") catch {};
        }
        pop(L, 1);
    } else {
        pop(L, 1);
    }
}

fn reportLuaError(L: *c.lua_State) void {
    const msg = c.lua_tolstring(L, -1, null);
    if (msg) |m| {
        const stderr = std.fs.File.stderr();
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        pos += style.fg(buf[pos..], .red);
        pos += style.bold(buf[pos..]);
        pos += cp(buf[pos..], "lua:");
        pos += style.reset(buf[pos..]);
        pos += cp(buf[pos..], " ");
        const span = std.mem.span(m);
        const len = @min(span.len, buf.len - pos - 1);
        @memcpy(buf[pos..][0..len], span[0..len]);
        pos += len;
        pos += cp(buf[pos..], "\n");
        stderr.writeAll(buf[0..pos]) catch {};
    }
    pop(L, 1);
}

fn cp(dest: []u8, src: []const u8) usize {
    const len = @min(src.len, dest.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}

fn pop(L: *c.lua_State, n: c_int) void {
    c.lua_settop(L, -(n) - 1);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testLuaState() lua_api.LuaState {
    return c.luaL_newstate();
}

fn testCompilesAsLua(code: []const u8) bool {
    const L = testLuaState();
    defer if (L) |s| c.lua_close(s);
    return compilesAsLua(L, code);
}

test "compilesAsLua — valid Lua" {
    const testing = std.testing;
    // Assignments
    try testing.expect(testCompilesAsLua("x = 5"));
    try testing.expect(testCompilesAsLua("t.x = 5"));
    try testing.expect(testCompilesAsLua("t[1] = 5"));
    try testing.expect(testCompilesAsLua("select = 42"));
    // Statements
    try testing.expect(testCompilesAsLua("local x = 5"));
    try testing.expect(testCompilesAsLua("function foo() end"));
    try testing.expect(testCompilesAsLua("for i = 1, 10 do end"));
    try testing.expect(testCompilesAsLua("if true then end"));
    try testing.expect(testCompilesAsLua("return 42"));
    // Expressions (compiled as `return <expr>`)
    try testing.expect(testCompilesAsLua("2 + 2"));
    try testing.expect(testCompilesAsLua("3.14 * 2"));
    try testing.expect(testCompilesAsLua("\"hello\""));
    try testing.expect(testCompilesAsLua("{1, 2, 3}"));
    try testing.expect(testCompilesAsLua("true"));
    try testing.expect(testCompilesAsLua("nil"));
    try testing.expect(testCompilesAsLua("#t"));
    try testing.expect(testCompilesAsLua("not true"));
    // Function calls
    try testing.expect(testCompilesAsLua("print(42)"));
    try testing.expect(testCompilesAsLua("t:method()"));
}

test "compilesAsLua — not valid Lua" {
    const testing = std.testing;
    // Shell commands with pipes
    try testing.expect(!testCompilesAsLua("curl -Ss https://example.com | json | select title | where id = 1"));
    try testing.expect(!testCompilesAsLua("ls -la | grep foo"));
    try testing.expect(!testCompilesAsLua("echo hello | cat"));
    // Shell env prefix
    try testing.expect(!testCompilesAsLua("HELLO=world command_name"));
    try testing.expect(!testCompilesAsLua("FOO=bar BAZ=qux some_cmd"));
    // Shell commands (multi-word without operators don't compile)
    try testing.expect(!testCompilesAsLua("git status"));
    try testing.expect(!testCompilesAsLua("docker run --rm image"));
    // Note: `ls -la` DOES compile as Lua (`ls - la`), so the heuristic
    // gate (isLuaCode) must reject it before compilesAsLua is called.
    // Shell redirects
    try testing.expect(!testCompilesAsLua("echo hello > file.txt"));
    // Assignment followed by shell-like args
    try testing.expect(!testCompilesAsLua("hello = world command_name"));
}

test "compilesAsLua — edge cases" {
    const testing = std.testing;
    // Variable named like a command — should compile as Lua
    try testing.expect(testCompilesAsLua("curl = 5"));
    try testing.expect(testCompilesAsLua("git = {}"));
    try testing.expect(testCompilesAsLua("ls = nil"));
    // Lua function call with command name as callee
    try testing.expect(testCompilesAsLua("select(1, 'a', 'b')"));
    try testing.expect(testCompilesAsLua("type(x)"));
    // Multiword values that look like shell but are valid Lua
    try testing.expect(testCompilesAsLua("x = 5 + 3"));
    try testing.expect(testCompilesAsLua("x = math.max(1, 2)"));
}

/// Combined check: heuristics + compilation, the same logic used in shell.zig.
fn testIsLua(code: []const u8) bool {
    if (!isLuaCode(code)) return false;
    return testCompilesAsLua(code);
}

test "isLua combined — pipe commands stay as shell" {
    const testing = std.testing;
    // The original bug: pipe chains with `= value` were misdetected as Lua
    try testing.expect(!testIsLua("curl -Ss https://example.com/posts | json | select title | where id = 1"));
    try testing.expect(!testIsLua("cat file.txt | grep pattern | sort"));
    try testing.expect(!testIsLua("echo hello | wc -l"));
}

test "isLua combined — env prefix stays as shell" {
    const testing = std.testing;
    try testing.expect(!testIsLua("HELLO=world command_name"));
    try testing.expect(!testIsLua("FOO=bar BAZ=qux some_cmd"));
    try testing.expect(!testIsLua("NODE_ENV=production npm start"));
}

test "isLua combined — valid Lua is detected" {
    const testing = std.testing;
    // Assignments
    try testing.expect(testIsLua("x = 5"));
    try testing.expect(testIsLua("t.x = 5"));
    try testing.expect(testIsLua("x = 5 + 3"));
    // Variables named like commands
    try testing.expect(testIsLua("curl = 5"));
    try testing.expect(testIsLua("git = {}"));
    try testing.expect(testIsLua("select = 42"));
    // Function calls
    try testing.expect(testIsLua("print(42)"));
    try testing.expect(testIsLua("xyron.setenv(\"FOO\", \"bar\")"));
    try testing.expect(testIsLua("select(1, \"a\", \"b\")"));
    // Keywords
    try testing.expect(testIsLua("local x = 5"));
    try testing.expect(testIsLua("return 42"));
    // Expressions
    try testing.expect(testIsLua("2 + 2"));
    try testing.expect(testIsLua("{1, 2, 3}"));
    try testing.expect(testIsLua("true"));
}

test "isLua combined — ambiguous but correct" {
    const testing = std.testing;
    // These pass the heuristic but fail compilation → shell
    try testing.expect(!testIsLua("hello = world command_name"));
    // These pass both → Lua
    try testing.expect(testIsLua("hello = \"world\""));
    try testing.expect(testIsLua("x = math.max(1, 2)"));
}

test "expressionShorthand" {
    const testing = std.testing;
    try testing.expectEqualStrings("2 + 2", expressionShorthand("=2 + 2").?);
    try testing.expectEqualStrings("2 + 2", expressionShorthand("= 2 + 2").?);
    try testing.expectEqual(@as(?[]const u8, null), expressionShorthand("echo hi"));
    try testing.expectEqual(@as(?[]const u8, null), expressionShorthand("="));
}

test "isLuaCode keywords" {
    const testing = std.testing;
    try testing.expect(isLuaCode("local x = 5"));
    try testing.expect(isLuaCode("function foo() end"));
    try testing.expect(isLuaCode("return 42"));
    try testing.expect(isLuaCode("return"));
    try testing.expect(isLuaCode("repeat"));
    try testing.expect(!isLuaCode("echo hello"));
    try testing.expect(!isLuaCode("ls -la"));
}

test "isLuaCode assignments" {
    const testing = std.testing;
    try testing.expect(isLuaCode("x = 5"));
    try testing.expect(isLuaCode("t.x = 5"));
    try testing.expect(!isLuaCode("FOO=bar")); // no space around =
    try testing.expect(!isLuaCode("x == 5")); // comparison, not assignment
}

test "isLuaCode function calls" {
    const testing = std.testing;
    try testing.expect(isLuaCode("print(42)"));
    try testing.expect(isLuaCode("xyron.setenv(\"FOO\", \"bar\")"));
    try testing.expect(isLuaCode("t:method()"));
    try testing.expect(isLuaCode("require(\"foo\")"));
    try testing.expect(!isLuaCode("git status"));
}

test "isLuaCode expressions" {
    const testing = std.testing;
    // Math
    try testing.expect(isLuaCode("2 + 2"));
    try testing.expect(isLuaCode("3.14 * 2"));
    try testing.expect(isLuaCode("0xff"));
    try testing.expect(isLuaCode("100"));
    // Parenthesized
    try testing.expect(isLuaCode("(2 + 3) * 4"));
    // Negative
    try testing.expect(isLuaCode("-5 + 3"));
    try testing.expect(isLuaCode("-.5"));
    // Length operator
    try testing.expect(isLuaCode("#t"));
    // Unary not
    try testing.expect(isLuaCode("not true"));
    // Literals
    try testing.expect(isLuaCode("true"));
    try testing.expect(isLuaCode("false"));
    try testing.expect(isLuaCode("nil"));
    // Strings
    try testing.expect(isLuaCode("\"hello\""));
    // Tables
    try testing.expect(isLuaCode("{1, 2, 3}"));
    // Still not shell
    try testing.expect(!isLuaCode("git status"));
    try testing.expect(!isLuaCode("ls -la"));
}
