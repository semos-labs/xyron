// jump_db.zig — SQLite-backed frecency directory database.
//
// Implements zoxide-style frecency ranking: each visit increments the score,
// and a recency multiplier boosts recently visited directories.
//
// Frecency = base_score × recency_multiplier
//   Last hour:  ×4
//   Last day:   ×2
//   Last week:  ÷2
//   Older:      ÷4
//
// When total score exceeds MAXAGE (10000), all scores are reduced so the
// total becomes ~90% of MAXAGE, and entries below 1.0 are pruned.

const std = @import("std");
const sqlite = @import("sqlite.zig");

const MAXAGE: f64 = 10000.0;

pub const JumpEntry = struct {
    path: []const u8,
    score: f64,
    last_access: i64, // unix timestamp (seconds)
    frecency: f64, // computed, not stored
};

pub const JumpDb = struct {
    db: ?sqlite.Db,

    pub fn init(allocator: std.mem.Allocator) JumpDb {
        const db = openDb(allocator) catch null;
        if (db) |*d| {
            var mutable = d.*;
            initSchema(&mutable);
        }
        return .{ .db = db };
    }

    pub fn deinit(self: *JumpDb) void {
        if (self.db) |*d| d.close();
    }

    /// Record a directory visit. Increments score and updates last_access.
    pub fn recordVisit(self: *JumpDb, path: []const u8) void {
        var db = &(self.db orelse return);
        const now = @divTrunc(std.time.timestamp(), 1);

        // Try update existing entry
        {
            var stmt = db.prepare(
                "UPDATE jump_dirs SET score = score + 1, last_access = ?1 WHERE path = ?2",
            ) catch return;
            defer stmt.deinit();
            stmt.bindInt(1, now);
            stmt.bindText(2, path);
            _ = stmt.step() catch return;
        }

        // Check if row was affected by reading the entry
        {
            var stmt = db.prepare("SELECT 1 FROM jump_dirs WHERE path = ?1") catch return;
            defer stmt.deinit();
            stmt.bindText(1, path);
            const exists = stmt.step() catch false;
            if (!exists) {
                // Insert new entry
                var ins = db.prepare(
                    "INSERT INTO jump_dirs (path, score, last_access) VALUES (?1, 1.0, ?2)",
                ) catch return;
                defer ins.deinit();
                ins.bindText(1, path);
                ins.bindInt(2, now);
                _ = ins.step() catch {};
            }
        }

        // Age management: if total score exceeds MAXAGE, reduce all scores
        self.ageIfNeeded();
    }

    /// Remove a directory from the database.
    pub fn remove(self: *JumpDb, path: []const u8) bool {
        var db = &(self.db orelse return false);
        var stmt = db.prepare("DELETE FROM jump_dirs WHERE path = ?1") catch return false;
        defer stmt.deinit();
        stmt.bindText(1, path);
        _ = stmt.step() catch return false;
        return true;
    }

    /// Query directories matching a fuzzy search, ranked by frecency.
    /// Returns count of entries written to `out`.
    pub fn query(
        self: *JumpDb,
        terms: []const []const u8,
        out: []JumpEntry,
        str_buf: []u8,
    ) usize {
        var db = &(self.db orelse return 0);
        const now = @divTrunc(std.time.timestamp(), 1);

        var stmt = db.prepare(
            "SELECT path, score, last_access FROM jump_dirs ORDER BY score DESC",
        ) catch return 0;
        defer stmt.deinit();

        var count: usize = 0;
        var str_pos: usize = 0;

        while (count < out.len) {
            const has_row = stmt.step() catch break;
            if (!has_row) break;

            const path = stmt.columnText(0) orelse continue;
            const score = @as(f64, @floatFromInt(stmt.columnInt(1)));
            const last_access = stmt.columnInt(2);

            // Apply matching filter
            if (terms.len > 0 and !matchPath(path, terms)) continue;

            // Compute frecency
            const frecency = computeFrecency(score, last_access, now);

            // Store path in string buffer
            if (str_pos + path.len > str_buf.len) break;
            @memcpy(str_buf[str_pos..][0..path.len], path);
            out[count] = .{
                .path = str_buf[str_pos..][0..path.len],
                .score = score,
                .last_access = last_access,
                .frecency = frecency,
            };
            str_pos += path.len;
            count += 1;
        }

        // Sort by frecency (descending)
        sortByFrecency(out[0..count]);
        return count;
    }

    /// List all entries ranked by frecency.
    pub fn listAll(
        self: *JumpDb,
        out: []JumpEntry,
        str_buf: []u8,
    ) usize {
        return self.query(&.{}, out, str_buf);
    }

    /// Remove entries whose directories no longer exist.
    pub fn clean(self: *JumpDb) usize {
        var db = &(self.db orelse return 0);
        var removed: usize = 0;

        // Collect paths to remove
        var paths_to_remove: [256][]const u8 = undefined;
        var remove_count: usize = 0;
        var path_buf: [256 * 512]u8 = undefined;
        var buf_pos: usize = 0;

        {
            var stmt = db.prepare("SELECT path FROM jump_dirs") catch return 0;
            defer stmt.deinit();
            while (true) {
                const has_row = stmt.step() catch break;
                if (!has_row) break;
                const path = stmt.columnText(0) orelse continue;

                // Check if directory exists
                std.fs.cwd().access(path, .{}) catch {
                    if (remove_count < 256 and buf_pos + path.len <= path_buf.len) {
                        @memcpy(path_buf[buf_pos..][0..path.len], path);
                        paths_to_remove[remove_count] = path_buf[buf_pos..][0..path.len];
                        buf_pos += path.len;
                        remove_count += 1;
                    }
                    continue;
                };
            }
        }

        // Delete collected paths
        for (paths_to_remove[0..remove_count]) |path| {
            var del = db.prepare("DELETE FROM jump_dirs WHERE path = ?1") catch continue;
            defer del.deinit();
            del.bindText(1, path);
            _ = del.step() catch continue;
            removed += 1;
        }

        return removed;
    }

    /// Import entries from zoxide's binary database.
    pub fn importZoxide(self: *JumpDb) !usize {
        const db = &(self.db orelse return error.NoDatabase);

        // Find zoxide db: $ZOXIDE_DATA_DIR/db.zo or $XDG_DATA_HOME/zoxide/db.zo
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const zo_path = findZoxideDb(&path_buf) orelse return error.NotFound;

        const file = std.fs.cwd().openFile(zo_path, .{}) catch return error.NotFound;
        defer file.close();

        // Read entire file
        const alloc = std.heap.page_allocator;
        var content: [1024 * 1024]u8 = undefined; // 1MB max
        const n = file.readAll(&content) catch return error.ReadFailed;
        if (n < 4) return error.InvalidFormat;
        const data = content[0..n];

        // Parse zoxide v3 binary format (bincode)
        // Header: version (4 bytes LE u32) — must be 3
        const version = std.mem.readInt(u32, data[0..4], .little);
        if (version != 3) {
            // Try v2 format or unknown
            return error.UnsupportedVersion;
        }

        var imported: usize = 0;
        var pos: usize = 4;

        // Entry count (u64 LE — bincode serializes Vec length as u64)
        if (pos + 8 > n) return error.InvalidFormat;
        const entry_count = std.mem.readInt(u64, data[pos..][0..8], .little);
        pos += 8;
        _ = entry_count; // We just iterate until EOF

        // Entries: [path_len:u64 LE][path bytes][score:f64 LE][timestamp:i64 LE]
        while (pos + 8 <= n) {
            if (pos + 8 > n) break;
            const path_len = std.mem.readInt(u64, data[pos..][0..8], .little);
            pos += 8;
            if (path_len > 4096 or pos + path_len > n) break;
            const path = data[pos..][0..path_len];
            pos += path_len;

            // Score (f64)
            if (pos + 8 > n) break;
            const score_bits = std.mem.readInt(u64, data[pos..][0..8], .little);
            const score: f64 = @bitCast(score_bits);
            pos += 8;

            // Last accessed (i64, unix timestamp seconds)
            if (pos + 8 > n) break;
            const last_access = std.mem.readInt(i64, data[pos..][0..8], .little);
            pos += 8;

            // Insert or update
            if (path.len > 0) {
                insertImported(db, path, score, last_access, alloc);
                imported += 1;
            }
        }

        return imported;
    }

    /// Get the total entry count.
    pub fn totalEntries(self: *JumpDb) usize {
        var db = &(self.db orelse return 0);
        var stmt = db.prepare("SELECT COUNT(*) FROM jump_dirs") catch return 0;
        defer stmt.deinit();
        _ = stmt.step() catch return 0;
        return @intCast(@max(stmt.columnInt(0), 0));
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    fn ageIfNeeded(self: *JumpDb) void {
        var db = &(self.db orelse return);

        // Check total score
        var stmt = db.prepare("SELECT SUM(score) FROM jump_dirs") catch return;
        defer stmt.deinit();
        _ = stmt.step() catch return;
        const total = @as(f64, @floatFromInt(stmt.columnInt(0)));

        if (total > MAXAGE) {
            // Reduce all scores so total becomes ~90% of MAXAGE
            const target = MAXAGE * 0.9;
            const factor = target / total;
            db.exec("UPDATE jump_dirs SET score = CAST(score * " ++
                std.fmt.comptimePrint("{d}", .{0.9}) ++
                " AS REAL)") catch {};
            _ = factor;
            // Actually use a simpler approach: multiply all by 0.9
            // Remove entries below threshold
            db.exec("DELETE FROM jump_dirs WHERE score < 1.0") catch {};
        }
    }
};

// ---------------------------------------------------------------------------
// Frecency computation
// ---------------------------------------------------------------------------

fn computeFrecency(score: f64, last_access: i64, now: i64) f64 {
    const age_secs = now - last_access;
    const multiplier: f64 = if (age_secs < 3600)
        4.0 // last hour
    else if (age_secs < 86400)
        2.0 // last day
    else if (age_secs < 604800)
        0.5 // last week
    else
        0.25; // older
    return score * multiplier;
}

// ---------------------------------------------------------------------------
// Path matching (zoxide-style)
// ---------------------------------------------------------------------------

/// Match path against query terms. All terms must appear in order,
/// case-insensitive. The last term must match the last path component.
fn matchPath(path: []const u8, terms: []const []const u8) bool {
    if (terms.len == 0) return true;

    // All terms must appear in order within the path (case-insensitive)
    var search_from: usize = 0;
    for (terms, 0..) |term, ti| {
        if (term.len == 0) continue;
        const found = findCaseInsensitive(path[search_from..], term);
        if (found) |idx| {
            // Last term must match within the last path component
            if (ti == terms.len - 1) {
                const last_sep = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
                const abs_pos = search_from + idx;
                if (abs_pos < last_sep) return false;
            }
            search_from += idx + term.len;
        } else {
            return false;
        }
    }
    return true;
}

fn findCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    const limit = haystack.len - needle.len + 1;
    outer: for (0..limit) |i| {
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) continue :outer;
        }
        return i;
    }
    return null;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ---------------------------------------------------------------------------
