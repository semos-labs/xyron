// sqlite.zig — Thin Zig wrapper around the SQLite3 C API.
//
// Provides a safe interface for opening databases, executing SQL,
// and binding parameters. Keeps all C interop isolated here.

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Db = struct {
    handle: ?*c.sqlite3,

    /// Open a database file. Creates the file if it doesn't exist.
    pub fn open(path: [*:0]const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &handle);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteOpenFailed;
        }
        return .{ .handle = handle };
    }

    /// Close the database.
    pub fn close(self: *Db) void {
        if (self.handle) |h| _ = c.sqlite3_close(h);
        self.handle = null;
    }

    /// Execute a SQL statement that returns no rows.
    pub fn exec(self: *Db, sql: [*:0]const u8) !void {
        const rc = c.sqlite3_exec(self.handle, sql, null, null, null);
        if (rc != c.SQLITE_OK) return error.SqliteExecFailed;
    }

    /// Prepare a SQL statement for parameter binding.
    pub fn prepare(self: *Db, sql: [*:0]const u8) !Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return error.SqlitePrepareFailed;
        return .{ .handle = stmt.? };
    }

    /// Get the last inserted row id.
    pub fn lastInsertRowid(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn deinit(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    /// Bind a text value to a parameter (1-indexed).
    /// Uses SQLITE_STATIC — caller must ensure data outlives the step() call.
    pub fn bindText(self: *Stmt, idx: c_int, text: []const u8) void {
        _ = c.sqlite3_bind_text(self.handle, idx, text.ptr, @intCast(text.len), null);
    }

    /// Bind an integer value to a parameter (1-indexed).
    pub fn bindInt(self: *Stmt, idx: c_int, val: i64) void {
        _ = c.sqlite3_bind_int64(self.handle, idx, val);
    }

    /// Step the statement. Returns true if a row is available.
    pub fn step(self: *Stmt) !bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return error.SqliteStepFailed;
    }

    /// Reset the statement for re-use.
    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.handle);
    }

    /// Get a text column value (0-indexed).
    pub fn columnText(self: *Stmt, idx: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.handle, idx);
        if (ptr == null) return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, idx));
        return ptr[0..len];
    }

    /// Get an integer column value (0-indexed).
    pub fn columnInt(self: *Stmt, idx: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, idx);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "open and close in-memory database" {
    var db = try Db.open(":memory:");
    defer db.close();
}

test "exec creates table" {
    var db = try Db.open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, val TEXT)");
}

test "prepare and step" {
    var db = try Db.open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, val TEXT)");
    try db.exec("INSERT INTO test (val) VALUES ('hello')");

    var stmt = try db.prepare("SELECT val FROM test");
    defer stmt.deinit();

    const has_row = try stmt.step();
    try std.testing.expect(has_row);

    const val = stmt.columnText(0);
    try std.testing.expectEqualStrings("hello", val.?);
}
