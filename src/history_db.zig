// history_db.zig — SQLite-backed command history storage.
//
// Manages the history database: schema creation, command/step insertion,
// and querying recent entries. Falls back gracefully if the database
// cannot be opened.

const std = @import("std");
const sqlite = @import("sqlite.zig");

/// A recorded command entry.
pub const HistoryEntry = struct {
    id: i64,
    raw_input: []const u8,
    cwd: []const u8,
    exit_code: i64,
    duration_ms: i64,
    started_at: i64,
};

pub const HistoryDb = struct {
    db: ?sqlite.Db,
    session_id: []const u8,
    allocator: std.mem.Allocator,

    /// Open or create the history database.
    pub fn init(allocator: std.mem.Allocator, session_id: []const u8) HistoryDb {
        const db = openDb(allocator) catch null;
        if (db) |*d| {
            var mutable = d.*;
            initSchema(&mutable);
        }
        return .{ .db = db, .session_id = session_id, .allocator = allocator };
    }

    pub fn deinit(self: *HistoryDb) void {
        if (self.db) |*d| d.close();
    }

    /// Record a completed command group.
    pub fn recordCommand(
        self: *HistoryDb,
        raw_input: []const u8,
        cwd: []const u8,
        exit_code: u8,
        duration_ms: i64,
        started_at: i64,
        interrupted: bool,
        steps: []const StepInfo,
    ) ?i64 {
        var db = &(self.db orelse return null);

        var stmt = db.prepare(
            "INSERT INTO commands (raw_input, cwd, started_at, finished_at, duration_ms, exit_code, interrupted, session_id)" ++
                " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        ) catch return null;
        defer stmt.deinit();

        stmt.bindText(1, raw_input);
        stmt.bindText(2, cwd);
        stmt.bindInt(3, started_at);
        stmt.bindInt(4, started_at + duration_ms);
        stmt.bindInt(5, duration_ms);
        stmt.bindInt(6, @intCast(exit_code));
        stmt.bindInt(7, if (interrupted) 1 else 0);
        stmt.bindText(8, self.session_id);

        _ = stmt.step() catch return null;
        const cmd_id = db.lastInsertRowid();

        // Insert steps
        for (steps, 0..) |step, i| {
            self.recordStep(cmd_id, i, step);
        }

        return cmd_id;
    }

    fn recordStep(self: *HistoryDb, cmd_id: i64, idx: usize, step: StepInfo) void {
        var db = &(self.db orelse return);
        var stmt = db.prepare(
            "INSERT INTO command_steps (command_id, step_index, argv, exit_code, duration_ms)" ++
                " VALUES (?1, ?2, ?3, ?4, ?5)",
        ) catch return;
        defer stmt.deinit();

        stmt.bindInt(1, cmd_id);
        stmt.bindInt(2, @intCast(idx));
        stmt.bindText(3, step.argv_text);
        stmt.bindInt(4, @intCast(step.exit_code));
        stmt.bindInt(5, step.duration_ms);

        _ = stmt.step() catch {};
    }

    /// Query recent history entries.
    pub fn recentEntries(self: *HistoryDb, buf: []HistoryEntry, str_buf: []u8) usize {
        var db = &(self.db orelse return 0);
        var stmt = db.prepare(
            "SELECT id, raw_input, cwd, exit_code, duration_ms, started_at" ++
                " FROM commands ORDER BY id DESC LIMIT ?1",
        ) catch return 0;
        defer stmt.deinit();

        stmt.bindInt(1, @intCast(buf.len));
        var count: usize = 0;
        var str_pos: usize = 0;

        while (count < buf.len) {
            const has_row = stmt.step() catch break;
            if (!has_row) break;

            const raw = stmt.columnText(1) orelse "";
            const cwd = stmt.columnText(2) orelse "";

            // Copy strings into str_buf
            const raw_start = str_pos;
            const raw_len = @min(raw.len, str_buf.len - str_pos);
            if (raw_len > 0) @memcpy(str_buf[str_pos..][0..raw_len], raw[0..raw_len]);
            str_pos += raw_len;

            const cwd_start = str_pos;
            const cwd_len = @min(cwd.len, str_buf.len - str_pos);
            if (cwd_len > 0) @memcpy(str_buf[str_pos..][0..cwd_len], cwd[0..cwd_len]);
            str_pos += cwd_len;

            buf[count] = .{
                .id = stmt.columnInt(0),
                .raw_input = str_buf[raw_start..][0..raw_len],
                .cwd = str_buf[cwd_start..][0..cwd_len],
                .exit_code = stmt.columnInt(3),
                .duration_ms = stmt.columnInt(4),
                .started_at = stmt.columnInt(5),
            };
            count += 1;
        }
        return count;
    }

    // ------------------------------------------------------------------
    // Structured queries
    // ------------------------------------------------------------------

    /// Query with filters. Returns entries newest-first.
    pub fn query(self: *HistoryDb, q: *const HistoryQuery, buf: []HistoryEntry, str_buf: []u8) usize {
        var db = &(self.db orelse return 0);

        // Build SQL dynamically based on filters
        var sql_buf: [1024]u8 = undefined;
        var pos: usize = 0;
        pos += cp(sql_buf[pos..], "SELECT id, raw_input, cwd, exit_code, duration_ms, started_at FROM commands WHERE 1=1");

        if (q.text_contains.len > 0)
            pos += cp(sql_buf[pos..], " AND raw_input LIKE ?1");
        if (q.cwd_filter.len > 0)
            pos += cp(sql_buf[pos..], " AND cwd = ?2");
        if (q.only_failed)
            pos += cp(sql_buf[pos..], " AND exit_code != 0");
        if (q.only_success)
            pos += cp(sql_buf[pos..], " AND exit_code = 0");
        if (q.only_interrupted)
            pos += cp(sql_buf[pos..], " AND interrupted = 1");
        if (q.since_ms > 0)
            pos += cp(sql_buf[pos..], " AND started_at >= ?3");
        if (q.min_duration_ms > 0)
            pos += cp(sql_buf[pos..], " AND duration_ms >= ?4");

        pos += cp(sql_buf[pos..], " ORDER BY id DESC LIMIT ?5");
        sql_buf[pos] = 0;

        var stmt = db.prepare(@ptrCast(sql_buf[0..pos :0])) catch return 0;
        defer stmt.deinit();

        // Bind parameters
        if (q.text_contains.len > 0) {
            var pat_buf: [258]u8 = undefined;
            pat_buf[0] = '%';
            const pl = @min(q.text_contains.len, 256);
            @memcpy(pat_buf[1..][0..pl], q.text_contains[0..pl]);
            pat_buf[pl + 1] = '%';
            stmt.bindText(1, pat_buf[0 .. pl + 2]);
        }
        if (q.cwd_filter.len > 0) stmt.bindText(2, q.cwd_filter);
        if (q.since_ms > 0) stmt.bindInt(3, q.since_ms);
        if (q.min_duration_ms > 0) stmt.bindInt(4, q.min_duration_ms);
        stmt.bindInt(5, @intCast(q.limit));

        return self.readEntries(&stmt, buf, str_buf);
    }

    /// Get a single entry by ID.
    pub fn getById(self: *HistoryDb, id: i64, str_buf: []u8) ?HistoryEntry {
        var db = &(self.db orelse return null);
        var stmt = db.prepare(
            "SELECT id, raw_input, cwd, exit_code, duration_ms, started_at FROM commands WHERE id = ?1",
        ) catch return null;
        defer stmt.deinit();
        stmt.bindInt(1, id);

        var entries: [1]HistoryEntry = undefined;
        const count = self.readEntries(&stmt, &entries, str_buf);
        if (count == 0) return null;
        return entries[0];
    }

    /// Find the best ghost text suggestion — most recent successful command
    /// that starts with the given prefix. Searches the full database.
    /// Returns the result into the caller's buffer.
    pub fn findGhost(self: *HistoryDb, prefix: []const u8, out: []u8) ?[]const u8 {
        if (prefix.len == 0) return null;
        var db = &(self.db orelse return null);

        var stmt = db.prepare(
            "SELECT raw_input FROM commands" ++
                " WHERE raw_input LIKE ?1 AND exit_code = 0 AND length(raw_input) > ?2" ++
                " ORDER BY id DESC LIMIT 1",
        ) catch return null;
        defer stmt.deinit();

        // Build prefix pattern: "typed_text%"
        var pat_buf: [512]u8 = undefined;
        const pl = @min(prefix.len, pat_buf.len - 1);
        @memcpy(pat_buf[0..pl], prefix[0..pl]);
        pat_buf[pl] = '%';
        stmt.bindText(1, pat_buf[0 .. pl + 1]);
        stmt.bindInt(2, @intCast(prefix.len));

        const has_row = stmt.step() catch return null;
        if (!has_row) return null;

        const raw = stmt.columnText(0) orelse return null;
        if (raw.len == 0 or raw.len > out.len) return null;
        @memcpy(out[0..raw.len], raw[0..raw.len]);
        return out[0..raw.len];
    }

    fn readEntries(self: *HistoryDb, stmt: *sqlite.Stmt, buf: []HistoryEntry, str_buf: []u8) usize {
        _ = self;
        var count: usize = 0;
        var str_pos: usize = 0;

        while (count < buf.len) {
            const has_row = stmt.step() catch break;
            if (!has_row) break;

            const raw = stmt.columnText(1) orelse "";
            const cwd_text = stmt.columnText(2) orelse "";

            const raw_start = str_pos;
            const raw_len = @min(raw.len, str_buf.len - str_pos);
            if (raw_len > 0) @memcpy(str_buf[str_pos..][0..raw_len], raw[0..raw_len]);
            str_pos += raw_len;

            const cwd_start = str_pos;
            const cwd_len = @min(cwd_text.len, str_buf.len - str_pos);
            if (cwd_len > 0) @memcpy(str_buf[str_pos..][0..cwd_len], cwd_text[0..cwd_len]);
            str_pos += cwd_len;

            buf[count] = .{
                .id = stmt.columnInt(0),
                .raw_input = str_buf[raw_start..][0..raw_len],
                .cwd = str_buf[cwd_start..][0..cwd_len],
                .exit_code = stmt.columnInt(3),
                .duration_ms = stmt.columnInt(4),
                .started_at = stmt.columnInt(5),
            };
            count += 1;
        }
        return count;
    }

    /// Count total entries.
    pub fn totalEntries(self: *HistoryDb) i64 {
        var db = &(self.db orelse return 0);
        var stmt = db.prepare("SELECT COUNT(*) FROM commands") catch return 0;
        defer stmt.deinit();
        _ = stmt.step() catch return 0;
        return stmt.columnInt(0);
    }
};

pub const HistoryQuery = struct {
    text_contains: []const u8 = "",
    cwd_filter: []const u8 = "",
    only_failed: bool = false,
    only_success: bool = false,
    only_interrupted: bool = false,
    since_ms: i64 = 0,
    min_duration_ms: i64 = 0,
    limit: usize = 25,
};

pub const StepInfo = struct {
    argv_text: []const u8,
    exit_code: u8,
    duration_ms: i64,
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

fn openDb(allocator: std.mem.Allocator) !sqlite.Db {
    _ = allocator;

    // XDG_DATA_HOME/xyron/ or ~/.local/share/xyron/
    const data_home = std.posix.getenv("XDG_DATA_HOME");
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;

    const dir_path = if (data_home) |xdg|
        std.fmt.bufPrintZ(&dir_buf, "{s}/xyron", .{xdg}) catch return error.PathTooLong
    else blk: {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        // Ensure intermediate dirs exist
        var tmp: [std.fs.max_path_bytes]u8 = undefined;
        const share = std.fmt.bufPrintZ(&tmp, "{s}/.local/share", .{home}) catch return error.PathTooLong;
        std.fs.makeDirAbsolute(share) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return error.MkdirFailed,
        };
        break :blk std.fmt.bufPrintZ(&dir_buf, "{s}/.local/share/xyron", .{home}) catch return error.PathTooLong;
    };

    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.MkdirFailed,
    };

    var db_buf: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&db_buf, "{s}/history.db", .{dir_path}) catch return error.PathTooLong;
    return sqlite.Db.open(db_path);
}