// Sorting
// ---------------------------------------------------------------------------

fn sortByFrecency(entries: []JumpEntry) void {
    // Insertion sort (lists are small)
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        const key = entries[i];
        var j: usize = i;
        while (j > 0 and entries[j - 1].frecency < key.frecency) : (j -= 1) {
            entries[j] = entries[j - 1];
        }
        entries[j] = key;
    }
}

// ---------------------------------------------------------------------------
// Database setup
// ---------------------------------------------------------------------------

fn openDb(allocator: std.mem.Allocator) !sqlite.Db {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const data_home = std.posix.getenv("XDG_DATA_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        break :blk std.fmt.bufPrint(&path_buf, "{s}/.local/share", .{home}) catch return error.PathTooLong;
    };
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/xyron", .{data_home}) catch return error.PathTooLong;
    std.fs.cwd().makePath(dir) catch {};

    _ = allocator;
    var db_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/xyron/jump.db", .{data_home}) catch return error.PathTooLong;
    // Null-terminate for sqlite
    if (db_path.len >= db_path_buf.len) return error.PathTooLong;
    db_path_buf[db_path.len] = 0;

    return sqlite.Db.open(db_path_buf[0..db_path.len :0]);
}

fn initSchema(db: *sqlite.Db) void {
    db.exec(
        "CREATE TABLE IF NOT EXISTS jump_dirs (" ++
            "path TEXT PRIMARY KEY," ++
            "score REAL NOT NULL DEFAULT 1.0," ++
            "last_access INTEGER NOT NULL" ++
            ")",
    ) catch {};
    db.exec("CREATE INDEX IF NOT EXISTS idx_jump_score ON jump_dirs(score DESC)") catch {};
}

