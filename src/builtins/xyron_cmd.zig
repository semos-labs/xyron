// builtins/xyron_cmd.zig — Xyron shell utilities command.
//
// Subcommands:
//   xyron secrets init             Set up GPG key and secrets file
//   xyron secrets open [--local]   TUI browser for secrets
//   xyron secrets get <name>       Query a secret by name
//   xyron secrets add <name> <value> [--description, --local]
//   xyron secrets list [--local]   List all secrets

const std = @import("std");
const posix = std.posix;
const c = std.c;
const secrets_mod = @import("../secrets.zig");
const style = @import("../style.zig");
const project_cmd = @import("project_cmd.zig");
const doctor_cmd = @import("doctor_cmd.zig");
const explain_cmd = @import("explain_cmd.zig");
const bootstrap_cmd = @import("bootstrap_cmd.zig");
const Result = @import("mod.zig").BuiltinResult;

const environ_mod = @import("../environ.zig");

/// Set by `xyron reload` — shell checks this after executeLine.
pub var reload_pending: bool = false;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File, env_inst: *environ_mod.Environ) Result {
    if (args.len == 0) return runHelp(stdout);
    if (std.mem.eql(u8, args[0], "secrets")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return runSecrets(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "project")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return project_cmd.run(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "run")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return project_cmd.runCommand(sub_args, stdout, stderr, env_inst);
    }
    if (std.mem.eql(u8, args[0], "up")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return project_cmd.serviceUp(sub_args, stdout, stderr, env_inst);
    }
    if (std.mem.eql(u8, args[0], "down")) return project_cmd.serviceDown(stdout, stderr);
    if (std.mem.eql(u8, args[0], "restart")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return project_cmd.serviceRestart(sub_args, stdout, stderr, env_inst);
    }
    if (std.mem.eql(u8, args[0], "ps")) return project_cmd.servicePs(stdout, stderr);
    if (std.mem.eql(u8, args[0], "logs")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return project_cmd.serviceLogs(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "init")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return bootstrap_cmd.runInit(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "new")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return bootstrap_cmd.runNew(sub_args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "reload")) {
        reload_pending = true;
        stdout.writeAll("\x1b[2mreloading config...\x1b[0m\n") catch {};
        return .{};
    }
    if (std.mem.eql(u8, args[0], "doctor")) return doctor_cmd.run(stdout);
    if (std.mem.eql(u8, args[0], "context")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        // "xyron context explain [KEY]" or bare "xyron context" → explain summary
        if (sub_args.len == 0) return explain_cmd.run(&.{}, stdout, stderr);
        if (std.mem.eql(u8, sub_args[0], "explain")) {
            const explain_args = if (sub_args.len > 1) sub_args[1..] else &[_][]const u8{};
            return explain_cmd.run(explain_args, stdout, stderr);
        }
        // Fall through to project context for backward compat
        return project_cmd.run(args, stdout, stderr);
    }
    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) return runHelp(stdout);
    stderr.writeAll("xyron: unknown subcommand. Try `xyron help`\n") catch {};
    return .{ .exit_code = 1 };
}

fn runHelp(stdout: std.fs.File) Result {
    stdout.writeAll(
        \\xyron — shell utilities
        \\
        \\Commands:
        \\  xyron init                             Initialize xyron.toml
        \\  xyron new <ecosystem> <name>          Create new project
        \\  xyron run <command>                   Run a project command
        \\  xyron up [service]                   Start project services
        \\  xyron down                           Stop project services
        \\  xyron restart <service>              Restart a service
        \\  xyron ps                             Show service status
        \\  xyron logs <service>                 Show service logs
        \\  xyron reload                           Reload config and project context
        \\  xyron doctor                          Diagnose project issues
        \\  xyron context explain [KEY]           Explain context/value origin
        \\  xyron project info                   Show project info
        \\  xyron project context                Show resolved context
        \\  xyron secrets init                   Set up GPG key
        \\  xyron secrets open [--local]         Browse secrets (TUI)
        \\  xyron secrets get <name>             Get a secret value
        \\  xyron secrets add <n> <v> [opts]     Add a secret
        \\  xyron secrets list [--local]         List secrets
        \\
        \\Add options:
        \\  --description "text"    Description
        \\  --local                 Scope to current directory
        \\  --password              Store as password (not env)
        \\
    ) catch {};
    return .{};
}

