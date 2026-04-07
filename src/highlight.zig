// highlight.zig — Semantic syntax highlighting for the interactive editor.
//
// Performs zero-allocation tokenization of the input buffer and writes
// ANSI-colored output. Uses a command existence cache to avoid filesystem
// I/O on every keystroke. The inline tokenizer mirrors token.zig logic
// but writes directly to an output buffer, preserving quote characters.

const std = @import("std");
const builtins = @import("builtins.zig");
const lua_commands = @import("lua_commands.zig");
const lua_api = @import("lua_api.zig");
const lua_eval = @import("lua_eval.zig");
const aliases_mod = @import("aliases.zig");
const path_search = @import("path_search.zig");
const environ_mod = @import("environ.zig");

// ---------------------------------------------------------------------------
// Token classes and styles
// ---------------------------------------------------------------------------

pub const TokenClass = enum {
    builtin_cmd,
    lua_cmd,
    lua_code,
    valid_cmd,
    unknown_cmd,
    flag,
    argument,
    env_assignment,
    pipe,
    redirect,
    ampersand,
    quoted,
    redirect_target,
    default,
};

const RESET = "\x1b[0m";

fn styleFor(class: TokenClass) []const u8 {
    return switch (class) {
        .builtin_cmd => "\x1b[1;36m", // bold cyan
        .lua_cmd => "\x1b[1;35m", // bold magenta
        .lua_code => "\x1b[35m", // magenta
        .valid_cmd => "\x1b[1;32m", // bold green
        .unknown_cmd => "\x1b[4;31m", // underline red
        .flag => "\x1b[36m", // cyan
        .argument => "", // default
        .env_assignment => "\x1b[33m", // yellow
        .pipe => "\x1b[1;33m", // bold yellow
        .redirect => "\x1b[1;33m", // bold yellow
        .ampersand => "\x1b[1;33m", // bold yellow
        .quoted => "\x1b[32m", // green
        .redirect_target => "\x1b[35m", // magenta
        .default => "",
    };
}

// ---------------------------------------------------------------------------
// Command existence cache
// ---------------------------------------------------------------------------

