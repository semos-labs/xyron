// builtins/jump.zig — Smart directory jumper (zoxide alternative).
//
// Subcommands:
//   jump go <query...>   Jump to best matching directory (aliased as `j`)
//   jump list            List all directories ranked by frecency
//   jump add <path>      Manually add a directory
//   jump remove <path>   Remove a directory
//   jump clean           Remove entries for non-existent directories
//   jump migrate         Import from zoxide database
//   jump help            Show usage
//
// `j <query>` is shorthand for `jump go <query>`.
// `j <literal-path>` acts as regular `cd` when the path exists on disk.

const std = @import("std");
const jump_db_mod = @import("../jump_db.zig");
const fz_mod = @import("fz.zig");
const Result = @import("mod.zig").BuiltinResult;

/// Global jump database — initialized by the shell at startup.
pub var db: ?jump_db_mod.JumpDb = null;

pub fn initDb(allocator: std.mem.Allocator) void {
    db = jump_db_mod.JumpDb.init(allocator);
}

pub fn deinitDb() void {
    if (db) |*d| d.deinit();
    db = null;
}

/// Record a cd into the jump database. Called by the shell after every cd.
pub fn recordCd(path: []const u8) void {
    if (db) |*d| d.recordVisit(path);
}

// ---------------------------------------------------------------------------
// Builtin entry point
// ---------------------------------------------------------------------------

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) return runHelp(stdout);

    const subcmd = args[0];
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcmd, "go")) return runGo(sub_args, stderr);
    if (std.mem.eql(u8, subcmd, "list")) return runList(stdout);
    if (std.mem.eql(u8, subcmd, "add")) return runAdd(sub_args, stderr);
    if (std.mem.eql(u8, subcmd, "remove")) return runRemove(sub_args, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "clean")) return runClean(stdout);
    if (std.mem.eql(u8, subcmd, "migrate")) return runMigrate(stdout, stderr);
    if (std.mem.eql(u8, subcmd, "reset")) return runReset(sub_args, stdout);
    if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help")) return runHelp(stdout);

    // Unknown subcommand — treat as `jump go`
    return runGo(args, stderr);
}

/// `j <args>` — shorthand for `jump go <args>`, with literal path support.
pub fn runJ(args: []const []const u8, stderr: std.fs.File) Result {
    if (args.len == 0) {
        // `j` with no args → cd home
        const home = std.posix.getenv("HOME") orelse {
            stderr.writeAll("xyron: j: HOME not set\n") catch {};
            return .{ .exit_code = 1 };
        };
        std.posix.chdir(home) catch {
            stderr.writeAll("xyron: j: cannot cd to HOME\n") catch {};
            return .{ .exit_code = 1 };
        };
        return .{};
    }
    return runGo(args, stderr);
}

// ---------------------------------------------------------------------------
// Subcommands
// ---------------------------------------------------------------------------

