// bookmarks.zig — Named command bookmarks and snippets.
//
// Bookmarks are named shortcuts for commands, stored in the history database.
// Users create them from history or manually, give them a name, and invoke
// them as top-level commands. Snippets are bookmarks with $1/$2/... placeholders
// that accept arguments.
//
// Storage: SQLite table `bookmarks` in the history.db file.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const builtins = @import("builtins/mod.zig");
const lua_commands = @import("lua_commands.zig");
const aliases = @import("aliases.zig");

pub const MAX_BOOKMARKS = 256;
const MAX_NAME = 64;
const MAX_CMD = 1024;
const MAX_DESC = 256;

pub const Bookmark = struct {
    id: i64 = 0,
    name: [MAX_NAME]u8 = undefined,
    name_len: usize = 0,
    command: [MAX_CMD]u8 = undefined,
    command_len: usize = 0,
    description: [MAX_DESC]u8 = undefined,
    desc_len: usize = 0,

    pub fn nameSlice(self: *const Bookmark) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn commandSlice(self: *const Bookmark) []const u8 {
        return self.command[0..self.command_len];
    }

    pub fn descSlice(self: *const Bookmark) []const u8 {
        return self.description[0..self.desc_len];
    }

    /// Check if the command contains snippet placeholders.
    /// Supports: ${1}, ${@}, ${name}
    pub fn isSnippet(self: *const Bookmark) bool {
        const cmd = self.commandSlice();
        var i: usize = 0;
        while (i < cmd.len) : (i += 1) {
            if (cmd[i] == '$' and i + 1 < cmd.len and cmd[i + 1] == '{') {
                if (std.mem.indexOfScalar(u8, cmd[i + 2 ..], '}')) |_| return true;
            }
        }
        return false;
    }

    /// Expand snippet placeholders with the given arguments.
    ///   ${1}..${9}  — positional (1-based)
    ///   ${@}        — all args joined with spaces
    ///   ${name}     — named, filled positionally in order of appearance
    pub fn expand(self: *const Bookmark, args: []const []const u8, out: []u8) []const u8 {
        const cmd = self.commandSlice();
        var pos: usize = 0;
        var i: usize = 0;
        var named_idx: usize = 0; // tracks which positional arg fills the next named placeholder

        while (i < cmd.len and pos < out.len) {
            // Look for ${...}
            if (cmd[i] == '$' and i + 1 < cmd.len and cmd[i + 1] == '{') {
                if (std.mem.indexOfScalar(u8, cmd[i + 2 ..], '}')) |close| {
                    const inner = cmd[i + 2 ..][0..close];
                    i += 3 + close; // skip past ${...}

                    if (std.mem.eql(u8, inner, "@")) {
                        // ${@} = all args
                        for (args, 0..) |arg, ai| {
                            if (ai > 0 and pos < out.len) { out[pos] = ' '; pos += 1; }
                            const n = @min(arg.len, out.len - pos);
                            @memcpy(out[pos..][0..n], arg[0..n]);
                            pos += n;
                        }
                    } else if (inner.len == 1 and inner[0] >= '1' and inner[0] <= '9') {
                        // ${1}..${9} — positional
                        const idx: usize = inner[0] - '1';
                        if (idx < args.len) {
                            const n = @min(args[idx].len, out.len - pos);
                            @memcpy(out[pos..][0..n], args[idx][0..n]);
                            pos += n;
                        }
                    } else {
                        // ${name} — filled positionally in order of appearance
                        if (named_idx < args.len) {
                            const n = @min(args[named_idx].len, out.len - pos);
                            @memcpy(out[pos..][0..n], args[named_idx][0..n]);
                            pos += n;
                            named_idx += 1;
                        }
                    }
                    continue;
                }
            }
            out[pos] = cmd[i];
            pos += 1;
            i += 1;
        }
        return out[0..pos];
    }
};

// ---------------------------------------------------------------------------
// Name validation
// ---------------------------------------------------------------------------

/// Check if a name is a valid bookmark name (letters, numbers, underscore, dash).
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME) return false;
    for (name) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_' or ch == '-')) return false;
    }
    return true;
}

