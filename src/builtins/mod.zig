// builtins/mod.zig — Builtin command dispatcher.
//
// Each command lives in its own file. This module provides isBuiltin,
// isProcessOnly, and execute which dispatches to the right handler.

const std = @import("std");
const environ_mod = @import("../environ.zig");
const history_db_mod = @import("../history_db.zig");
const jobs_mod = @import("../jobs.zig");

pub const BuiltinResult = struct {
    exit_code: u8 = 0,
    should_exit: bool = false,
};

// Command modules
const cd = @import("cd.zig");
const pwd = @import("pwd.zig");
const exit_cmd = @import("exit.zig");
const export_cmd = @import("export.zig");
const unset = @import("unset.zig");
const env = @import("env.zig");
const which = @import("which.zig");
const type_cmd = @import("type.zig");
const history = @import("history.zig");
const alias_cmd = @import("alias.zig");
const exec_cmd = @import("exec.zig");
const ls = @import("ls.zig");
const ps = @import("ps.zig");
const json = @import("json.zig");
const popup = @import("popup.zig");
const migrate = @import("migrate.zig");
const inspect = @import("inspect.zig");
const jobs_cmd = @import("jobs.zig");
const fg = @import("fg.zig");
const bg = @import("bg.zig");
const query = @import("query.zig");
const select_cmd = @import("select.zig");
const where_cmd = @import("where.zig");
const sort_cmd = @import("sort_cmd.zig");
const csv_cmd = @import("csv.zig");
const fz_cmd = @import("fz.zig");
const jump_cmd = @import("jump.zig");
const to_json = @import("to_json.zig");
const xyron_cmd = @import("xyron_cmd.zig");

const builtin_names = [_][]const u8{
    "cd", "pwd", "exit", "export", "unset", "env", "which", "type",
    "history", "jobs", "fg", "bg", "alias", "exec", "popup", "inspect",
    "ls", "ps", "json", "to_json", "query", "select", "where", "sort", "csv", "fz", "migrate", "jump", "j", "xyron", "xy",
};

const process_only_names = [_][]const u8{
    "cd", "exit", "export", "unset", "jobs", "fg", "bg", "alias", "j",
};

pub fn isBuiltin(name: []const u8) bool {
    for (builtin_names) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

pub fn isProcessOnly(name: []const u8) bool {
    for (process_only_names) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

pub fn execute(
    argv: []const []const u8,
    stdout: std.fs.File,
    stderr: std.fs.File,
    env_inst: *environ_mod.Environ,
    hdb: ?*history_db_mod.HistoryDb,
    job_table: ?*jobs_mod.JobTable,
) BuiltinResult {
    const name = argv[0];
    const args = if (argv.len > 1) argv[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, name, "cd")) return cd.run(args, stderr, env_inst);
    if (std.mem.eql(u8, name, "pwd")) return pwd.run(stdout, stderr);
    if (std.mem.eql(u8, name, "exit")) return exit_cmd.run(args);
    if (std.mem.eql(u8, name, "export")) return export_cmd.run(args, stderr, env_inst);
    if (std.mem.eql(u8, name, "unset")) return unset.run(args, env_inst);
    if (std.mem.eql(u8, name, "env")) return env.run(stdout, env_inst);
    if (std.mem.eql(u8, name, "which")) return which.run(args, stdout, stderr, env_inst);
    if (std.mem.eql(u8, name, "type")) return type_cmd.run(args, stdout, stderr, env_inst);
    if (std.mem.eql(u8, name, "history")) return history.run(args, stdout, hdb);
    if (std.mem.eql(u8, name, "alias")) return alias_cmd.run(args, stdout, stderr);
    if (std.mem.eql(u8, name, "exec")) return exec_cmd.run(args, stderr);
    if (std.mem.eql(u8, name, "ls")) return ls.run(args, stdout);
    if (std.mem.eql(u8, name, "ps")) return ps.run(args, stdout);
    if (std.mem.eql(u8, name, "json")) return json.run(args, stdout);
    if (std.mem.eql(u8, name, "to_json")) return .{ .exit_code = to_json.run(args, stdout, stderr) };
    if (std.mem.eql(u8, name, "query")) return .{ .exit_code = query.run(args, stdout, stderr) };
    if (std.mem.eql(u8, name, "select")) return .{ .exit_code = select_cmd.run(args, stdout, stderr) };
    if (std.mem.eql(u8, name, "where")) return .{ .exit_code = where_cmd.run(args, stdout, stderr) };
    if (std.mem.eql(u8, name, "sort")) return .{ .exit_code = sort_cmd.run(args, stdout, stderr) };
    if (std.mem.eql(u8, name, "csv")) return .{ .exit_code = csv_cmd.run(args, stdout, stderr) };
    if (std.mem.eql(u8, name, "fz")) return fz_cmd.run(args, stdout);
    if (std.mem.eql(u8, name, "jump")) return jump_cmd.run(args, stdout, stderr);
    if (std.mem.eql(u8, name, "j")) return jump_cmd.runJ(args, stderr);
    if (std.mem.eql(u8, name, "xyron") or std.mem.eql(u8, name, "xy")) return xyron_cmd.run(args, stdout, stderr, env_inst);
    if (std.mem.eql(u8, name, "migrate")) return migrate.run(args, stdout, stderr);
    if (std.mem.eql(u8, name, "popup")) return popup.run(args, stdout);
    if (std.mem.eql(u8, name, "inspect")) return inspect.run(args, stdout, hdb);
    if (std.mem.eql(u8, name, "jobs")) return jobs_cmd.run(stdout, job_table);
    if (std.mem.eql(u8, name, "fg")) return fg.run(args, stdout, stderr, job_table);
    if (std.mem.eql(u8, name, "bg")) return bg.run(args, stdout, stderr, job_table);

    stderr.writeAll("xyron: unknown builtin\n") catch {};
    return .{ .exit_code = 127 };
}

// Tests
test "isBuiltin" {
    try std.testing.expect(isBuiltin("cd"));
    try std.testing.expect(isBuiltin("ls"));
    try std.testing.expect(isBuiltin("ps"));
    try std.testing.expect(!isBuiltin("cat"));
}
