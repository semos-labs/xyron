// history — structured history queries and replay.
//
// Subcommands:
//   history [N]                  Recent entries (default)
//   history search <text>        Search by command text
//   history failed [N]           Failed commands
//   history show <id>            Detailed entry view
//   history rerun <id>           Replay a command
//   history cwd [path]           Commands from a directory
//   history slow [min_ms]        Long-running commands

const std = @import("std");
const rich = @import("../rich_output.zig");
const history_db_mod = @import("../history_db.zig");
const types = @import("../types.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, hdb: ?*history_db_mod.HistoryDb) Result {
    const db = hdb orelse {
        stdout.writeAll("xyron: history: no database\n") catch {};
        return .{ .exit_code = 1 };
    };

    if (args.len == 0) return recent(db, 25, stdout);

    const subcmd = args[0];

    // history N (plain number = recent with limit)
    if (std.fmt.parseInt(usize, subcmd, 10)) |limit| {
        return recent(db, limit, stdout);
    } else |_| {}

    if (std.mem.eql(u8, subcmd, "search") and args.len > 1) return search(db, args[1], stdout);
    if (std.mem.eql(u8, subcmd, "failed")) return failed(db, if (args.len > 1) parseNum(args[1], 25) else 25, stdout);
    if (std.mem.eql(u8, subcmd, "show") and args.len > 1) return show(db, args[1], stdout);
    if (std.mem.eql(u8, subcmd, "rerun") and args.len > 1) return rerun(db, args[1], stdout);
    if (std.mem.eql(u8, subcmd, "cwd")) return cwdQuery(db, if (args.len > 1) args[1] else null, stdout);
    if (std.mem.eql(u8, subcmd, "slow")) return slow(db, if (args.len > 1) parseNum(args[1], 1000) else 1000, stdout);

    stdout.writeAll("xyron: history: unknown subcommand\n") catch {};
    stdout.writeAll("  usage: history [N|search|failed|show|rerun|cwd|slow]\n") catch {};
    return .{ .exit_code = 1 };
}

/// Replay result — carries the command to execute.
pub var replay_command: [256]u8 = undefined;
pub var replay_len: usize = 0;
pub var replay_pending: bool = false;

fn recent(db: *history_db_mod.HistoryDb, limit: usize, stdout: std.fs.File) Result {
    var q = history_db_mod.HistoryQuery{ .limit = @min(limit, 100) };
    _ = &q;
    var entries: [100]history_db_mod.HistoryEntry = undefined;
    var str_buf: [100 * 256]u8 = undefined;
    const count = db.query(&q, entries[0..q.limit], &str_buf);
    renderTable(entries[0..count], stdout);
    return .{};
}

fn search(db: *history_db_mod.HistoryDb, text: []const u8, stdout: std.fs.File) Result {
    const q = history_db_mod.HistoryQuery{ .text_contains = text, .limit = 25 };
    var entries: [25]history_db_mod.HistoryEntry = undefined;
    var str_buf: [25 * 256]u8 = undefined;
    const count = db.query(&q, &entries, &str_buf);
    if (count == 0) { stdout.writeAll("No matches.\n") catch {}; return .{}; }
    renderTable(entries[0..count], stdout);
    return .{};
}

fn failed(db: *history_db_mod.HistoryDb, limit: usize, stdout: std.fs.File) Result {
    const q = history_db_mod.HistoryQuery{ .only_failed = true, .limit = @min(limit, 50) };
    var entries: [50]history_db_mod.HistoryEntry = undefined;
    var str_buf: [50 * 256]u8 = undefined;
    const count = db.query(&q, entries[0..q.limit], &str_buf);
    if (count == 0) { stdout.writeAll("No failed commands.\n") catch {}; return .{}; }
    renderTable(entries[0..count], stdout);
    return .{};
}

fn show(db: *history_db_mod.HistoryDb, id_str: []const u8, stdout: std.fs.File) Result {
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        stdout.writeAll("xyron: history show: invalid id\n") catch {};
        return .{ .exit_code = 1 };
    };
    var str_buf: [512]u8 = undefined;
    const entry = db.getById(id, &str_buf) orelse {
        stdout.writeAll("xyron: history show: entry not found\n") catch {};
        return .{ .exit_code = 1 };
    };

    var tbl = rich.Table{};
    tbl.addColumn(.{ .header = "field", .color = "\x1b[1;36m" });
    tbl.addColumn(.{ .header = "value", .color = "" });

    addField(&tbl, "id", fmtInt(entry.id));
    addField(&tbl, "command", entry.raw_input);
    addField(&tbl, "cwd", entry.cwd);
    const code_color: []const u8 = if (entry.exit_code == 0) "\x1b[32m" else "\x1b[31m";
    tbl.setCellColor(tbl.addRow(), 1, fmtInt(entry.exit_code), code_color);
    tbl.setCell(tbl.row_count - 1, 0, "exit_code");
    addField(&tbl, "duration", fmtDuration(entry.duration_ms));
    addField(&tbl, "started_at", fmtTimestamp(entry.started_at));

    tbl.render(stdout);
    return .{};
}

