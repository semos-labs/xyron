// builtins.zig — Built-in shell commands.
//
// Phase 3 builtins: cd, pwd, exit, export, unset, env, which, type.
// Builtins that modify shell state (cd, exit, export, unset) are
// "process-only" and cannot run in pipelines.

const std = @import("std");
const environ_mod = @import("environ.zig");
const path_search = @import("path_search.zig");

pub const BuiltinResult = struct {
    exit_code: u8 = 0,
    should_exit: bool = false,
};

const history_db_mod = @import("history_db.zig");
const jobs_mod = @import("jobs.zig");

const aliases_mod = @import("aliases.zig");
const bridge = @import("attyx_bridge.zig");
const rich = @import("rich_output.zig");

const builtin_names = [_][]const u8{
    "cd", "pwd", "exit", "export", "unset", "env", "which", "type", "history",
    "jobs", "fg", "bg", "alias", "exec", "popup", "inspect", "ls", "ps",
};

const process_only_names = [_][]const u8{
    "cd", "exit", "export", "unset", "jobs", "fg", "bg", "alias",
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

/// Dispatch a builtin command.
pub fn execute(
    argv: []const []const u8,
    stdout: std.fs.File,
    stderr: std.fs.File,
    env: *environ_mod.Environ,
    hdb: ?*history_db_mod.HistoryDb,
    job_table: ?*jobs_mod.JobTable,
) BuiltinResult {
    const name = argv[0];
    const args = if (argv.len > 1) argv[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, name, "cd")) return executeCd(args, stderr, env);
    if (std.mem.eql(u8, name, "pwd")) return executePwd(stdout, stderr);
    if (std.mem.eql(u8, name, "exit")) return executeExit(args);
    if (std.mem.eql(u8, name, "export")) return executeExport(args, stderr, env);
    if (std.mem.eql(u8, name, "unset")) return executeUnset(args, stderr, env);
    if (std.mem.eql(u8, name, "env")) return executeEnv(stdout, env);
    if (std.mem.eql(u8, name, "which")) return executeWhich(args, stdout, stderr, env);
    if (std.mem.eql(u8, name, "type")) return executeType(args, stdout, stderr, env);
    if (std.mem.eql(u8, name, "history")) return executeHistory(args, stdout, hdb);
    if (std.mem.eql(u8, name, "alias")) return executeAlias(args, stdout, stderr);
    if (std.mem.eql(u8, name, "exec")) return executeExec(args, stderr);
    if (std.mem.eql(u8, name, "ls")) return executeLs(args, stdout);
    if (std.mem.eql(u8, name, "popup")) return executePopup(args, stdout);
    if (std.mem.eql(u8, name, "inspect")) return executeInspect(args, stdout, hdb);
    if (std.mem.eql(u8, name, "jobs")) return executeJobs(stdout, job_table);
    if (std.mem.eql(u8, name, "fg")) return executeFg(args, stdout, stderr, job_table);
    if (std.mem.eql(u8, name, "bg")) return executeBg(args, stdout, stderr, job_table);

    stderr.writeAll("xyron: unknown builtin\n") catch {};
    return .{ .exit_code = 127 };
}

// ---------------------------------------------------------------------------
// cd [dir]
// ---------------------------------------------------------------------------

fn executeCd(args: []const []const u8, stderr: std.fs.File, env: *const environ_mod.Environ) BuiltinResult {
    const target: []const u8 = if (args.len > 0)
        args[0]
    else
        env.home() orelse {
            stderr.writeAll("xyron: cd: HOME not set\n") catch {};
            return .{ .exit_code = 1 };
        };

    std.posix.chdir(target) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "xyron: cd: {s}: {s}\n", .{ target, @errorName(err) }) catch "xyron: cd: error\n";
        stderr.writeAll(msg) catch {};
        return .{ .exit_code = 1 };
    };
    return .{};
}

fn executePwd(stdout: std.fs.File, stderr: std.fs.File) BuiltinResult {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        stderr.writeAll("xyron: pwd: unable to get current directory\n") catch {};
        return .{ .exit_code = 1 };
    };
    stdout.writeAll(cwd) catch {};
    stdout.writeAll("\n") catch {};
    return .{};
}