fn runSecrets(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) return runSecretsOpen(args, stdout, stderr);
    const subcmd = args[0];
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
    if (std.mem.eql(u8, subcmd, "init")) return @import("secrets_init.zig").run(stdout, stderr);
    if (std.mem.eql(u8, subcmd, "open")) return runSecretsOpen(sub_args, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "get")) return runSecretsGet(sub_args, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "add")) return runSecretsAdd(sub_args, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "list")) return runSecretsList(sub_args, stdout, stderr);
    stderr.writeAll("xyron secrets: unknown subcommand\n") catch {};
    return .{ .exit_code = 1 };
}

// ---------------------------------------------------------------------------
// CLI subcommands
// ---------------------------------------------------------------------------

fn runSecretsGet(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) { stderr.writeAll("Usage: xyron secrets get <name>\n") catch {}; return .{ .exit_code = 1 }; }
    var store = secrets_mod.SecretsStore.init();
    if (!store.isInitialized()) { stderr.writeAll("Run `xyron secrets init` first.\n") catch {}; return .{ .exit_code = 1 }; }
    store.load() catch { stderr.writeAll("Failed to decrypt secrets.\n") catch {}; return .{ .exit_code = 1 }; };
    if (store.findByName(args[0])) |idx| {
        stdout.writeAll(store.secrets[idx].valueSlice()) catch {};
        stdout.writeAll("\n") catch {};
        return .{};
    }
    stderr.writeAll("Secret not found: ") catch {};
    stderr.writeAll(args[0]) catch {};
    stderr.writeAll("\n") catch {};
    return .{ .exit_code = 1 };
}

fn runSecretsAdd(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len < 2) {
        stderr.writeAll("Usage: xyron secrets add <name> <value> [--description \"...\"] [--local] [--password]\n") catch {};
        return .{ .exit_code = 1 };
    }
    const name = args[0];
    const value = args[1];
    var desc: []const u8 = "";
    var kind: secrets_mod.SecretKind = .env;
    var dir: []const u8 = "";

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--description") and i + 1 < args.len) { i += 1; desc = args[i]; }
        else if (std.mem.eql(u8, args[i], "--local")) {
            kind = .local;
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            dir = std.posix.getcwd(&cwd_buf) catch "";
        } else if (std.mem.eql(u8, args[i], "--password")) { kind = .password; }
    }

    var store = secrets_mod.SecretsStore.init();
    if (!store.isInitialized()) { stderr.writeAll("Run `xyron secrets init` first.\n") catch {}; return .{ .exit_code = 1 }; }
    store.load() catch {};
    if (store.findByName(name) != null) {
        stderr.writeAll("Secret already exists: ") catch {};
        stderr.writeAll(name) catch {};
        stderr.writeAll(". Remove it first.\n") catch {};
        return .{ .exit_code = 1 };
    }
    if (!store.add(name, value, desc, dir, kind)) { stderr.writeAll("Too many secrets.\n") catch {}; return .{ .exit_code = 1 }; }
    store.save() catch { stderr.writeAll("Failed to save secrets.\n") catch {}; return .{ .exit_code = 1 }; };
    stdout.writeAll("Added: ") catch {};
    stdout.writeAll(name) catch {};
    stdout.writeAll("\n") catch {};
    return .{};
}

fn runSecretsList(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    var store = secrets_mod.SecretsStore.init();
    if (!store.isInitialized()) { stderr.writeAll("Run `xyron secrets init` first.\n") catch {}; return .{ .exit_code = 1 }; }
    store.load() catch { stderr.writeAll("Failed to decrypt secrets.\n") catch {}; return .{ .exit_code = 1 }; };

    var local_only = false;
    for (args) |a| { if (std.mem.eql(u8, a, "--local")) local_only = true; }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch ".";
    var count: usize = 0;
    for (0..store.count) |i| {
        const s = &store.secrets[i];
        if (local_only and (s.kind != .local or !std.mem.eql(u8, s.dirSlice(), cwd))) continue;
        var buf: [1024]u8 = undefined;
        var pos: usize = 0;
        pos += cp(buf[pos..], "  ");
        switch (s.kind) {
            .env => pos += style.colored(buf[pos..], .green, "env"),
            .local => pos += style.colored(buf[pos..], .blue, "local"),
            .password => pos += style.colored(buf[pos..], .yellow, "pass"),
        }
        pos += cp(buf[pos..], "  ");
        pos += style.boldText(buf[pos..], s.nameSlice());
        if (s.desc_len > 0) { pos += cp(buf[pos..], "  "); pos += style.dimText(buf[pos..], s.descSlice()); }
        pos += cp(buf[pos..], "\n");
        stdout.writeAll(buf[0..pos]) catch {};
        count += 1;
    }
    if (count == 0) stdout.writeAll("  No secrets found.\n") catch {};
    return .{};
}