fn rerun(db: *history_db_mod.HistoryDb, id_str: []const u8, stdout: std.fs.File) Result {
    // Special: "last" = rerun most recent, "failed" = rerun last failed
    if (std.mem.eql(u8, id_str, "last")) {
        const q = history_db_mod.HistoryQuery{ .limit = 1 };
        var entries: [1]history_db_mod.HistoryEntry = undefined;
        var str_buf: [256]u8 = undefined;
        if (db.query(&q, &entries, &str_buf) == 0) {
            stdout.writeAll("No history.\n") catch {};
            return .{ .exit_code = 1 };
        }
        return scheduleReplay(entries[0].raw_input, stdout);
    }
    if (std.mem.eql(u8, id_str, "failed")) {
        const q = history_db_mod.HistoryQuery{ .only_failed = true, .limit = 1 };
        var entries: [1]history_db_mod.HistoryEntry = undefined;
        var str_buf: [256]u8 = undefined;
        if (db.query(&q, &entries, &str_buf) == 0) {
            stdout.writeAll("No failed commands.\n") catch {};
            return .{ .exit_code = 1 };
        }
        return scheduleReplay(entries[0].raw_input, stdout);
    }

    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        stdout.writeAll("xyron: history rerun: invalid id (use number, 'last', or 'failed')\n") catch {};
        return .{ .exit_code = 1 };
    };
    var str_buf: [256]u8 = undefined;
    const entry = db.getById(id, &str_buf) orelse {
        stdout.writeAll("xyron: history rerun: not found\n") catch {};
        return .{ .exit_code = 1 };
    };
    return scheduleReplay(entry.raw_input, stdout);
}

fn cwdQuery(db: *history_db_mod.HistoryDb, path: ?[]const u8, stdout: std.fs.File) Result {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path orelse (std.posix.getcwd(&cwd_buf) catch ".");

    const q = history_db_mod.HistoryQuery{ .cwd_filter = cwd, .limit = 25 };
    var entries: [25]history_db_mod.HistoryEntry = undefined;
    var str_buf: [25 * 256]u8 = undefined;
    const count = db.query(&q, &entries, &str_buf);
    if (count == 0) { stdout.writeAll("No commands in this directory.\n") catch {}; return .{}; }
    renderTable(entries[0..count], stdout);
    return .{};
}

fn slow(db: *history_db_mod.HistoryDb, min_ms: usize, stdout: std.fs.File) Result {
    const q = history_db_mod.HistoryQuery{ .min_duration_ms = @intCast(min_ms), .limit = 25 };
    var entries: [25]history_db_mod.HistoryEntry = undefined;
    var str_buf: [25 * 256]u8 = undefined;
    const count = db.query(&q, &entries, &str_buf);
    if (count == 0) { stdout.writeAll("No slow commands.\n") catch {}; return .{}; }
    renderTable(entries[0..count], stdout);
    return .{};
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn scheduleReplay(input: []const u8, stdout: std.fs.File) Result {
    const n = @min(input.len, replay_command.len);
    @memcpy(replay_command[0..n], input[0..n]);
    replay_len = n;
    replay_pending = true;
    var buf: [300]u8 = undefined;
    stdout.writeAll(std.fmt.bufPrint(&buf, "replaying: {s}\n", .{input}) catch "") catch {};
    return .{};
}

fn renderTable(entries: []const history_db_mod.HistoryEntry, stdout: std.fs.File) void {
    var tbl = rich.Table{};
    tbl.addColumn(.{ .header = "#", .align_ = .right, .color = "\x1b[2m" });
    tbl.addColumn(.{ .header = "command", .color = "" });
    tbl.addColumn(.{ .header = "exit", .align_ = .right, .color = "" });
    tbl.addColumn(.{ .header = "duration", .align_ = .right, .color = "\x1b[33m" });

    // Reverse to show oldest-first
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const e = &entries[i];
        const r = tbl.addRow();
        tbl.setCell(r, 0, fmtInt(e.id));
        tbl.setCell(r, 1, e.raw_input);
        tbl.setCellColor(r, 2, fmtInt(e.exit_code), if (e.exit_code == 0) "\x1b[32m" else "\x1b[31m");
        tbl.setCell(r, 3, fmtDuration(e.duration_ms));
    }
    tbl.render(stdout);
}

var fmt_int_buf: [16]u8 = undefined;
fn fmtInt(v: i64) []const u8 {
    return std.fmt.bufPrint(&fmt_int_buf, "{d}", .{v}) catch "?";
}

var fmt_dur_buf: [16]u8 = undefined;
fn fmtDuration(ms: i64) []const u8 {
    if (ms < 1000) return std.fmt.bufPrint(&fmt_dur_buf, "{d}ms", .{ms}) catch "?";
    if (ms < 60000) return std.fmt.bufPrint(&fmt_dur_buf, "{d}s", .{@divTrunc(ms, 1000)}) catch "?";
    return std.fmt.bufPrint(&fmt_dur_buf, "{d}m", .{@divTrunc(ms, 60000)}) catch "?";
}

var fmt_ts_buf: [32]u8 = undefined;
fn fmtTimestamp(ms: i64) []const u8 {
    const secs = @divTrunc(ms, 1000);
    return std.fmt.bufPrint(&fmt_ts_buf, "{d}", .{secs}) catch "?";
}

fn addField(tbl: *rich.Table, key: []const u8, val: []const u8) void {
    const r = tbl.addRow();
    tbl.setCell(r, 0, key);
    tbl.setCell(r, 1, val);
}

fn parseNum(s: []const u8, default: usize) usize {
    return std.fmt.parseInt(usize, s, 10) catch default;
}