fn initSchema(db: *sqlite.Db) void {
    db.exec(
        "CREATE TABLE IF NOT EXISTS commands (" ++
            "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
            "raw_input TEXT NOT NULL," ++
            "cwd TEXT NOT NULL," ++
            "started_at INTEGER NOT NULL," ++
            "finished_at INTEGER NOT NULL," ++
            "duration_ms INTEGER NOT NULL," ++
            "exit_code INTEGER NOT NULL," ++
            "interrupted INTEGER NOT NULL DEFAULT 0," ++
            "session_id TEXT NOT NULL" ++
            ")",
    ) catch return;

    db.exec(
        "CREATE TABLE IF NOT EXISTS command_steps (" ++
            "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
            "command_id INTEGER NOT NULL REFERENCES commands(id)," ++
            "step_index INTEGER NOT NULL," ++
            "argv TEXT NOT NULL," ++
            "exit_code INTEGER NOT NULL," ++
            "duration_ms INTEGER NOT NULL" ++
            ")",
    ) catch return;

    db.exec("CREATE INDEX IF NOT EXISTS idx_commands_started_at ON commands(started_at)") catch {};
    db.exec("CREATE INDEX IF NOT EXISTS idx_commands_cwd ON commands(cwd)") catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "init and record command" {
    // Use in-memory DB for testing
    var db = try sqlite.Db.open(":memory:");
    initSchema(&db);

    var hdb = HistoryDb{ .db = db, .session_id = "test-session", .allocator = std.testing.allocator };
    defer hdb.deinit();

    const steps = [_]StepInfo{.{ .argv_text = "ls -la", .exit_code = 0, .duration_ms = 10 }};
    const cmd_id = hdb.recordCommand("ls -la", "/tmp", 0, 10, 1000, false, &steps);
    try std.testing.expect(cmd_id != null);
    try std.testing.expectEqual(@as(i64, 1), cmd_id.?);
}

test "query recent entries" {
    var db = try sqlite.Db.open(":memory:");
    initSchema(&db);

    var hdb = HistoryDb{ .db = db, .session_id = "test", .allocator = std.testing.allocator };
    defer hdb.deinit();

    _ = hdb.recordCommand("echo hello", "/tmp", 0, 5, 1000, false, &.{});
    _ = hdb.recordCommand("ls -la", "/home", 0, 10, 2000, false, &.{});

    var entries: [10]HistoryEntry = undefined;
    var str_buf: [4096]u8 = undefined;
    const count = hdb.recentEntries(&entries, &str_buf);

    try std.testing.expectEqual(@as(usize, 2), count);
    // Most recent first
    try std.testing.expectEqualStrings("ls -la", entries[0].raw_input);
    try std.testing.expectEqualStrings("echo hello", entries[1].raw_input);
}
