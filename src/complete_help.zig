// complete_help.zig — Help introspection fallback provider.
//
// Lazily probes commands via --help, parses flag patterns from output,
// and caches results in SQLite. Uses strict timeouts and bounded output
// capture. Never blocks the shell on failure.

const std = @import("std");
const posix = std.posix;
const sqlite = @import("sqlite.zig");
const environ_mod = @import("environ.zig");
const path_search = @import("path_search.zig");
const complete = @import("complete.zig");

const CACHE_TTL_MS: i64 = 7 * 24 * 3600 * 1000; // 7 days
const HELP_TIMEOUT_MS: i32 = 2000;
const MAX_OUTPUT: usize = 65536;

pub const HelpCache = struct {
    /// Stores a copy of the Db handle (not a pointer) to avoid dangling refs.
    /// The underlying C sqlite3* handle is heap-allocated and shared with HistoryDb.
    /// Only HistoryDb closes the handle — HelpCache never closes it.
    db: ?sqlite.Db,

    pub fn init(db: ?sqlite.Db) HelpCache {
        var result = HelpCache{ .db = db };
        if (result.db) |*d| initSchema(d);
        return result;
    }

    /// Ensure help flags are cached for a command (supports subcommands like "docker compose").
    pub fn ensureCached(self: *HelpCache, cmd: []const u8, env: *const environ_mod.Environ) void {
        const db = &(self.db orelse return);

        // Check if already cached and fresh
        if (isCached(db, cmd)) return;

        // Split "docker compose" → base="docker", sub_args=["compose"]
        const alloc = std.heap.page_allocator;
        var parts: [16][]const u8 = undefined;
        var part_count: usize = 0;
        var iter = std.mem.splitScalar(u8, cmd, ' ');
        while (iter.next()) |p| {
            if (p.len == 0) continue;
            if (part_count < parts.len) {
                parts[part_count] = p;
                part_count += 1;
            }
        }
        if (part_count == 0) return;

        // Resolve the base command path
        const path = path_search.findInPath(alloc, parts[0], env) catch return;
        if (path == null) return;
        defer alloc.free(path.?);

        // Run: <cmd_path> [sub_args...] --help
        const output = runHelpWithArgs(alloc, path.?, parts[1..part_count]) catch return;
        defer alloc.free(output);

        // Parse flags from output and store under the full command key
        parseAndStore(db, cmd, output);
    }

    /// Check if `name` is a known subcommand of `cmd` in the cache.
    pub fn isSubcommand(self: *HelpCache, cmd: []const u8, name: []const u8) bool {
        var db = &(self.db orelse return false);

        var stmt = db.prepare(
            "SELECT 1 FROM command_help_flags WHERE command = ?1 AND flag = ?2 AND flag NOT LIKE '-%' LIMIT 1",
        ) catch return false;
        defer stmt.deinit();

        stmt.bindText(1, cmd);
        stmt.bindText(2, name);

        const has_row = stmt.step() catch return false;
        return has_row;
    }

    /// Query cached flags matching a prefix. Returns flags with descriptions.
    pub fn queryFlags(self: *HelpCache, cmd: []const u8, prefix: []const u8, out: *complete.CandidateBuffer) void {
        var db = &(self.db orelse return);

        var stmt = db.prepare(
            "SELECT flag, description FROM command_help_flags WHERE command = ?1 AND flag LIKE ?2",
        ) catch return;
        defer stmt.deinit();

        stmt.bindText(1, cmd);

        var pattern_buf: [256]u8 = undefined;
        const plen = @min(prefix.len, 254);
        @memcpy(pattern_buf[0..plen], prefix[0..plen]);
        pattern_buf[plen] = '%';
        pattern_buf[plen + 1] = 0;
        stmt.bindText(2, pattern_buf[0 .. plen + 1]);

        while (true) {
            const has_row = stmt.step() catch break;
            if (!has_row) break;
            const flag = stmt.columnText(0) orelse continue;
            const desc = stmt.columnText(1) orelse "";
            // Subcommands (no dash prefix) get command kind, flags get flag kind
            const kind: complete.CandidateKind = if (flag.len > 0 and flag[0] != '-') .external_cmd else .flag;
            out.addWithDesc(flag, desc, kind);
        }
    }
};

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

fn initSchema(db: *sqlite.Db) void {
    db.exec(
        "CREATE TABLE IF NOT EXISTS command_help_flags (" ++
            "command TEXT NOT NULL," ++
            "flag TEXT NOT NULL," ++
            "description TEXT NOT NULL DEFAULT ''," ++
            "cached_at INTEGER NOT NULL," ++
            "PRIMARY KEY (command, flag)" ++
            ")",
    ) catch {};
}