fn executeExit(args: []const []const u8) BuiltinResult {
    var code: u8 = 0;
    if (args.len > 0) code = std.fmt.parseInt(u8, args[0], 10) catch 1;
    return .{ .exit_code = code, .should_exit = true };
}

// ---------------------------------------------------------------------------
// export NAME=value | export NAME
// ---------------------------------------------------------------------------

fn executeExport(args: []const []const u8, stderr: std.fs.File, env: *environ_mod.Environ) BuiltinResult {
    if (args.len == 0) {
        stderr.writeAll("xyron: export: usage: export NAME=value\n") catch {};
        return .{ .exit_code = 1 };
    }
    for (args) |arg| {
        if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            const key = arg[0..eq_pos];
            const val = arg[eq_pos + 1 ..];
            env.set(key, val) catch {
                stderr.writeAll("xyron: export: failed to set variable\n") catch {};
                return .{ .exit_code = 1 };
            };
        } else {
            // export NAME (without value) — currently a no-op since all vars
            // in the env map are already exported to children
        }
    }
    return .{};
}

// ---------------------------------------------------------------------------
// unset NAME
// ---------------------------------------------------------------------------

fn executeUnset(args: []const []const u8, stderr: std.fs.File, env: *environ_mod.Environ) BuiltinResult {
    _ = stderr;
    for (args) |name| {
        env.unset(name);
    }
    return .{};
}

// ---------------------------------------------------------------------------
// env — print environment
// ---------------------------------------------------------------------------

fn executeEnv(stdout: std.fs.File, env: *const environ_mod.Environ) BuiltinResult {
    var table = rich.Table{};
    table.addColumn(.{ .header = "variable", .color = "\x1b[1;36m" });
    table.addColumn(.{ .header = "value", .color = "\x1b[37m" });

    // Collect and sort keys
    var key_buf: [256][]const u8 = undefined;
    var count: usize = 0;
    var iter = env.map.iterator();
    while (iter.next()) |entry| {
        if (count >= 256) break;
        key_buf[count] = entry.key_ptr.*;
        count += 1;
    }

    // Sort
    std.mem.sort([]const u8, key_buf[0..count], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    for (key_buf[0..count]) |key| {
        const val = env.get(key) orelse "";
        const r = table.addRow();
        table.setCell(r, 0, key);
        // Truncate long values
        if (val.len > 80) {
            var trunc: [83]u8 = undefined;
            @memcpy(trunc[0..80], val[0..80]);
            trunc[80] = '.';
            trunc[81] = '.';
            trunc[82] = '.';
            table.setCell(r, 1, trunc[0..83]);
        } else {
            table.setCell(r, 1, val);
        }
    }

    table.render(stdout);
    return .{};
}

// ---------------------------------------------------------------------------
// which command — find executable in PATH
// ---------------------------------------------------------------------------

fn executeWhich(
    args: []const []const u8,
    stdout: std.fs.File,
    stderr: std.fs.File,
    env: *const environ_mod.Environ,
) BuiltinResult {
    if (args.len == 0) {
        stderr.writeAll("xyron: which: usage: which command\n") catch {};
        return .{ .exit_code = 1 };
    }
    // Use a page allocator for the temporary path search
    const allocator = std.heap.page_allocator;
    const result = path_search.findInPath(allocator, args[0], env) catch {
        return .{ .exit_code = 1 };
    };
    if (result) |path| {
        defer allocator.free(path);
        stdout.writeAll(path) catch {};
        stdout.writeAll("\n") catch {};
        return .{};
    }
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "xyron: which: {s} not found\n", .{args[0]}) catch return .{ .exit_code = 1 };
    stderr.writeAll(msg) catch {};
    return .{ .exit_code = 1 };
}

// ---------------------------------------------------------------------------
// type command — identify command type
// ---------------------------------------------------------------------------