/// Check if a name conflicts with a builtin, alias, or Lua command.
pub fn nameConflicts(name: []const u8) bool {
    if (builtins.isBuiltin(name)) return true;
    if (aliases.get(name) != null) return true;
    if (lua_commands.isLuaCommand(name)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Database operations
// ---------------------------------------------------------------------------

var db_ref: ?*sqlite.Db = null;

pub fn initDb(db: ?*sqlite.Db) void {
    db_ref = db;
    if (db) |d| {
        d.exec(
            "CREATE TABLE IF NOT EXISTS bookmarks (" ++
                "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
                "name TEXT NOT NULL UNIQUE," ++
                "command TEXT NOT NULL," ++
                "description TEXT NOT NULL DEFAULT ''," ++
                "created_at INTEGER NOT NULL" ++
                ")",
        ) catch {};
    }
}

pub fn add(name: []const u8, command: []const u8, description: []const u8) bool {
    const db = db_ref orelse return false;
    var stmt = db.prepare(
        "INSERT OR REPLACE INTO bookmarks (name, command, description, created_at) VALUES (?1, ?2, ?3, ?4)",
    ) catch return false;
    defer stmt.deinit();
    stmt.bindText(1, name);
    stmt.bindText(2, command);
    stmt.bindText(3, description);
    stmt.bindInt(4, std.time.milliTimestamp());
    _ = stmt.step() catch return false;
    return true;
}

pub fn rename(id: i64, new_name: []const u8) bool {
    const db = db_ref orelse return false;
    var stmt = db.prepare("UPDATE bookmarks SET name = ?1 WHERE id = ?2") catch return false;
    defer stmt.deinit();
    stmt.bindText(1, new_name);
    stmt.bindInt(2, id);
    _ = stmt.step() catch return false;
    return true;
}

pub fn remove(name: []const u8) bool {
    const db = db_ref orelse return false;
    var stmt = db.prepare("DELETE FROM bookmarks WHERE name = ?1") catch return false;
    defer stmt.deinit();
    stmt.bindText(1, name);
    _ = stmt.step() catch return false;
    return true;
}

pub fn removeById(id: i64) bool {
    const db = db_ref orelse return false;
    var stmt = db.prepare("DELETE FROM bookmarks WHERE id = ?1") catch return false;
    defer stmt.deinit();
    stmt.bindInt(1, id);
    _ = stmt.step() catch return false;
    return true;
}

pub fn update(id: i64, command: []const u8, description: []const u8) bool {
    const db = db_ref orelse return false;
    var stmt = db.prepare("UPDATE bookmarks SET command = ?1, description = ?2 WHERE id = ?3") catch return false;
    defer stmt.deinit();
    stmt.bindText(1, command);
    stmt.bindText(2, description);
    stmt.bindInt(3, id);
    _ = stmt.step() catch return false;
    return true;
}

/// Find a bookmark by name. Returns null if not found.
pub fn findByName(name: []const u8) ?Bookmark {
    const db = db_ref orelse return null;
    var stmt = db.prepare("SELECT id, name, command, description FROM bookmarks WHERE name = ?1") catch return null;
    defer stmt.deinit();
    stmt.bindText(1, name);
    return readOne(&stmt);
}

/// Load all bookmarks into a buffer. Returns count.
pub fn loadAll(buf: []Bookmark) usize {
    const db = db_ref orelse return 0;
    var stmt = db.prepare("SELECT id, name, command, description FROM bookmarks ORDER BY name") catch return 0;
    defer stmt.deinit();
    return readMany(&stmt, buf);
}

fn readOne(stmt: *sqlite.Stmt) ?Bookmark {
    const has_row = stmt.step() catch return null;
    if (!has_row) return null;
    var b = Bookmark{};
    b.id = stmt.columnInt(0);
    copyField(&b.name, &b.name_len, stmt.columnText(1));
    copyField(&b.command, &b.command_len, stmt.columnText(2));
    copyField(&b.description, &b.desc_len, stmt.columnText(3));
    return b;
}

fn readMany(stmt: *sqlite.Stmt, buf: []Bookmark) usize {
    var count: usize = 0;
    while (count < buf.len) {
        const has_row = stmt.step() catch break;
        if (!has_row) break;
        var b = &buf[count];
        b.* = Bookmark{};
        b.id = stmt.columnInt(0);
        copyField(&b.name, &b.name_len, stmt.columnText(1));
        copyField(&b.command, &b.command_len, stmt.columnText(2));
        copyField(&b.description, &b.desc_len, stmt.columnText(3));
        count += 1;
    }
    return count;
}

fn copyField(dest: []u8, len: *usize, src: ?[]const u8) void {
    const s = src orelse "";
    const n = @min(s.len, dest.len);
    @memcpy(dest[0..n], s[0..n]);
    len.* = n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isValidName" {
    try std.testing.expect(isValidName("deploy"));
    try std.testing.expect(isValidName("my-script"));
    try std.testing.expect(isValidName("build_prod"));
    try std.testing.expect(isValidName("test123"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("has space"));
    try std.testing.expect(!isValidName("has.dot"));
    try std.testing.expect(!isValidName("has/slash"));
}

test "snippet detection" {
    var b = Bookmark{};
    const cmd1 = "git push origin main";
    @memcpy(b.command[0..cmd1.len], cmd1);
    b.command_len = cmd1.len;
    try std.testing.expect(!b.isSnippet());

    const cmd2 = "git push origin ${1}";
    @memcpy(b.command[0..cmd2.len], cmd2);
    b.command_len = cmd2.len;
    try std.testing.expect(b.isSnippet());

    const cmd3 = "deploy ${branch}";
    @memcpy(b.command[0..cmd3.len], cmd3);
    b.command_len = cmd3.len;
    try std.testing.expect(b.isSnippet());
}

test "positional expansion" {
    var b = Bookmark{};
    const cmd = "git push ${1} ${2}";
    @memcpy(b.command[0..cmd.len], cmd);
    b.command_len = cmd.len;

    var out: [256]u8 = undefined;
    const result = b.expand(&.{ "origin", "main" }, &out);
    try std.testing.expectEqualStrings("git push origin main", result);
}

test "named expansion" {
    var b = Bookmark{};
    const cmd = "git push ${remote} ${branch}";
    @memcpy(b.command[0..cmd.len], cmd);
    b.command_len = cmd.len;

    var out: [256]u8 = undefined;
    const result = b.expand(&.{ "origin", "main" }, &out);
    try std.testing.expectEqualStrings("git push origin main", result);
}

test "${@} expansion" {
    var b = Bookmark{};
    const cmd = "echo ${@}";
    @memcpy(b.command[0..cmd.len], cmd);
    b.command_len = cmd.len;

    var out: [256]u8 = undefined;
    const result = b.expand(&.{ "hello", "world" }, &out);
    try std.testing.expectEqualStrings("echo hello world", result);
}

test "mixed positional and named" {
    var b = Bookmark{};
    const cmd = "kubectl logs -f ${service} -n ${1}";
    @memcpy(b.command[0..cmd.len], cmd);
    b.command_len = cmd.len;

    var out: [256]u8 = undefined;
    // ${service} gets arg[0] (named, first appearance), ${1} gets arg[0] (positional)
    const result = b.expand(&.{ "my-pod", "staging" }, &out);
    try std.testing.expectEqualStrings("kubectl logs -f my-pod -n my-pod", result);
}