fn isCached(db: *sqlite.Db, cmd: []const u8) bool {
    var stmt = db.prepare(
        "SELECT COUNT(*) FROM command_help_flags WHERE command = ?1 AND cached_at > ?2",
    ) catch return false;
    defer stmt.deinit();

    stmt.bindText(1, cmd);
    const cutoff = std.time.milliTimestamp() - CACHE_TTL_MS;
    stmt.bindInt(2, cutoff);

    _ = stmt.step() catch return false;
    return stmt.columnInt(0) > 0;
}

// ---------------------------------------------------------------------------
// Help execution
// ---------------------------------------------------------------------------

fn runHelpWithArgs(alloc: std.mem.Allocator, cmd_path: []const u8, sub_args: []const []const u8) ![]const u8 {
    // Build argv: [cmd_path, sub_args..., "--help"]
    var argv_buf: [18][]const u8 = undefined;
    argv_buf[0] = cmd_path;
    const n_sub = @min(sub_args.len, 16);
    for (0..n_sub) |j| argv_buf[1 + j] = sub_args[j];
    argv_buf[1 + n_sub] = "--help";
    const argv = argv_buf[0 .. 2 + n_sub];

    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return error.SpawnFailed;

    // Read output with timeout using poll
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(alloc);

    const stdout_fd = if (child.stdout) |f| f.handle else return error.NoPipe;
    const stderr_fd = if (child.stderr) |f| f.handle else return error.NoPipe;

    var fds = [_]posix.pollfd{
        .{ .fd = stdout_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = stderr_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var deadline: i32 = HELP_TIMEOUT_MS;
    while (output.items.len < MAX_OUTPUT and deadline > 0) {
        const start = std.time.milliTimestamp();
        const ready = posix.poll(&fds, deadline) catch break;
        const elapsed: i32 = @intCast(@min(std.time.milliTimestamp() - start, 2000));
        deadline -= elapsed;

        if (ready == 0) break; // timeout

        for (0..2) |fi| {
            if (fds[fi].revents & posix.POLL.IN != 0) {
                var buf: [4096]u8 = undefined;
                const n = posix.read(fds[fi].fd, &buf) catch 0;
                if (n == 0) { fds[fi].fd = -1; } else {
                    output.appendSlice(alloc, buf[0..n]) catch {};
                }
            }
        }

        if (fds[0].fd == -1 and fds[1].fd == -1) break;
    }

    _ = child.wait() catch {};
    return output.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Flag parsing
// ---------------------------------------------------------------------------

fn parseAndStore(db: *sqlite.Db, cmd: []const u8, output: []const u8) void {
    const now = std.time.milliTimestamp();
    var in_commands_section = false;

    var line_iter = std.mem.splitScalar(u8, output, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Detect section headers (non-indented lines)
        if (trimmed.len > 0 and !startsWithSpace(line)) {
            const has_cmd_keyword = std.mem.indexOf(u8, line, "ommand") != null or
                std.mem.indexOf(u8, line, "OMMAND") != null or
                std.mem.indexOf(u8, line, "ubcommand") != null;

            if (has_cmd_keyword) {
                // "Commands:", "CORE COMMANDS", "Management Commands:", etc.
                in_commands_section = true;
                continue;
            }
            // Non-indented descriptive headers (git-style): any non-indented line
            // that doesn't look like a flag or usage line may precede subcommands.
            // Don't clear in_commands_section for these — git uses them as group labels.
            if (!std.mem.startsWith(u8, trimmed, "usage:") and
                !std.mem.startsWith(u8, trimmed, "Usage:") and
                !std.mem.startsWith(u8, trimmed, "USAGE") and
                trimmed[0] != '-' and trimmed[0] != '[')
            {
                // Potential section header — don't disable commands section
            } else {
                in_commands_section = false;
            }
        }

        if (trimmed.len == 0) continue;

        // Parse flags: lines starting with -
        if (trimmed.len >= 2 and trimmed[0] == '-') {
            parseFlags(db, cmd, trimmed, now);
            continue;
        }

        // Parse subcommands: indented lines matching "word    description" pattern.
        // Two detection modes:
        //   1. Explicitly in a "Commands:" section
        //   2. Indented line with alpha word + large gap + description (universal pattern)
        if (startsWithSpace(line) and trimmed.len > 0 and isAlphaStart(trimmed[0])) {
            var end: usize = 0;
            while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and trimmed[end] != ':') : (end += 1) {}

            if (end >= 2 and end <= 30) {
                // Check for a large gap (2+ spaces) after the word — indicates
                // a two-column layout (subcommand + description)
                var gap: usize = 0;
                var gi = end;
                // Skip trailing colon (gh-style: "auth:   Authenticate...")
                if (gi < trimmed.len and trimmed[gi] == ':') gi += 1;
                while (gi < trimmed.len and (trimmed[gi] == ' ' or trimmed[gi] == '\t')) : (gi += 1) { gap += 1; }

                if (in_commands_section or gap >= 2) {
                    const word = trimmed[0..end];
                    // Reject words that look like file paths or arguments
                    if (!std.mem.startsWith(u8, word, "/") and
                        !std.mem.startsWith(u8, word, ".") and
                        std.mem.indexOf(u8, word, "=") == null)
                    {
                        const desc = extractSubcmdDescription(trimmed[end..]);
                        storeEntry(db, cmd, word, desc, now);
                    }
                }
            }
        }
    }
}

fn parseFlags(db: *sqlite.Db, cmd: []const u8, trimmed: []const u8, now: i64) void {
    var i: usize = 0;
    var last_flag: ?[]const u8 = null;

    while (i < trimmed.len) {
        if (trimmed[i] != '-') break;

        const flag_start = i;
        i += 1;
        if (i < trimmed.len and trimmed[i] == '-') i += 1;
        while (i < trimmed.len and isIdChar(trimmed[i])) : (i += 1) {}
        const flag = trimmed[flag_start..i];

        if (flag.len >= 2) last_flag = flag;

        // Skip =<val>, [val], comma, spaces
        while (i < trimmed.len and (trimmed[i] == ',' or trimmed[i] == '=' or trimmed[i] == ' ' or trimmed[i] == '<' or trimmed[i] == '[')) {
            if (trimmed[i] == '<') {
                while (i < trimmed.len and trimmed[i] != '>') : (i += 1) {}
                if (i < trimmed.len) i += 1;
            } else if (trimmed[i] == '[') {
                while (i < trimmed.len and trimmed[i] != ']') : (i += 1) {}
                if (i < trimmed.len) i += 1;
            } else if (trimmed[i] == ' ') {
                // Check if this is a large gap (description follows)
                const gap_start = i;
                while (i < trimmed.len and trimmed[i] == ' ') : (i += 1) {}
                if (i - gap_start >= 2) break; // description starts here
                // Single space — might be between -f, --flag
            } else {
                i += 1;
                // Skip non-space token (VALUE, ARG, etc.)
                while (i < trimmed.len and trimmed[i] != ' ' and trimmed[i] != ',') : (i += 1) {}
            }
        }
        if (i < trimmed.len and trimmed[i] == '-') continue;
        break;
    }

    // Everything remaining is the description
    const desc = std.mem.trim(u8, if (i < trimmed.len) trimmed[i..] else "", " \t");

    // Store the last (longest) flag with description
    if (last_flag) |flag| storeEntry(db, cmd, flag, desc, now);
}

/// Extract description text: skip whitespace/args, take remaining text.
fn extractDescription(rest: []const u8) []const u8 {
    // Skip leading whitespace and any argument-like words (uppercase, brackets)
    var i: usize = 0;
    // Skip spaces
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
    // Skip argument placeholders like "FILE", "<arg>", "[value]"
    while (i < rest.len) {
        if (rest[i] == '<' or rest[i] == '[') {
            while (i < rest.len and rest[i] != '>' and rest[i] != ']') : (i += 1) {}
            if (i < rest.len) i += 1;
            while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
        } else if (i < rest.len and rest[i] >= 'A' and rest[i] <= 'Z') {
            while (i < rest.len and rest[i] != ' ' and rest[i] != '\t') : (i += 1) {}
            while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
        } else break;
    }
    const desc = std.mem.trim(u8, rest[i..], " \t");
    return if (desc.len > 0) desc else "";
}

fn startsWithSpace(line: []const u8) bool {
    return line.len > 0 and (line[0] == ' ' or line[0] == '\t');
}

fn isAlphaStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

/// Extract description from a subcommand line. Skips example args by
/// finding text after a large gap (multiple spaces), which is where
/// help output typically puts the description column.
fn extractSubcmdDescription(rest: []const u8) []const u8 {
    // Find a gap of 2+ spaces — text after that is the description
    var i: usize = 0;
    while (i < rest.len) {
        // Skip single spaces (within an arg)
        if (rest[i] == ' ' or rest[i] == '\t') {
            const gap_start = i;
            while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
            // Gap of 2+ chars and remaining text = description
            if (i - gap_start >= 2 and i < rest.len) {
                // Check if we've seen at least one word before
                if (gap_start > 0) {
                    return std.mem.trim(u8, rest[i..], " \t");
                }
            }
        } else {
            i += 1;
        }
    }
    return "";
}

fn storeEntry(db: *sqlite.Db, cmd: []const u8, flag: []const u8, desc: []const u8, now: i64) void {
    var stmt = db.prepare(
        "INSERT OR REPLACE INTO command_help_flags (command, flag, description, cached_at) VALUES (?1, ?2, ?3, ?4)",
    ) catch return;
    defer stmt.deinit();
    stmt.bindText(1, cmd);
    stmt.bindText(2, flag);
    stmt.bindText(3, desc);
    stmt.bindInt(4, now);
    _ = stmt.step() catch {};
}

fn isIdChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "HelpCache init does not crash" {
    const db = try sqlite.Db.open(":memory:");
    var hc = HelpCache.init(db);
    _ = &hc;
    // Don't close db here — HelpCache shares the handle
}

test "parseAndStore extracts flags" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    initSchema(&db);

    const output =
        \\Usage: test [OPTIONS]
        \\
        \\  -h, --help     Show help
        \\  -v, --verbose  Be verbose
        \\  --output=FILE  Output file
    ;
    parseAndStore(&db, "test", output);

    // Verify flags were stored
    var stmt = try db.prepare("SELECT COUNT(*) FROM command_help_flags WHERE command = 'test'");
    defer stmt.deinit();
    _ = try stmt.step();
    const count = stmt.columnInt(0);
    try std.testing.expect(count >= 3);
}

test "parseAndStore extracts git-style subcommands" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    initSchema(&db);

    // Git-style output: descriptive section headers (no "Commands:" keyword),
    // subcommands indented with multi-space gap before description
    const output =
        \\usage: git [options] <command> [<args>]
        \\
        \\start a working area
        \\   clone      Clone a repository into a new directory
        \\   init       Create an empty Git repository
        \\
        \\work on the current change
        \\   add        Add file contents to the index
        \\   mv         Move or rename a file
        \\   restore    Restore working tree files
        \\
        \\examine the history and state
        \\   diff       Show changes between commits
        \\   log        Show commit logs
        \\   status     Show the working tree status
    ;
    parseAndStore(&db, "git", output);

    // Should find subcommands like clone, init, add, diff, log, status
    var stmt = try db.prepare("SELECT flag FROM command_help_flags WHERE command = 'git' AND flag NOT LIKE '-%' ORDER BY flag");
    defer stmt.deinit();
    var found: usize = 0;
    while (try stmt.step()) { found += 1; }
    try std.testing.expect(found >= 6); // clone, init, add, mv, restore, diff, log, status
}