// ---------------------------------------------------------------------------
// Secrets TUI
// ---------------------------------------------------------------------------

fn runSecretsOpen(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    _ = stdout;
    var store = secrets_mod.SecretsStore.init();
    if (!store.isInitialized()) { stderr.writeAll("Run `xyron secrets init` first.\n") catch {}; return .{ .exit_code = 1 }; }
    store.load() catch { stderr.writeAll("Failed to decrypt secrets.\n") catch {}; return .{ .exit_code = 1 }; };

    var local_only = false;
    for (args) |a| { if (std.mem.eql(u8, a, "--local")) local_only = true; }

    const tty_fd = posix.openZ("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return .{ .exit_code = 1 };
    defer posix.close(tty_fd);
    const tty = std.fs.File{ .handle = tty_fd };

    var orig: c.termios = undefined;
    _ = c.tcgetattr(tty_fd, &orig);
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    _ = c.tcsetattr(tty_fd, .NOW, &raw);
    defer _ = c.tcsetattr(tty_fd, .NOW, &orig);

    {
        var enter_buf: [64]u8 = undefined;
        var ep: usize = 0;
        ep += style.altScreenOn(enter_buf[ep..]);
        ep += style.showCursor(enter_buf[ep..]);
        tty.writeAll(enter_buf[0..ep]) catch {};
    }
    defer {
        var exit_buf: [64]u8 = undefined;
        var xp: usize = 0;
        xp += style.showCursor(exit_buf[xp..]);
        xp += style.altScreenOff(exit_buf[xp..]);
        tty.writeAll(exit_buf[0..xp]) catch {};
    }

    var cursor: usize = 0;
    var scroll: usize = 0;
    var show_values = false;
    var searching = false;
    var filter: [128]u8 = undefined;
    var filter_len: usize = 0;
    var ts = getTermSize(tty_fd);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch ".";

    renderTui(tty, &store, cursor, scroll, show_values, local_only, cwd, ts, searching, filter[0..filter_len]);

    while (true) {
        var key_buf: [1]u8 = undefined;
        const rc = c.read(tty_fd, &key_buf, 1);
        if (rc == -1) { ts = getTermSize(tty_fd); renderTui(tty, &store, cursor, scroll, show_values, local_only, cwd, ts, searching, filter[0..filter_len]); continue; }
        if (rc <= 0) break;
        const vis = visibleRows(ts);
        const total = filteredCountSearch(&store, local_only, cwd, filter[0..filter_len]);

        if (searching) {
            switch (key_buf[0]) {
                27 => { // Esc — exit search, clear filter
                    searching = false;
                    filter_len = 0;
                    cursor = 0;
                    scroll = 0;
                },
                10, 13 => { // Enter — exit search, keep filter
                    searching = false;
                },
                127, 8 => { // Backspace
                    if (filter_len > 0) {
                        filter_len -= 1;
                        cursor = 0;
                        scroll = 0;
                    }
                },
                21 => { // Ctrl+U — clear filter
                    filter_len = 0;
                    cursor = 0;
                    scroll = 0;
                },
                3 => { searching = false; filter_len = 0; }, // Ctrl+C
                else => |ch| {
                    if (ch >= 32 and ch < 127 and filter_len < 128) {
                        filter[filter_len] = ch;
                        filter_len += 1;
                        cursor = 0;
                        scroll = 0;
                    }
                },
            }
        } else {
            switch (key_buf[0]) {
                27 => {
                    var seq: [2]u8 = undefined;
                    const rc2 = c.read(tty_fd, &seq, 2);
                    if (rc2 == 2 and seq[0] == '[') {
                        switch (seq[1]) {
                            'A' => { if (cursor > 0) cursor -= 1; if (cursor < scroll) scroll = cursor; },
                            'B' => { if (total > 0 and cursor + 1 < total) cursor += 1; if (cursor >= scroll + vis) scroll = cursor - vis + 1; },
                            else => {},
                        }
                    } else if (rc2 <= 0) break;
                },
                'q', 3 => break,
                '/' => { searching = true; },
                'v' => show_values = !show_values,
                'a' => {
                    const kind: secrets_mod.SecretKind = if (local_only) .local else .env;
                    if (addSecretModal(tty, tty_fd, &store, kind, if (local_only) cwd else "", ts)) {
                        store.save() catch {};
                    }
                },
                'e' => {
                    if (resolveIndexSearch(&store, cursor, local_only, cwd, filter[0..filter_len])) |real_idx| {
                        if (editSecretModal(tty, tty_fd, &store, real_idx, ts)) {
                            store.save() catch {};
                        }
                    }
                },
                'x' => {
                    if (resolveIndexSearch(&store, cursor, local_only, cwd, filter[0..filter_len])) |real_idx| {
                        store.remove(real_idx);
                        const new_total = filteredCountSearch(&store, local_only, cwd, filter[0..filter_len]);
                        if (cursor > 0 and cursor >= new_total) cursor -= 1;
                        store.save() catch {};
                    }
                },
                16 => { if (cursor > 0) cursor -= 1; if (cursor < scroll) scroll = cursor; },
                14 => { if (total > 0 and cursor + 1 < total) cursor += 1; if (cursor >= scroll + vis) scroll = cursor - vis + 1; },
                else => {},
            }
        }
        renderTui(tty, &store, cursor, scroll, show_values, local_only, cwd, ts, searching, filter[0..filter_len]);
    }

    if (store.modified) store.save() catch {};
    return .{};
}

// ---------------------------------------------------------------------------
// Add / Edit modals
// ---------------------------------------------------------------------------

const FieldIdx = enum(u2) { name = 0, value = 1, desc = 2 };

fn addSecretModal(tty: std.fs.File, tty_fd: posix.fd_t, store: *secrets_mod.SecretsStore, kind: secrets_mod.SecretKind, dir: []const u8, ts: TermSize) bool {
    var fields: [3][128]u8 = undefined;
    var lens = [3]usize{ 0, 0, 0 };
    const labels = [3][]const u8{ "Name", "Value", "Description" };
    var active: FieldIdx = .name;

    while (true) {
        renderModal(tty, "Add Secret", &labels, &fields, &lens, active, ts);
        switch (readModalKey(tty_fd)) {
            .up => active = if (@intFromEnum(active) > 0) @enumFromInt(@intFromEnum(active) - 1) else active,
            .down, .tab => active = if (@intFromEnum(active) < 2) @enumFromInt(@intFromEnum(active) + 1) else .name,
            .enter => {
                if (lens[0] == 0) continue;
                return store.add(fields[0][0..lens[0]], fields[1][0..lens[1]], fields[2][0..lens[2]], dir, kind);
            },
            .backspace => { const ai = @intFromEnum(active); if (lens[ai] > 0) lens[ai] -= 1; },
            .char => |ch| { const ai = @intFromEnum(active); if (lens[ai] < 127) { fields[ai][lens[ai]] = ch; lens[ai] += 1; } },
            .cancel => return false,
            .none => {},
        }
    }
}

fn editSecretModal(tty: std.fs.File, tty_fd: posix.fd_t, store: *secrets_mod.SecretsStore, idx: usize, ts: TermSize) bool {
    if (idx >= store.count) return false;
    const sec = &store.secrets[idx];

    var fields: [3][128]u8 = undefined;
    var lens: [3]usize = undefined;
    const labels = [3][]const u8{ "Name", "Value", "Description" };

    @memcpy(fields[0][0..sec.name_len], sec.name[0..sec.name_len]);
    lens[0] = sec.name_len;
    const vl = @min(sec.value_len, 128);
    @memcpy(fields[1][0..vl], sec.value[0..vl]);
    lens[1] = vl;
    const dl = @min(sec.desc_len, 128);
    @memcpy(fields[2][0..dl], sec.description[0..dl]);
    lens[2] = dl;

    var active: FieldIdx = .value;

    while (true) {
        renderModal(tty, "Edit Secret", &labels, &fields, &lens, active, ts);
        switch (readModalKey(tty_fd)) {
            .up => active = if (@intFromEnum(active) > 0) @enumFromInt(@intFromEnum(active) - 1) else active,
            .down, .tab => active = if (@intFromEnum(active) < 2) @enumFromInt(@intFromEnum(active) + 1) else .name,
            .enter => {
                if (lens[0] == 0) continue;
                secrets_mod.SecretsStore.setFieldPub(&sec.name, &sec.name_len, fields[0][0..lens[0]]);
                secrets_mod.SecretsStore.setFieldPub(&sec.value, &sec.value_len, fields[1][0..lens[1]]);
                secrets_mod.SecretsStore.setFieldPub(&sec.description, &sec.desc_len, fields[2][0..lens[2]]);
                store.modified = true;
                return true;
            },
            .backspace => { const ai = @intFromEnum(active); if (lens[ai] > 0) lens[ai] -= 1; },
            .char => |ch| { const ai = @intFromEnum(active); if (lens[ai] < 127) { fields[ai][lens[ai]] = ch; lens[ai] += 1; } },
            .cancel => return false,
            .none => {},
        }
    }
}

const ModalKey = union(enum) { up, down, tab, enter, backspace, cancel, none, char: u8 };

fn readModalKey(tty_fd: posix.fd_t) ModalKey {
    var kb: [1]u8 = undefined;
    const rc = c.read(tty_fd, &kb, 1);
    if (rc <= 0) return .cancel;
    return switch (kb[0]) {
        27 => {
            // Poll for more bytes (50ms) — if none, it's plain Esc
            var fds = [_]posix.pollfd{.{ .fd = tty_fd, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&fds, 50) catch return .cancel;
            if (ready == 0) return .cancel; // plain Esc
            var seq: [2]u8 = undefined;
            const rc2 = c.read(tty_fd, &seq, 2);
            if (rc2 == 2 and seq[0] == '[') {
                return switch (seq[1]) { 'A' => .up, 'B' => .down, else => .none };
            }
            return .cancel;
        },
        3 => .cancel,
        9 => .tab,
        10, 13 => .enter,
        127, 8 => .backspace,
        else => |ch| if (ch >= 32 and ch < 127) .{ .char = ch } else .none,
    };
}

fn renderModal(tty: std.fs.File, title: []const u8, labels: *const [3][]const u8, fields: *const [3][128]u8, lens: *const [3]usize, active: FieldIdx, ts: TermSize) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const cols = ts.cols;
    const rows = ts.rows;

    // Centered modal
    const modal_w: usize = if (cols > 60) 56 else cols -| 4;
    const modal_h: usize = 9;
    const start_row = if (rows > modal_h + 2) (rows - modal_h) / 2 else 1;
    const start_col = if (cols > modal_w + 2) (cols - modal_w) / 2 else 1;
    const inner_w = modal_w - 4;

    const placeholders = [3][]const u8{ "SECRET_NAME", "secret value", "optional description" };

    var cursor_row: usize = 0;
    var cursor_col: usize = 0;

    // Find longest label
    var max_label: usize = 0;
    for (labels) |l| max_label = @max(max_label, l.len);

    // Modal bg: palette 0 (#45475a in catppuccin-style themes)
    const modal_bg = "\x1b[40m";

    // Row layout: 0=title, 1=sep, 2=blank, 3/4/5=fields, 6=blank, 7=help, 8=bottom pad
    for (0..modal_h) |ri| {
        pos += style.moveTo(buf[pos..], start_row + ri, start_col);
        pos += cp(buf[pos..], modal_bg);
        var row_w: usize = 0;

        if (ri == 0) {
            pos += cp(buf[pos..], "  ");
            pos += style.bold(buf[pos..]);
            pos += cp(buf[pos..], title);
            pos += style.unbold(buf[pos..]);
            row_w = title.len + 2;
        } else if (ri == 1) {
            pos += style.fg(buf[pos..], .bright_black);
            pos += style.hline(buf[pos..], modal_w);
            pos += style.fg(buf[pos..], .default);
            row_w = modal_w;
        } else if (ri >= 3 and ri <= 5) {
            const fi = ri - 3;
            const is_active = @intFromEnum(active) == fi;
            const val = fields[fi][0..lens[fi]];
            const label = labels[fi];

            pos += cp(buf[pos..], "  ");
            row_w += 2;
            const lpad = max_label - label.len;
            { var lp: usize = 0; while (lp < lpad and pos < buf.len) : (lp += 1) { buf[pos] = ' '; pos += 1; } }
            row_w += lpad;

            if (is_active) { pos += style.fg(buf[pos..], .cyan); } else { pos += style.fg(buf[pos..], .white); }
            pos += cp(buf[pos..], label);
            pos += style.fg(buf[pos..], .default);
            row_w += label.len;

            pos += cp(buf[pos..], "  ");
            row_w += 2;

            const max_val = if (inner_w > max_label + 4) inner_w - max_label - 4 else 10;
            if (val.len > 0) {
                if (is_active) pos += style.bold(buf[pos..]);
                pos += style.fg(buf[pos..], .bright_white);
                const vd = @min(val.len, max_val);
                pos += cp(buf[pos..], val[0..vd]);
                row_w += vd;
                pos += style.fg(buf[pos..], .default);
                if (is_active) pos += style.unbold(buf[pos..]);
            } else {
                pos += style.fg(buf[pos..], .bright_black);
                const ph = placeholders[fi];
                const phd = @min(ph.len, max_val);
                pos += cp(buf[pos..], ph[0..phd]);
                row_w += phd;
                pos += style.fg(buf[pos..], .default);
            }

            if (is_active) {
                cursor_row = start_row + ri;
                cursor_col = start_col + 2 + max_label + 2 + val.len;
            }
        } else if (ri == 7) {
            pos += cp(buf[pos..], "  ");
            pos += style.fg(buf[pos..], .white);
            pos += style.bold(buf[pos..]);
            pos += cp(buf[pos..], "Tab");
            pos += style.unbold(buf[pos..]);
            pos += cp(buf[pos..], " next  ");
            pos += style.bold(buf[pos..]);
            pos += cp(buf[pos..], "Enter");
            pos += style.unbold(buf[pos..]);
            pos += cp(buf[pos..], " save  ");
            pos += style.bold(buf[pos..]);
            pos += cp(buf[pos..], "Esc");
            pos += style.unbold(buf[pos..]);
            pos += cp(buf[pos..], " cancel");
            pos += style.fg(buf[pos..], .default);
            row_w = 36;
        }

        // Pad to modal_w
        if (row_w < modal_w) {
            { var pad: usize = row_w; while (pad < modal_w and pos < buf.len) : (pad += 1) { buf[pos] = ' '; pos += 1; } }
        }
        pos += style.reset(buf[pos..]);
        pos += style.clearLine(buf[pos..]); // clear any scrollbar artifacts
    }

    // Show cursor at active field
    if (cursor_row > 0) {
        pos += style.showCursor(buf[pos..]);
        pos += style.moveTo(buf[pos..], cursor_row, cursor_col);
    }

    tty.writeAll(buf[0..pos]) catch {};
}

fn matchesFilter(sec: *const secrets_mod.Secret, filter_str: []const u8) bool {
    if (filter_str.len == 0) return true;
    // Case-insensitive substring match on name and description
    const name = sec.nameSlice();
    const desc = sec.descSlice();
    return findCaseInsensitive(name, filter_str) != null or
        findCaseInsensitive(desc, filter_str) != null;
}

fn findCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    const limit = haystack.len - needle.len + 1;
    for (0..limit) |i| {
        var matched = true;
        for (0..needle.len) |j| {
            const a = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z') haystack[i + j] + 32 else haystack[i + j];
            const b = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (a != b) { matched = false; break; }
        }
        if (matched) return i;
    }
    return null;
}