pub const CommandCache = struct {
    map: std.StringHashMapUnmanaged(bool),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) CommandCache {
        return .{
            .map = .{},
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *CommandCache) void {
        self.map.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    /// Check if a command exists. Caches the result.
    pub fn exists(self: *CommandCache, name: []const u8, env: *const environ_mod.Environ) bool {
        // Check cache first
        if (self.map.get(name)) |v| return v;

        // Cache miss — do a PATH lookup
        const found = blk: {
            const result = path_search.findInPath(std.heap.page_allocator, name, env) catch break :blk false;
            if (result) |path| {
                std.heap.page_allocator.free(path);
                break :blk true;
            }
            break :blk false;
        };

        // Store in cache (dupe the key into the arena)
        const key = self.arena.allocator().dupe(u8, name) catch return found;
        self.map.put(self.arena.allocator(), key, found) catch {};
        return found;
    }

    /// Invalidate all entries (e.g., when PATH changes).
    pub fn invalidate(self: *CommandCache) void {
        self.map.clearAndFree(self.arena.allocator());
        _ = self.arena.reset(.retain_capacity);
    }
};

// ---------------------------------------------------------------------------
// Main highlight function — zero allocation on hot path (cache hit)
// ---------------------------------------------------------------------------

/// Tokenize `input` and write ANSI-colored output to `out`. Returns bytes written.
pub fn renderHighlighted(
    out: []u8,
    input: []const u8,
    cache: *CommandCache,
    env: *const environ_mod.Environ,
    lua: ?lua_api.LuaState,
) usize {
    if (input.len == 0) return 0;

    // Lua mode: highlight entire line as Lua code.
    // Heuristics flag candidates, then luaL_loadstring confirms it actually parses as Lua.
    const lua_state: lua_api.LuaState = if (lua) |l| l else null;
    if (lua_eval.expressionShorthand(input) != null or
        (lua_eval.isLuaCode(input) and lua_eval.compilesAsLua(lua_state, input)))
    {
        return renderLuaHighlighted(out, input);
    }

    var pos: usize = 0; // write position in out
    var i: usize = 0; // read position in input
    var cmd_pos = true; // next word is a command
    var after_redirect = false; // next word is a redirect target

    while (i < input.len and pos + 20 < out.len) {
        const ch = input[i];

        // Whitespace — copy verbatim
        if (ch == ' ' or ch == '\t') {
            pos += emit(out[pos..], RESET);
            out[pos] = ch;
            pos += 1;
            i += 1;
            continue;
        }

        // Semicolon — command separator
        if (ch == ';') {
            pos += emitStyled(out[pos..], ";", .pipe);
            i += 1;
            cmd_pos = true;
            after_redirect = false;
            continue;
        }

        // Double ampersand / double pipe — command separators (must come before single | and &)
        if ((ch == '&' or ch == '|') and i + 1 < input.len and input[i + 1] == ch) {
            pos += emitStyled(out[pos..], input[i .. i + 2], .pipe);
            i += 2;
            cmd_pos = true;
            after_redirect = false;
            continue;
        }

        // Pipe
        if (ch == '|') {
            pos += emitStyled(out[pos..], "|", .pipe);
            i += 1;
            cmd_pos = true;
            after_redirect = false;
            continue;
        }

        // Single ampersand (background)
        if (ch == '&') {
            pos += emitStyled(out[pos..], "&", .ampersand);
            i += 1;
            continue;
        }

        // Stderr redirect: 2>
        if (ch == '2' and i + 1 < input.len and input[i + 1] == '>') {
            pos += emitStyled(out[pos..], "2>", .redirect);
            i += 2;
            after_redirect = true;
            cmd_pos = false;
            continue;
        }

        // Stdout/stdin redirect
        if (ch == '>' or ch == '<') {
            pos += emitStyled(out[pos..], input[i .. i + 1], .redirect);
            i += 1;
            after_redirect = true;
            cmd_pos = false;
            continue;
        }

        // Quoted string (preserve quotes in output)
        if (ch == '\'' or ch == '"') {
            const quote = ch;
            const start = i;
            i += 1;
            while (i < input.len and input[i] != quote) : (i += 1) {}
            if (i < input.len) i += 1; // closing quote
            pos += emitStyled(out[pos..], input[start..i], .quoted);
            cmd_pos = false;
            after_redirect = false;
            continue;
        }

        // Word
        const word_start = i;
        while (i < input.len) {
            const c = input[i];
            if (c == ' ' or c == '\t' or c == '|' or c == '>' or c == '<' or c == '&' or c == ';') break;
            i += 1;
        }
        const word = input[word_start..i];
        if (word.len == 0) continue;

        // Classify the word
        const class = classifyWord(word, cmd_pos, after_redirect, cache, env);
        pos += emitStyled(out[pos..], word, class);

        if (cmd_pos and class != .env_assignment) cmd_pos = false;
        after_redirect = false;
    }

    // Final reset
    pos += emit(out[pos..], RESET);
    return pos;
}

/// Classify a word based on its position and content.
fn classifyWord(
    word: []const u8,
    cmd_pos: bool,
    after_redirect: bool,
    cache: *CommandCache,
    env: *const environ_mod.Environ,
) TokenClass {
    if (after_redirect) return .redirect_target;

    // Check for inline env assignment (NAME=value before command)
    if (cmd_pos and isAssignment(word)) return .env_assignment;

    if (cmd_pos) {
        // Command resolution: builtin → lua → PATH → unknown
        if (builtins.isBuiltin(word)) return .builtin_cmd;
        if (aliases_mod.isAlias(word)) return .valid_cmd;
        if (lua_commands.isLuaCommand(word)) return .lua_cmd;
        // Skip PATH lookup for words with / (paths)
        if (std.mem.indexOfScalar(u8, word, '/') != null) return .argument;
        if (cache.exists(word, env)) return .valid_cmd;
        return .unknown_cmd;
    }

    // Argument position
    if (word.len > 0 and word[0] == '-') return .flag;
    return .argument;
}

fn isAssignment(word: []const u8) bool {
    const eq = std.mem.indexOf(u8, word, "=") orelse return false;
    if (eq == 0) return false;
    if (!isVarStart(word[0])) return false;
    for (word[1..eq]) |c| { if (!isVarChar(c)) return false; }
    return true;
}

fn isVarStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isVarChar(c: u8) bool {
    return isVarStart(c) or (c >= '0' and c <= '9');
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

fn emit(dest: []u8, s: []const u8) usize {
    const n = @min(s.len, dest.len);
    @memcpy(dest[0..n], s[0..n]);
    return n;
}

fn emitStyled(dest: []u8, text: []const u8, class: TokenClass) usize {
    var pos: usize = 0;
    const style = styleFor(class);
    if (style.len > 0) pos += emit(dest[pos..], style);
    pos += emit(dest[pos..], text);
    if (style.len > 0) pos += emit(dest[pos..], RESET);
    return pos;
}

// ---------------------------------------------------------------------------
// Lua highlighting
// ---------------------------------------------------------------------------

const LUA_KEYWORDS = [_][]const u8{
    "and",      "break", "do",       "else",   "elseif", "end",
    "false",    "for",   "function", "goto",   "if",     "in",
    "local",    "nil",   "not",      "or",     "repeat", "return",
    "then",     "true",  "until",    "while",
};

fn isLuaKeyword(word: []const u8) bool {
    for (&LUA_KEYWORDS) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// Highlight a line as Lua code with keyword coloring.
fn renderLuaHighlighted(out: []u8, input: []const u8) usize {
    var pos: usize = 0;
    var i: usize = 0;

    // `=` prefix gets special treatment — highlight it as an operator
    if (input.len > 0 and input[0] == '=') {
        pos += emitStyled(out[pos..], "=", .pipe); // yellow bold for the `=`
        i = 1;
    }

    while (i < input.len and pos + 20 < out.len) {
        const ch = input[i];

        // Whitespace
        if (ch == ' ' or ch == '\t') {
            out[pos] = ch;
            pos += 1;
            i += 1;
            continue;
        }

        // Strings
        if (ch == '"' or ch == '\'') {
            const quote = ch;
            const start = i;
            i += 1;
            while (i < input.len and input[i] != quote) : (i += 1) {
                if (input[i] == '\\') i += 1;
            }
            if (i < input.len) i += 1;
            pos += emitStyled(out[pos..], input[start..i], .quoted);
            continue;
        }

        // Long strings: [[ ... ]]
        if (ch == '[' and i + 1 < input.len and input[i + 1] == '[') {
            const start = i;
            i += 2;
            while (i + 1 < input.len) : (i += 1) {
                if (input[i] == ']' and input[i + 1] == ']') {
                    i += 2;
                    break;
                }
            }
            pos += emitStyled(out[pos..], input[start..i], .quoted);
            continue;
        }

        // Comments: --
        if (ch == '-' and i + 1 < input.len and input[i + 1] == '-') {
            // Rest of line is a comment — dim it
            pos += emit(out[pos..], "\x1b[2m");
            const rest = input[i..];
            pos += emit(out[pos..], rest);
            pos += emit(out[pos..], RESET);
            i = input.len;
            continue;
        }

        // Numbers
        if (ch >= '0' and ch <= '9') {
            const start = i;
            while (i < input.len and ((input[i] >= '0' and input[i] <= '9') or
                input[i] == '.' or input[i] == 'x' or input[i] == 'X' or
                (input[i] >= 'a' and input[i] <= 'f') or
                (input[i] >= 'A' and input[i] <= 'F'))) : (i += 1) {}
            pos += emitStyled(out[pos..], input[start..i], .lua_cmd); // magenta for numbers
            continue;
        }

        // Identifiers and keywords
        if (isIdentChar(ch)) {
            const start = i;
            while (i < input.len and isIdentChar(input[i])) : (i += 1) {}
            const word = input[start..i];
            if (isLuaKeyword(word)) {
                pos += emitStyled(out[pos..], word, .lua_code); // magenta for keywords
            } else {
                pos += emit(out[pos..], word);
            }
            continue;
        }

        // Operators and punctuation — default color
        out[pos] = ch;
        pos += 1;
        i += 1;
    }

    pos += emit(out[pos..], RESET);
    return pos;
}

fn isIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or ch == '_';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "classify builtin in command position" {
    var cache = CommandCache.init(std.testing.allocator);
    defer cache.deinit();
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    try std.testing.expectEqual(TokenClass.builtin_cmd, classifyWord("cd", true, false, &cache, &env));
    try std.testing.expectEqual(TokenClass.builtin_cmd, classifyWord("exit", true, false, &cache, &env));
}

test "classify flag and argument" {
    var cache = CommandCache.init(std.testing.allocator);
    defer cache.deinit();
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    try std.testing.expectEqual(TokenClass.flag, classifyWord("-la", false, false, &cache, &env));
    try std.testing.expectEqual(TokenClass.argument, classifyWord("file.txt", false, false, &cache, &env));
}

test "classify env assignment" {
    var cache = CommandCache.init(std.testing.allocator);
    defer cache.deinit();
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    try std.testing.expectEqual(TokenClass.env_assignment, classifyWord("FOO=bar", true, false, &cache, &env));
}

test "classify redirect target" {
    var cache = CommandCache.init(std.testing.allocator);
    defer cache.deinit();
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    try std.testing.expectEqual(TokenClass.redirect_target, classifyWord("file.txt", false, true, &cache, &env));
}

test "command cache caches PATH lookups" {
    var cache = CommandCache.init(std.testing.allocator);
    defer cache.deinit();
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/usr/bin:/bin");
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    // ls should exist
    try std.testing.expect(cache.exists("ls", &env));
    // Second lookup should use cache (same result)
    try std.testing.expect(cache.exists("ls", &env));
    // Nonexistent should be false
    try std.testing.expect(!cache.exists("__xyron_nonexistent__", &env));
}

test "command after && is classified as command" {
    var cache = CommandCache.init(std.testing.allocator);
    defer cache.deinit();
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    // "cd foo && exit" — exit should be highlighted as builtin
    var buf: [512]u8 = undefined;
    const len = renderHighlighted(&buf, "cd foo && exit", &cache, &env, null);
    const result = buf[0..len];
    // After &&, "exit" should get builtin_cmd style (bold cyan \x1b[1;36m)
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1;36m" ++ "exit") != null);
}

test "command after semicolon is classified as command" {
    var cache = CommandCache.init(std.testing.allocator);
    defer cache.deinit();
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    var env = environ_mod.Environ{ .map = env_map, .allocator = std.testing.allocator, .attyx = null };

    var buf: [512]u8 = undefined;
    const len = renderHighlighted(&buf, "cd foo; exit", &cache, &env, null);
    const result = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, result, "\x1b[1;36m" ++ "exit") != null);
}