fn executeType(
    args: []const []const u8,
    stdout: std.fs.File,
    stderr: std.fs.File,
    env: *const environ_mod.Environ,
) BuiltinResult {
    if (args.len == 0) {
        stderr.writeAll("xyron: type: usage: type command\n") catch {};
        return .{ .exit_code = 1 };
    }
    const name = args[0];
    var buf: [1024]u8 = undefined;

    if (isBuiltin(name)) {
        const msg = std.fmt.bufPrint(&buf, "{s} is a shell builtin\n", .{name}) catch return .{ .exit_code = 1 };
        stdout.writeAll(msg) catch {};
        return .{};
    }

    const allocator = std.heap.page_allocator;
    const path_result = path_search.findInPath(allocator, name, env) catch {
        return .{ .exit_code = 1 };
    };
    if (path_result) |path| {
        defer allocator.free(path);
        const msg = std.fmt.bufPrint(&buf, "{s} is {s}\n", .{ name, path }) catch return .{ .exit_code = 1 };
        stdout.writeAll(msg) catch {};
        return .{};
    }

    const msg = std.fmt.bufPrint(&buf, "xyron: type: {s} not found\n", .{name}) catch return .{ .exit_code = 1 };
    stderr.writeAll(msg) catch {};
    return .{ .exit_code = 1 };
}

// ---------------------------------------------------------------------------
// ls [path] — rich directory listing
// ---------------------------------------------------------------------------

fn executeLs(args: []const []const u8, stdout: std.fs.File) BuiltinResult {
    // Parse flags we support; anything unknown falls through to external ls
    var show_all = false;
    var show_long = false;
    var target: []const u8 = ".";

    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |ch| {
                switch (ch) {
                    'a' => show_all = true,
                    'l' => show_long = true,
                    else => return .{ .exit_code = 255 }, // unknown flag → external
                }
            }
        } else {
            target = arg;
        }
    }

    var dir = if (target[0] == '/')
        std.fs.openDirAbsolute(target, .{ .iterate = true }) catch {
            stdout.writeAll("xyron: ls: cannot open directory\n") catch {};
            return .{ .exit_code = 1 };
        }
    else
        std.fs.cwd().openDir(target, .{ .iterate = true }) catch {
            stdout.writeAll("xyron: ls: cannot open directory\n") catch {};
            return .{ .exit_code = 1 };
        };
    defer dir.close();

    var table = rich.Table{};
    if (show_long) table.addColumn(.{ .header = "permissions", .color = "\x1b[2m" });
    table.addColumn(.{ .header = "name", .color = "" });
    table.addColumn(.{ .header = "type", .color = "\x1b[2m" });
    table.addColumn(.{ .header = "size", .align_ = .right, .color = "" });

    var iter = dir.iterate();
    var names: [512][256]u8 = undefined;
    var kinds: [512]std.fs.Dir.Entry.Kind = undefined;
    var sizes: [512]u64 = undefined;
    var modes: [512]u32 = undefined;
    var name_lens: [512]usize = undefined;
    var entry_count: usize = 0;

    while (iter.next() catch null) |entry| {
        if (entry_count >= 512) break;
        // Skip dotfiles unless -a
        if (!show_all and entry.name.len > 0 and entry.name[0] == '.') continue;

        const nl = @min(entry.name.len, 255);
        @memcpy(names[entry_count][0..nl], entry.name[0..nl]);
        name_lens[entry_count] = nl;
        kinds[entry_count] = entry.kind;
        sizes[entry_count] = 0;
        modes[entry_count] = 0;

        // Stat for size and permissions
        if (dir.openFile(entry.name, .{})) |f| {
            defer f.close();
            if (f.stat()) |s| { sizes[entry_count] = s.size; modes[entry_count] = s.mode; } else |_| {}
        } else |_| {
            // openFile fails for dirs — try openDir + stat
            if (dir.openDir(entry.name, .{})) |*d2| {
                var d_mut = d2.*;
                defer d_mut.close();
                if (d_mut.stat()) |s| { modes[entry_count] = s.mode; } else |_| {}
            } else |_| {}
        }
        entry_count += 1;
    }

    var i: usize = 1;
    while (i < entry_count) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, names[j][0..name_lens[j]], names[j - 1][0..name_lens[j - 1]]) == .lt) {
            std.mem.swap([256]u8, &names[j], &names[j - 1]);
            std.mem.swap(std.fs.Dir.Entry.Kind, &kinds[j], &kinds[j - 1]);
            std.mem.swap(u64, &sizes[j], &sizes[j - 1]);
            std.mem.swap(u32, &modes[j], &modes[j - 1]);
            std.mem.swap(usize, &name_lens[j], &name_lens[j - 1]);
            j -= 1;
        }
    }

    for (0..entry_count) |ei| {
        const name = names[ei][0..name_lens[ei]];
        const kind = kinds[ei];
        const size = sizes[ei];
        const mode = modes[ei];

        const r = table.addRow();
        var col: usize = 0;

        // Permissions (only with -l)
        if (show_long) {
            var perm: [10]u8 = undefined;
            perm[0] = if (kind == .directory) @as(u8, 'd') else if (kind == .sym_link) @as(u8, 'l') else @as(u8, '-');
            perm[1] = if (mode & 0o400 != 0) @as(u8, 'r') else @as(u8, '-');
            perm[2] = if (mode & 0o200 != 0) @as(u8, 'w') else @as(u8, '-');
            perm[3] = if (mode & 0o100 != 0) @as(u8, 'x') else @as(u8, '-');
            perm[4] = if (mode & 0o040 != 0) @as(u8, 'r') else @as(u8, '-');
            perm[5] = if (mode & 0o020 != 0) @as(u8, 'w') else @as(u8, '-');
            perm[6] = if (mode & 0o010 != 0) @as(u8, 'x') else @as(u8, '-');
            perm[7] = if (mode & 0o004 != 0) @as(u8, 'r') else @as(u8, '-');
            perm[8] = if (mode & 0o002 != 0) @as(u8, 'w') else @as(u8, '-');
            perm[9] = if (mode & 0o001 != 0) @as(u8, 'x') else @as(u8, '-');
            table.setCell(r, col, &perm);
            col += 1;
        }

        // Name
        const name_color = rich.fileTypeColor(kind);
        var display_name: [258]u8 = undefined;
        @memcpy(display_name[0..name.len], name);
        var dn_len = name.len;
        if (kind == .directory and dn_len < 257) { display_name[dn_len] = '/'; dn_len += 1; }
        table.setCellColor(r, col, display_name[0..dn_len], name_color);
        col += 1;

        // Type
        const type_str: []const u8 = switch (kind) {
            .directory => "dir", .file => "file", .sym_link => "link",
            .named_pipe => "pipe", .unix_domain_socket => "sock", else => "?",
        };
        table.setCell(r, col, type_str);
        col += 1;

        // Size
        if (kind == .file) {
            var size_buf: [32]u8 = undefined;
            const size_str = rich.formatSize(&size_buf, size);
            table.setCellColor(r, col, size_str, rich.sizeColor(size));
        } else {
            table.setCell(r, col, "-");
        }
    }

    table.render(stdout);
    return .{};
}