fn filteredCountSearch(store: *const secrets_mod.SecretsStore, local_only: bool, cwd: []const u8, filter_str: []const u8) usize {
    var n: usize = 0;
    for (0..store.count) |i| {
        const sec = &store.secrets[i];
        if (local_only and (sec.kind != .local or !std.mem.eql(u8, sec.dirSlice(), cwd))) continue;
        if (!matchesFilter(sec, filter_str)) continue;
        n += 1;
    }
    return n;
}

fn resolveIndexSearch(store: *const secrets_mod.SecretsStore, visual_idx: usize, local_only: bool, cwd: []const u8, filter_str: []const u8) ?usize {
    var n: usize = 0;
    for (0..store.count) |i| {
        const sec = &store.secrets[i];
        if (local_only and (sec.kind != .local or !std.mem.eql(u8, sec.dirSlice(), cwd))) continue;
        if (!matchesFilter(sec, filter_str)) continue;
        if (n == visual_idx) return i;
        n += 1;
    }
    return null;
}

const TermSize = struct { rows: usize, cols: usize };
fn visibleRows(ts: TermSize) usize { return if (ts.rows > 5) ts.rows - 5 else 1; }

fn renderTui(tty: std.fs.File, store: *const secrets_mod.SecretsStore, cursor: usize, scroll: usize, show_values: bool, local_only: bool, cwd: []const u8, ts: TermSize, searching: bool, filter_str: []const u8) void {
    var buf: [32768]u8 = undefined;
    var pos: usize = 0;
    const cols = ts.cols;
    const rows = ts.rows;

    const total = filteredCountSearch(store, local_only, cwd, filter_str);

    pos += style.hideCursor(buf[pos..]);
    pos += style.home(buf[pos..]);

    // ── Title bar ──
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], "  Secrets");
    if (local_only) pos += cp(buf[pos..], " (local)");
    const tw: usize = if (local_only) 18 else 9;
    var cnt_buf: [32]u8 = undefined;
    const cnt_str = std.fmt.bufPrint(&cnt_buf, "{d} entries", .{total}) catch "";
    const cnt_pad = if (cols > tw + cnt_str.len + 4) cols - tw - cnt_str.len - 4 else 1;
    { var p: usize = 0; while (p < cnt_pad and pos < buf.len) : (p += 1) { buf[pos] = ' '; pos += 1; } }
    pos += cp(buf[pos..], cnt_str);
    pos += cp(buf[pos..], "  ");
    pos += style.reset(buf[pos..]);
    pos += style.clearLine(buf[pos..]);
    pos += style.crlf(buf[pos..]);

    // ── Search bar (when active or has filter) ──
    if (searching or filter_str.len > 0) {
        pos += cp(buf[pos..], "  ");
        pos += style.colored(buf[pos..], .yellow, "/ ");
        if (filter_str.len > 0) {
            pos += style.boldText(buf[pos..], filter_str);
        } else {
            pos += style.dimText(buf[pos..], "search...");
        }
        pos += style.clearLine(buf[pos..]);
        pos += style.crlf(buf[pos..]);
    }

    // ── Separator ──
    pos += style.dim(buf[pos..]);
    pos += style.hline(buf[pos..], cols);
    pos += style.reset(buf[pos..]);
    pos += style.crlf(buf[pos..]);

    // ── Entries ──
    const max_vis = visibleRows(ts);
    const vis_end = @min(scroll + max_vis, total);

    if (total == 0) {
        const empty_row = if (rows > 6) rows / 2 - 1 else 3;
        { var er: usize = 2; while (er < empty_row and pos < buf.len - 40) : (er += 1) {
            pos += style.clearLine(buf[pos..]);
            pos += style.crlf(buf[pos..]);
        }}
        // Centered empty state
        const line1 = "No secrets stored";
        const line2_pre = "Press ";
        const line2_key = "a";
        const line2_post = " to add your first secret";
        const l1_pad = if (cols > line1.len) (cols - line1.len) / 2 else 0;
        { var pl: usize = 0; while (pl < l1_pad and pos < buf.len) : (pl += 1) { buf[pos] = ' '; pos += 1; } }
        pos += style.dimText(buf[pos..], line1);
        pos += style.clearLine(buf[pos..]);
        pos += style.crlf(buf[pos..]);
        pos += style.clearLine(buf[pos..]);
        pos += style.crlf(buf[pos..]);
        const l2_total = line2_pre.len + line2_key.len + line2_post.len;
        const l2_pad = if (cols > l2_total) (cols - l2_total) / 2 else 0;
        { var pl: usize = 0; while (pl < l2_pad and pos < buf.len) : (pl += 1) { buf[pos] = ' '; pos += 1; } }
        pos += style.dim(buf[pos..]);
        pos += cp(buf[pos..], line2_pre);
        pos += style.reset(buf[pos..]);
        pos += style.boldColored(buf[pos..], .cyan, line2_key);
        pos += style.dim(buf[pos..]);
        pos += cp(buf[pos..], line2_post);
        pos += style.reset(buf[pos..]);
        pos += style.clearLine(buf[pos..]);
        pos += style.crlf(buf[pos..]);
    } else {
        var vi: usize = 0;
        for (0..store.count) |i| {
            const sec = &store.secrets[i];
            if (local_only and (sec.kind != .local or !std.mem.eql(u8, sec.dirSlice(), cwd))) continue;
            if (!matchesFilter(sec, filter_str)) continue;
            if (vi < scroll) { vi += 1; continue; }
            if (vi >= vis_end) break;
            const is_sel = vi == cursor;

            // Selection arrow
            if (is_sel) {
                pos += style.colored(buf[pos..], .cyan, " > ");
            } else {
                pos += cp(buf[pos..], "   ");
            }

            // Kind badge (colored bullet)
            switch (sec.kind) {
                .env => pos += style.colored(buf[pos..], .green, style.box.bullet),
                .local => pos += style.colored(buf[pos..], .blue, style.box.bullet),
                .password => pos += style.colored(buf[pos..], .yellow, style.box.bullet),
            }
            pos += cp(buf[pos..], " ");

            // Name
            const name = sec.nameSlice();
            const max_name: usize = 24;
            const name_disp = @min(name.len, max_name);
            if (is_sel) pos += style.bold(buf[pos..]);
            pos += cp(buf[pos..], name[0..name_disp]);
            pos += style.reset(buf[pos..]);

            // Value (masked or shown)
            const val = sec.valueSlice();
            if (val.len > 0) {
                pos += cp(buf[pos..], "  ");
                if (show_values) {
                    pos += style.dim(buf[pos..]);
                    const nd_w: usize = name_disp;
                    const max_val = if (cols > nd_w + 40) cols - nd_w - 40 else 16;
                    const val_disp = @min(val.len, max_val);
                    pos += cp(buf[pos..], val[0..val_disp]);
                    if (val.len > max_val) pos += cp(buf[pos..], style.box.ellipsis);
                    pos += style.reset(buf[pos..]);
                } else {
                    // Masked dots
                    pos += style.dimText(buf[pos..], "\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2");
                }
            }

            // Description (right-aligned)
            const desc = sec.descSlice();
            if (desc.len > 0) {
                const used_w = 6 + name_disp + if (val.len > 0) @as(usize, if (show_values) @min(val.len, 20) + 4 else 12) else @as(usize, 0);
                if (cols > used_w + desc.len + 2) {
                    const gap = cols - used_w - desc.len - 2;
                    { var g: usize = 0; while (g < gap and pos < buf.len) : (g += 1) { buf[pos] = ' '; pos += 1; } }
                } else {
                    pos += cp(buf[pos..], "  ");
                }
                pos += style.dimText(buf[pos..], desc);
            }

            pos += style.clearLine(buf[pos..]);
            pos += style.crlf(buf[pos..]);

            // Detail line for selected: kind label + directory
            if (is_sel) {
                pos += cp(buf[pos..], "     ");
                pos += style.dim(buf[pos..]);
                switch (sec.kind) {
                    .env => pos += cp(buf[pos..], "env"),
                    .local => {
                        pos += cp(buf[pos..], "local ");
                        pos += style.fg(buf[pos..], .cyan);
                        const dir = sec.dirSlice();
                        pos += cp(buf[pos..], dir[0..@min(dir.len, if (cols > 20) cols - 20 else cols)]);
                    },
                    .password => pos += cp(buf[pos..], "password"),
                }
                pos += style.reset(buf[pos..]);
                pos += style.clearLine(buf[pos..]);
                pos += style.crlf(buf[pos..]);
            }

            vi += 1;
        }
    }

    // Pad remaining
    const detail_line: usize = if (total > 0) 1 else 0;
    const used_rows = 2 + (vis_end - scroll) + detail_line;
    { var r: usize = used_rows; while (r + 2 < rows and pos < buf.len - 10) : (r += 1) {
        pos += style.clearLine(buf[pos..]);
        pos += style.crlf(buf[pos..]);
    }}

    // ── Scrollbar ──
    if (total > max_vis and max_vis > 2) {
        const bar_h = @max(1, max_vis * max_vis / total);
        const bar_pos = if (total > max_vis) scroll * (max_vis - bar_h) / (total - max_vis) else 0;
        for (0..max_vis) |ri| {
            pos += style.moveTo(buf[pos..], 3 + ri, cols);
            pos += style.dimText(buf[pos..], if (ri >= bar_pos and ri < bar_pos + bar_h) style.box.scrollbar_thumb else style.box.scrollbar_track);
        }
    }

    // ── Status bar ──
    pos += style.moveTo(buf[pos..], rows, 1);
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], "  ");
    pos += style.bold(buf[pos..]);
    pos += cp(buf[pos..], "q");
    pos += style.unbold(buf[pos..]);
    pos += cp(buf[pos..], " quit  ");
    pos += style.bold(buf[pos..]);
    pos += cp(buf[pos..], "/");
    pos += style.unbold(buf[pos..]);
    pos += cp(buf[pos..], " search  ");
    pos += style.bold(buf[pos..]);
    pos += cp(buf[pos..], "a");
    pos += style.unbold(buf[pos..]);
    pos += cp(buf[pos..], " add  ");
    pos += style.bold(buf[pos..]);
    pos += cp(buf[pos..], "e");
    pos += style.unbold(buf[pos..]);
    pos += cp(buf[pos..], " edit  ");
    pos += style.bold(buf[pos..]);
    pos += cp(buf[pos..], "v");
    pos += style.unbold(buf[pos..]);
    pos += cp(buf[pos..], " ");
    pos += cp(buf[pos..], if (show_values) "hide" else "show");
    pos += cp(buf[pos..], "  ");
    pos += style.bold(buf[pos..]);
    pos += cp(buf[pos..], "x");
    pos += style.unbold(buf[pos..]);
    pos += cp(buf[pos..], " delete");
    pos += style.reset(buf[pos..]);
    pos += style.clearLine(buf[pos..]);

    // Show cursor only when searching, positioned in search bar
    if (searching) {
        const search_row: usize = 2; // search bar is row 2 (after title)
        const search_col = 5 + filter_str.len; // "  / " = 4 chars + filter
        pos += style.showCursor(buf[pos..]);
        pos += style.moveTo(buf[pos..], search_row, search_col);
    }

    tty.writeAll(buf[0..pos]) catch {};
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getTermSize(fd: posix.fd_t) TermSize {
    const ts = style.getTermSize(fd);
    return .{ .rows = ts.rows, .cols = ts.cols };
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}