fn runGo(args: []const []const u8, stderr: std.fs.File) Result {
    if (args.len == 0) {
        stderr.writeAll("jump: no query provided\n") catch {};
        return .{ .exit_code = 1 };
    }

    // If single arg is a literal path that exists, act as cd
    if (args.len == 1) {
        const target = args[0];
        if (isLiteralPath(target)) {
            std.posix.chdir(target) catch |err| {
                var buf: [512]u8 = undefined;
                stderr.writeAll(std.fmt.bufPrint(&buf, "j: {s}: {s}\n", .{ target, @errorName(err) }) catch "j: error\n") catch {};
                return .{ .exit_code = 1 };
            };
            // Record the visit
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.posix.getcwd(&cwd_buf) catch "";
            if (cwd.len > 0) recordCd(cwd);
            return .{};
        }
    }

    // Query the database
    var d = &(db orelse {
        stderr.writeAll("jump: database not available\n") catch {};
        return .{ .exit_code = 1 };
    });

    var entries: [256]jump_db_mod.JumpEntry = undefined;
    var str_buf: [256 * 512]u8 = undefined;
    const count = d.query(args, &entries, &str_buf);

    if (count == 0) {
        var buf: [512]u8 = undefined;
        var msg_pos: usize = 0;
        msg_pos += cp(buf[msg_pos..], "jump: no match for ");
        for (args, 0..) |a, i| {
            if (i > 0) msg_pos += cp(buf[msg_pos..], " ");
            msg_pos += cp(buf[msg_pos..], a);
        }
        msg_pos += cp(buf[msg_pos..], "\n");
        stderr.writeAll(buf[0..msg_pos]) catch {};
        return .{ .exit_code = 1 };
    }

    // Single match or top match is very strong → jump directly
    if (count == 1 or entries[0].frecency > entries[1].frecency * 2) {
        return doChdir(entries[0].path, stderr);
    }

    // Multiple matches — use fz for interactive selection
    const selected = runFzSelector(&entries, count) orelse return .{ .exit_code = 130 };
    return doChdir(selected, stderr);
}

fn runList(stdout: std.fs.File) Result {
    var d = &(db orelse return .{ .exit_code = 1 });

    var entries: [256]jump_db_mod.JumpEntry = undefined;
    var str_buf: [256 * 512]u8 = undefined;
    const count = d.listAll(&entries, &str_buf);

    if (count == 0) {
        stdout.writeAll("(empty)\n") catch {};
        return .{};
    }

    // Detect if stdout is a pipe — if so, output just paths (for fz, grep, etc.)
    const is_tty = std.posix.isatty(stdout.handle);

    for (entries[0..count]) |e| {
        if (is_tty) {
            var buf: [1024]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{d:>8.1}  {s}\n", .{ e.frecency, e.path }) catch continue;
            stdout.writeAll(line) catch break;
        } else {
            stdout.writeAll(e.path) catch break;
            stdout.writeAll("\n") catch break;
        }
    }

    return .{};
}

fn runAdd(args: []const []const u8, stderr: std.fs.File) Result {
    if (args.len == 0) {
        stderr.writeAll("jump add: path required\n") catch {};
        return .{ .exit_code = 1 };
    }
    var d = &(db orelse return .{ .exit_code = 1 });

    // Resolve to absolute path
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = resolvePath(args[0], &abs_buf) orelse args[0];
    d.recordVisit(path);
    return .{};
}

fn runRemove(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) {
        stderr.writeAll("jump remove: path required\n") catch {};
        return .{ .exit_code = 1 };
    }
    var d = &(db orelse return .{ .exit_code = 1 });

    if (d.remove(args[0])) {
        var buf: [512]u8 = undefined;
        stdout.writeAll(std.fmt.bufPrint(&buf, "removed: {s}\n", .{args[0]}) catch "") catch {};
    } else {
        stderr.writeAll("jump remove: not found\n") catch {};
        return .{ .exit_code = 1 };
    }
    return .{};
}

fn runClean(stdout: std.fs.File) Result {
    var d = &(db orelse return .{ .exit_code = 1 });
    const removed = d.clean();
    var buf: [128]u8 = undefined;
    stdout.writeAll(std.fmt.bufPrint(&buf, "cleaned {d} stale entries\n", .{removed}) catch "") catch {};
    return .{};
}

fn runMigrate(stdout: std.fs.File, stderr: std.fs.File) Result {
    var d = &(db orelse {
        stderr.writeAll("jump: database not available\n") catch {};
        return .{ .exit_code = 1 };
    });

    const count = d.importZoxide() catch |err| {
        var buf: [256]u8 = undefined;
        const msg = switch (err) {
            error.NotFound => "jump migrate: zoxide database not found (checked ~/.local/share/zoxide/db.zo)\n",
            error.UnsupportedVersion => "jump migrate: unsupported zoxide database version (expected v3)\n",
            else => std.fmt.bufPrint(&buf, "jump migrate: {s}\n", .{@errorName(err)}) catch "jump migrate: error\n",
        };
        stderr.writeAll(msg) catch {};
        return .{ .exit_code = 1 };
    };

    var buf: [128]u8 = undefined;
    stdout.writeAll(std.fmt.bufPrint(&buf, "imported {d} entries from zoxide\n", .{count}) catch "") catch {};
    return .{};
}