test "parseAndStore extracts docker-style subcommands" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    initSchema(&db);

    const output =
        \\Usage:  docker [OPTIONS] COMMAND
        \\
        \\Management Commands:
        \\  compose     Docker Compose
        \\  container   Manage containers
        \\  image       Manage images
        \\
        \\Commands:
        \\  build       Build an image from a Dockerfile
        \\  exec        Execute a command in a running container
        \\  ps          List containers
        \\  run         Create and run a new container
    ;
    parseAndStore(&db, "docker", output);

    var stmt = try db.prepare("SELECT COUNT(*) FROM command_help_flags WHERE command = 'docker' AND flag NOT LIKE '-%'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expect(stmt.columnInt(0) >= 7); // compose, container, image, build, exec, ps, run
}

test "parseAndStore extracts gh-style subcommands" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    initSchema(&db);

    // gh-style: uppercase headers without colon, subcommands with trailing colon
    const output =
        \\USAGE
        \\  gh <command> <subcommand> [flags]
        \\
        \\CORE COMMANDS
        \\  auth:        Authenticate gh and git with GitHub
        \\  issue:       Manage issues
        \\  pr:          Manage pull requests
        \\  repo:        Manage repositories
        \\
        \\ADDITIONAL COMMANDS
        \\  alias:       Create command shortcuts
        \\  api:         Make an authenticated GitHub API request
    ;
    parseAndStore(&db, "gh", output);

    var stmt = try db.prepare("SELECT COUNT(*) FROM command_help_flags WHERE command = 'gh' AND flag NOT LIKE '-%'");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expect(stmt.columnInt(0) >= 6); // auth, issue, pr, repo, alias, api
}