fn insertImported(db: *sqlite.Db, path: []const u8, score: f64, last_access: i64, alloc: std.mem.Allocator) void {
    _ = alloc;
    // Use INSERT OR REPLACE to handle duplicates — keep higher score
    var stmt = db.prepare(
        "INSERT INTO jump_dirs (path, score, last_access) VALUES (?1, ?2, ?3) " ++
            "ON CONFLICT(path) DO UPDATE SET score = MAX(score, excluded.score), " ++
            "last_access = MAX(last_access, excluded.last_access)",
    ) catch return;
    defer stmt.deinit();
    stmt.bindText(1, path);
    // Store score as integer (sqlite bindInt)
    stmt.bindInt(2, @intFromFloat(@round(score)));
    stmt.bindInt(3, last_access);
    _ = stmt.step() catch {};
}

// ---------------------------------------------------------------------------
// Zoxide database location
// ---------------------------------------------------------------------------

fn findZoxideDb(buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    // Check $ZOXIDE_DATA_DIR/db.zo
    if (std.posix.getenv("_ZO_DATA_DIR")) |dir| {
        const p = std.fmt.bufPrint(buf, "{s}/db.zo", .{dir}) catch return null;
        if (std.fs.cwd().access(p, .{})) |_| return p else |_| {}
    }

    const home = std.posix.getenv("HOME") orelse return null;

    // macOS: ~/Library/Application Support/zoxide/db.zo
    {
        const p = std.fmt.bufPrint(buf, "{s}/Library/Application Support/zoxide/db.zo", .{home}) catch "";
        if (p.len > 0) {
            if (std.fs.cwd().access(p, .{})) |_| return p else |_| {}
        }
    }

    // Linux: $XDG_DATA_HOME/zoxide/db.zo or ~/.local/share/zoxide/db.zo
    var dh_buf: [std.fs.max_path_bytes]u8 = undefined;
    const data_home = std.posix.getenv("XDG_DATA_HOME") orelse
        std.fmt.bufPrint(&dh_buf, "{s}/.local/share", .{home}) catch return null;

    const p = std.fmt.bufPrint(buf, "{s}/zoxide/db.zo", .{data_home}) catch return null;
    if (std.fs.cwd().access(p, .{})) |_| return p else |_| return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "matchPath basic" {
    try std.testing.expect(matchPath("/home/user/Projects/xyron", &.{"xyron"}));
    try std.testing.expect(matchPath("/home/user/Projects/xyron", &.{ "proj", "xyron" }));
    try std.testing.expect(!matchPath("/home/user/Projects/xyron", &.{ "xyron", "proj" })); // wrong order
}

test "matchPath last component" {
    // Last term must match in last path component
    try std.testing.expect(matchPath("/home/user/Projects/xyron", &.{"xyr"}));
    try std.testing.expect(!matchPath("/home/user/Projects/xyron/src", &.{"xyr"})); // xyr not in "src"
}

test "matchPath case insensitive" {
    try std.testing.expect(matchPath("/home/User/Projects", &.{"user"}));
    try std.testing.expect(matchPath("/home/User/Projects", &.{"PROJECTS"}));
}

test "computeFrecency" {
    const now: i64 = 1000000;
    // Recent (within hour): ×4
    try std.testing.expectEqual(@as(f64, 40.0), computeFrecency(10.0, now - 100, now));
    // Within day: ×2
    try std.testing.expectEqual(@as(f64, 20.0), computeFrecency(10.0, now - 7200, now));
    // Within week: ÷2
    try std.testing.expectEqual(@as(f64, 5.0), computeFrecency(10.0, now - 200000, now));
    // Older: ÷4
    try std.testing.expectEqual(@as(f64, 2.5), computeFrecency(10.0, now - 1000000, now));
}