fn runReset(args: []const []const u8, stdout: std.fs.File) Result {
    var d = &(db orelse return .{ .exit_code = 1 });
    const total = d.totalEntries();

    // Require --confirm flag
    var confirmed = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--confirm")) confirmed = true;
    }

    if (!confirmed) {
        var buf: [256]u8 = undefined;
        stdout.writeAll(std.fmt.bufPrint(&buf, "jump database has {d} entries. Run `jump reset --confirm` to delete all.\n", .{total}) catch "") catch {};
        return .{};
    }

    var mdb = &(d.db orelse return .{ .exit_code = 1 });
    mdb.exec("DELETE FROM jump_dirs") catch {};
    stdout.writeAll("jump database reset\n") catch {};
    return .{};
}

fn runHelp(stdout: std.fs.File) Result {
    stdout.writeAll(
        \\jump — smart directory jumper
        \\
        \\Usage:
        \\  j <query...>         Jump to matching directory (or cd if path exists)
        \\  jump go <query...>   Jump to matching directory
        \\  jump list            List all directories ranked by frecency
        \\  jump add <path>      Add a directory manually
        \\  jump remove <path>   Remove a directory
        \\  jump clean           Remove stale entries (deleted directories)
        \\  jump migrate         Import from zoxide database
        \\  jump reset           Clear all entries (with confirmation)
        \\
        \\Matching:
        \\  Terms are matched case-insensitively, in order.
        \\  The last term must match the last path component.
        \\  All cd commands are recorded automatically.
        \\
    ) catch {};
    return .{};
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Check if a string looks like a literal path (starts with /, ./, ../, or ~)
fn isLiteralPath(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '/') return pathExists(s);
    if (s[0] == '~') return true; // let cd handle tilde expansion
    if (s[0] == '.') {
        if (s.len == 1) return true; // "."
        if (s[1] == '/') return true; // "./"
        if (s[1] == '.' and (s.len == 2 or s[2] == '/')) return true; // ".." or "../"
    }
    // Check if it's a directory in cwd
    std.fs.cwd().access(s, .{}) catch return false;
    // Verify it's a directory
    const stat = std.fs.cwd().statFile(s) catch return false;
    return stat.kind == .directory;
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn doChdir(path: []const u8, stderr: std.fs.File) Result {
    std.posix.chdir(path) catch |err| {
        var buf: [512]u8 = undefined;
        stderr.writeAll(std.fmt.bufPrint(&buf, "j: {s}: {s}\n", .{ path, @errorName(err) }) catch "j: error\n") catch {};
        return .{ .exit_code = 1 };
    };
    // Record the visit
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";
    if (cwd.len > 0) recordCd(cwd);
    return .{};
}

fn resolvePath(path: []const u8, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (path.len > 0 and path[0] == '/') return path;
    const cwd = std.posix.getcwd(buf) catch return null;
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ cwd, path }) catch return null;
    @memcpy(buf[0..abs.len], abs);
    return buf[0..abs.len];
}

/// Launch fz to interactively pick from entries.
fn runFzSelector(entries: []const jump_db_mod.JumpEntry, count: usize) ?[]const u8 {
    // Build item list for display on stderr (since stdout might be piped)
    const tty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .write_only }) catch return null;
    defer tty.close();

    // Simple: write candidates to a temp pipe, invoke fz logic
    // For now, just pick the top match (fz integration TODO)
    _ = count;
    if (entries.len > 0) return entries[0].path;
    return null;
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}