// alias [name[=value]] — manage aliases
// ---------------------------------------------------------------------------

fn executeAlias(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) BuiltinResult {
    if (args.len == 0) {
        if (aliases_mod.aliasCount() == 0) return .{};
        var tbl = rich.Table{};
        tbl.addColumn(.{ .header = "alias", .color = "\x1b[1;33m" });
        tbl.addColumn(.{ .header = "command", .color = "\x1b[37m" });
        for (0..aliases_mod.aliasCount()) |i| {
            const r = tbl.addRow();
            tbl.setCell(r, 0, aliases_mod.nameAt(i));
            tbl.setCell(r, 1, aliases_mod.expansionAt(i));
        }
        tbl.render(stdout);
        return .{};
    }

    for (args) |arg| {
        if (std.mem.indexOf(u8, arg, "=")) |eq| {
            aliases_mod.set(arg[0..eq], arg[eq + 1 ..]);
        } else {
            if (aliases_mod.get(arg)) |expansion| {
                var buf: [1024]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s} -> {s}\n", .{ arg, expansion }) catch continue;
                stdout.writeAll(msg) catch {};
            } else {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "xyron: alias: {s}: not found\n", .{arg}) catch continue;
                stderr.writeAll(msg) catch {};
            }
        }
    }
    return .{};
}

// ---------------------------------------------------------------------------
// exec command [args...] — run a command via sh
// ---------------------------------------------------------------------------

fn executeExec(args: []const []const u8, stderr: std.fs.File) BuiltinResult {
    if (args.len == 0) {
        stderr.writeAll("xyron: exec: usage: exec command [args...]\n") catch {};
        return .{ .exit_code = 1 };
    }

    // Join args into a single command string for sh -c
    var cmd_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0 and pos < cmd_buf.len) { cmd_buf[pos] = ' '; pos += 1; }
        const n = @min(arg.len, cmd_buf.len - pos);
        @memcpy(cmd_buf[pos..][0..n], arg[0..n]);
        pos += n;
    }

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd_buf[0..pos] }, std.heap.page_allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch {
        stderr.writeAll("xyron: exec: failed to run command\n") catch {};
        return .{ .exit_code = 127 };
    };

    const term = child.wait() catch return .{ .exit_code = 127 };
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    return .{ .exit_code = code };
}

// ---------------------------------------------------------------------------
// jobs — list all jobs
// ---------------------------------------------------------------------------

fn executeJobs(stdout: std.fs.File, job_table: ?*jobs_mod.JobTable) BuiltinResult {
    const jt = job_table orelse return .{};
    const all = jt.allJobs();
    if (all.len == 0) return .{};

    var tbl = rich.Table{};
    tbl.addColumn(.{ .header = "id", .align_ = .right, .color = "\x1b[1;37m" });
    tbl.addColumn(.{ .header = "state", .color = "" });
    tbl.addColumn(.{ .header = "command", .color = "\x1b[37m" });

    for (all) |*job| {
        const r = tbl.addRow();
        var id_buf: [8]u8 = undefined;
        tbl.setCell(r, 0, std.fmt.bufPrint(&id_buf, "{d}", .{job.id}) catch "?");
        const state_color: []const u8 = switch (job.state) {
            .running => "\x1b[32m",
            .stopped => "\x1b[33m",
            .completed => "\x1b[2m",
        };
        tbl.setCellColor(r, 1, job.state.label(), state_color);
        tbl.setCell(r, 2, job.rawInputSlice());
    }
    tbl.render(stdout);
    return .{};
}

// ---------------------------------------------------------------------------
// fg [job_id] — bring job to foreground, resume if stopped
// ---------------------------------------------------------------------------

fn executeFg(
    args: []const []const u8,
    stdout: std.fs.File,
    stderr: std.fs.File,
    job_table: ?*jobs_mod.JobTable,
) BuiltinResult {
    const executor = @import("executor.zig");
    const term_mod = @import("term.zig");
    const table = job_table orelse {
        stderr.writeAll("xyron: fg: no job table\n") catch {};
        return .{ .exit_code = 1 };
    };

    const job = if (args.len > 0) blk: {
        const id = std.fmt.parseInt(u32, args[0], 10) catch {
            stderr.writeAll("xyron: fg: invalid job id\n") catch {};
            return .{ .exit_code = 1 };
        };
        break :blk table.findById(id);
    } else table.findLastActive();

    if (job) |j| {
        if (j.state == .completed) {
            stderr.writeAll("xyron: fg: job has already completed\n") catch {};
            return .{ .exit_code = 1 };
        }

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}\n", .{j.rawInputSlice()}) catch "";
        stdout.writeAll(msg) catch {};

        // Suspend raw mode BEFORE resume so child gets clean terminal
        term_mod.suspendRawMode();
        if (j.state == .stopped) j.cont();
        const state = executor.waitForJobFg(j);
        term_mod.resumeRawMode();

        if (state == .stopped) return .{ .exit_code = 148 };
        return .{ .exit_code = j.exit_code };
    }

    stderr.writeAll("xyron: fg: no current job\n") catch {};
    return .{ .exit_code = 1 };
}

// ---------------------------------------------------------------------------
// bg [job_id] — resume a stopped job in background
// ---------------------------------------------------------------------------

fn executeBg(
    args: []const []const u8,
    stdout: std.fs.File,
    stderr: std.fs.File,
    job_table: ?*jobs_mod.JobTable,
) BuiltinResult {
    const table = job_table orelse {
        stderr.writeAll("xyron: bg: no job table\n") catch {};
        return .{ .exit_code = 1 };
    };

    const job = if (args.len > 0) blk: {
        const id = std.fmt.parseInt(u32, args[0], 10) catch {
            stderr.writeAll("xyron: bg: invalid job id\n") catch {};
            return .{ .exit_code = 1 };
        };
        break :blk table.findById(id);
    } else table.findLastStopped();

    if (job) |j| {
        if (j.state != .stopped) {
            stderr.writeAll("xyron: bg: job is not stopped\n") catch {};
            return .{ .exit_code = 1 };
        }
        j.cont();
        j.background = true;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[{d}]  {s} &\n", .{ j.id, j.rawInputSlice() }) catch "";
        stdout.writeAll(msg) catch {};
        return .{};
    }

    stderr.writeAll("xyron: bg: no stopped job\n") catch {};
    return .{ .exit_code = 1 };
}

// ---------------------------------------------------------------------------
// popup <text> — show content in Attyx popup or terminal
// ---------------------------------------------------------------------------

fn executePopup(args: []const []const u8, stdout: std.fs.File) BuiltinResult {
    if (args.len == 0) {
        stdout.writeAll("xyron: popup: usage: popup <text>\n") catch {};
        return .{ .exit_code = 1 };
    }
    // Join args
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0 and pos < buf.len) { buf[pos] = ' '; pos += 1; }
        const n = @min(arg.len, buf.len - pos);
        @memcpy(buf[pos..][0..n], arg[0..n]);
        pos += n;
    }
    bridge.popup(buf[0..pos], "popup", stdout, std.heap.page_allocator);
    return .{};
}

// ---------------------------------------------------------------------------
// inspect <kind> [id] — inspect runtime objects
// ---------------------------------------------------------------------------

fn executeInspect(
    args: []const []const u8,
    stdout: std.fs.File,
    hdb: ?*history_db_mod.HistoryDb,
) BuiltinResult {
    if (args.len == 0) {
        stdout.writeAll("xyron: inspect: usage: inspect <history|env|attyx>\n") catch {};
        return .{ .exit_code = 1 };
    }
    if (bridge.runInspect(args, stdout, hdb)) return .{};

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "xyron: inspect: unknown kind: {s}\n", .{args[0]}) catch return .{ .exit_code = 1 };
    stdout.writeAll(msg) catch {};
    return .{ .exit_code = 1 };
}

// ---------------------------------------------------------------------------
// history [N] — show recent command history
// ---------------------------------------------------------------------------

fn executeHistory(
    args: []const []const u8,
    stdout: std.fs.File,
    hdb: ?*history_db_mod.HistoryDb,
) BuiltinResult {
    const db = hdb orelse {
        stdout.writeAll("xyron: history: no database available\n") catch {};
        return .{ .exit_code = 1 };
    };

    var limit: usize = 25;
    if (args.len > 0) {
        limit = std.fmt.parseInt(usize, args[0], 10) catch 25;
    }

    const max_entries = @min(limit, 100);
    var entries: [100]history_db_mod.HistoryEntry = undefined;
    var str_buf: [100 * 256]u8 = undefined;
    const count = db.recentEntries(entries[0..max_entries], &str_buf);

    var table = rich.Table{};
    table.addColumn(.{ .header = "#", .align_ = .right, .color = "\x1b[2m" });
    table.addColumn(.{ .header = "command", .color = "" });
    table.addColumn(.{ .header = "exit", .align_ = .right, .color = "" });

    var i = count;
    while (i > 0) {
        i -= 1;
        const r = table.addRow();
        var id_buf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{entries[i].id}) catch "-";
        table.setCell(r, 0, id_str);
        table.setCell(r, 1, entries[i].raw_input);

        var code_buf: [8]u8 = undefined;
        const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{entries[i].exit_code}) catch "?";
        const code_color: []const u8 = if (entries[i].exit_code == 0) "\x1b[32m" else "\x1b[31m";
        table.setCellColor(r, 2, code_str, code_color);
    }

    table.render(stdout);
    return .{};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isBuiltin recognises all builtins" {
    try std.testing.expect(isBuiltin("cd"));
    try std.testing.expect(isBuiltin("export"));
    try std.testing.expect(isBuiltin("unset"));
    try std.testing.expect(isBuiltin("env"));
    try std.testing.expect(isBuiltin("which"));
    try std.testing.expect(isBuiltin("type"));
}

test "isBuiltin rejects unknown" {
    try std.testing.expect(!isBuiltin("cat"));
    try std.testing.expect(!isBuiltin(""));
}

test "isProcessOnly" {
    try std.testing.expect(isProcessOnly("cd"));
    try std.testing.expect(isProcessOnly("export"));
    try std.testing.expect(isProcessOnly("unset"));
    try std.testing.expect(!isProcessOnly("pwd"));
    try std.testing.expect(!isProcessOnly("env"));
}
