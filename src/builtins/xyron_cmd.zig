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
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) return runHelp(stdout);
    if (std.mem.eql(u8, args[0], "secrets")) {
        const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
        return runSecrets(sub_args, stdout, stderr);
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
    var ts = getTermSize(tty_fd);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch ".";

    renderTui(tty, &store, cursor, scroll, show_values, local_only, cwd, ts);

    while (true) {
        var key_buf: [1]u8 = undefined;
        const rc = c.read(tty_fd, &key_buf, 1);
        if (rc == -1) { ts = getTermSize(tty_fd); renderTui(tty, &store, cursor, scroll, show_values, local_only, cwd, ts); continue; }
        if (rc <= 0) break;
        const vis = visibleRows(ts);
        const total = filteredCount(&store, local_only, cwd);

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
            'v' => show_values = !show_values,
            'a' => { // Add new secret
                const kind: secrets_mod.SecretKind = if (local_only) .local else .env;
                if (addSecretModal(tty, tty_fd, &store, kind, if (local_only) cwd else "", ts)) {
                    store.save() catch {};
                }
            },
            'e' => { // Edit selected secret
                if (resolveIndex(&store, cursor, local_only, cwd)) |real_idx| {
                    if (editSecretModal(tty, tty_fd, &store, real_idx, ts)) {
                        store.save() catch {};
                    }
                }
            },
            'x' => {
                if (resolveIndex(&store, cursor, local_only, cwd)) |real_idx| {
                    store.remove(real_idx);
                    if (cursor > 0 and cursor >= filteredCount(&store, local_only, cwd)) cursor -= 1;
                    store.save() catch {};
                }
            },
            16 => { if (cursor > 0) cursor -= 1; if (cursor < scroll) scroll = cursor; },
            14 => { if (total > 0 and cursor + 1 < total) cursor += 1; if (cursor >= scroll + vis) scroll = cursor - vis + 1; },
            else => {},
        }
        renderTui(tty, &store, cursor, scroll, show_values, local_only, cwd, ts);
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
        var kb: [1]u8 = undefined;
        const rc = c.read(tty_fd, &kb, 1);
        if (rc <= 0) return false;
        switch (kb[0]) {
            27 => { // Esc or arrows
                var seq: [2]u8 = undefined;
                const rc2 = c.read(tty_fd, &seq, 2);
                if (rc2 == 2 and seq[0] == '[') {
                    switch (seq[1]) {
                        'A' => active = if (@intFromEnum(active) > 0) @enumFromInt(@intFromEnum(active) - 1) else active,
                        'B' => active = if (@intFromEnum(active) < 2) @enumFromInt(@intFromEnum(active) + 1) else active,
                        else => {},
                    }
                } else if (rc2 <= 0) return false; // plain Esc = cancel
            },
            3 => return false, // Ctrl+C
            9 => active = if (@intFromEnum(active) < 2) @enumFromInt(@intFromEnum(active) + 1) else .name, // Tab
            10, 13 => { // Enter — submit
                if (lens[0] == 0) continue; // name required
                return store.add(
                    fields[0][0..lens[0]],
                    fields[1][0..lens[1]],
                    fields[2][0..lens[2]],
                    dir,
                    kind,
                );
            },
            127, 8 => { // Backspace
                const ai = @intFromEnum(active);
                if (lens[ai] > 0) lens[ai] -= 1;
            },
            else => |ch| {
                if (ch >= 32 and ch < 127) {
                    const ai = @intFromEnum(active);
                    if (lens[ai] < 127) {
                        fields[ai][lens[ai]] = ch;
                        lens[ai] += 1;
                    }
                }
            },
        }
    }
}

fn editSecretModal(tty: std.fs.File, tty_fd: posix.fd_t, store: *secrets_mod.SecretsStore, idx: usize, ts: TermSize) bool {
    if (idx >= store.count) return false;
    const s = &store.secrets[idx];

    var fields: [3][128]u8 = undefined;
    var lens: [3]usize = undefined;
    const labels = [3][]const u8{ "Name", "Value", "Description" };

    // Pre-fill
    @memcpy(fields[0][0..s.name_len], s.name[0..s.name_len]);
    lens[0] = s.name_len;
    const vl = @min(s.value_len, 128);
    @memcpy(fields[1][0..vl], s.value[0..vl]);
    lens[1] = vl;
    const dl = @min(s.desc_len, 128);
    @memcpy(fields[2][0..dl], s.description[0..dl]);
    lens[2] = dl;

    var active: FieldIdx = .value; // start on value for editing

    while (true) {
        renderModal(tty, "Edit Secret", &labels, &fields, &lens, active, ts);
        var kb: [1]u8 = undefined;
        const rc = c.read(tty_fd, &kb, 1);
        if (rc <= 0) return false;
        switch (kb[0]) {
            27 => {
                var seq: [2]u8 = undefined;
                const rc2 = c.read(tty_fd, &seq, 2);
                if (rc2 == 2 and seq[0] == '[') {
                    switch (seq[1]) {
                        'A' => active = if (@intFromEnum(active) > 0) @enumFromInt(@intFromEnum(active) - 1) else active,
                        'B' => active = if (@intFromEnum(active) < 2) @enumFromInt(@intFromEnum(active) + 1) else active,
                        else => {},
                    }
                } else if (rc2 <= 0) return false;
            },
            3 => return false,
            9 => active = if (@intFromEnum(active) < 2) @enumFromInt(@intFromEnum(active) + 1) else .name,
            10, 13 => { // Enter — save
                if (lens[0] == 0) continue;
                // Update in place
                secrets_mod.SecretsStore.setFieldPub(&s.name, &s.name_len, fields[0][0..lens[0]]);
                secrets_mod.SecretsStore.setFieldPub(&s.value, &s.value_len, fields[1][0..lens[1]]);
                secrets_mod.SecretsStore.setFieldPub(&s.description, &s.desc_len, fields[2][0..lens[2]]);
                store.modified = true;
                return true;
            },
            127, 8 => {
                const ai = @intFromEnum(active);
                if (lens[ai] > 0) lens[ai] -= 1;
            },
            else => |ch| {
                if (ch >= 32 and ch < 127) {
                    const ai = @intFromEnum(active);
                    if (lens[ai] < 127) {
                        fields[ai][lens[ai]] = ch;
                        lens[ai] += 1;
                    }
                }
            },
        }
    }
}

fn renderModal(tty: std.fs.File, title: []const u8, labels: *const [3][]const u8, fields: *const [3][128]u8, lens: *const [3]usize, active: FieldIdx, ts: TermSize) void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const modal_w: usize = 50;
    const modal_h: usize = 9;
    const start_row = if (ts.rows > modal_h + 2) (ts.rows - modal_h) / 2 else 1;
    const start_col = if (ts.cols > modal_w + 2) (ts.cols - modal_w) / 2 else 1;

    // Top border
    pos += style.moveTo(buf[pos..], start_row, start_col);
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], style.box.top_left);
    pos += style.hline(buf[pos..], modal_w - 2);
    pos += cp(buf[pos..], style.box.top_right);
    pos += style.reset(buf[pos..]);

    // Title row
    pos += style.moveTo(buf[pos..], start_row + 1, start_col);
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], style.box.vertical);
    pos += style.reset(buf[pos..]);
    pos += cp(buf[pos..], " ");
    pos += style.boldText(buf[pos..], title);
    { var pad: usize = title.len + 1; while (pad < modal_w - 2 and pos < buf.len) : (pad += 1) { buf[pos] = ' '; pos += 1; } }
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], style.box.vertical);
    pos += style.reset(buf[pos..]);

    // Separator
    pos += style.moveTo(buf[pos..], start_row + 2, start_col);
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], style.box.t_left);
    pos += style.hline(buf[pos..], modal_w - 2);
    pos += cp(buf[pos..], style.box.t_right);
    pos += style.reset(buf[pos..]);

    // Fields
    for (0..3) |fi| {
        const row = start_row + 3 + fi;
        pos += style.moveTo(buf[pos..], row, start_col);
        const is_active = @intFromEnum(active) == fi;

        pos += style.dim(buf[pos..]);
        pos += cp(buf[pos..], style.box.vertical);
        pos += style.reset(buf[pos..]);
        pos += cp(buf[pos..], " ");
        if (is_active) pos += style.fg(buf[pos..], .cyan);
        pos += cp(buf[pos..], labels[fi]);
        pos += cp(buf[pos..], ": ");
        if (is_active) { pos += style.reset(buf[pos..]); pos += style.bold(buf[pos..]); }
        const val = fields[fi][0..lens[fi]];
        const max_val = modal_w - labels[fi].len - 6;
        const disp = @min(val.len, max_val);
        pos += cp(buf[pos..], val[0..disp]);
        if (is_active and val.len == 0) { pos += style.dim(buf[pos..]); pos += cp(buf[pos..], "_"); pos += style.unbold(buf[pos..]); }
        pos += style.reset(buf[pos..]);
        // Pad
        { var pad: usize = labels[fi].len + 2 + disp + @as(usize, if (is_active and val.len == 0) 1 else 0);
          while (pad < modal_w - 2 and pos < buf.len) : (pad += 1) { buf[pos] = ' '; pos += 1; } }
        pos += style.dim(buf[pos..]);
        pos += cp(buf[pos..], style.box.vertical);
        pos += style.reset(buf[pos..]);
    }

    // Empty row
    pos += style.moveTo(buf[pos..], start_row + 6, start_col);
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], style.box.vertical);
    pos += style.reset(buf[pos..]);
    { var pad: usize = 0; while (pad < modal_w - 2 and pos < buf.len) : (pad += 1) { buf[pos] = ' '; pos += 1; } }
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], style.box.vertical);
    pos += style.reset(buf[pos..]);

    // Help row
    pos += style.moveTo(buf[pos..], start_row + 7, start_col);
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], style.box.vertical);
    pos += cp(buf[pos..], " Tab next  Enter save  Esc cancel");
    { var pad: usize = 38; while (pad < modal_w - 2 and pos < buf.len) : (pad += 1) { buf[pos] = ' '; pos += 1; } }
    pos += cp(buf[pos..], style.box.vertical);
    pos += style.reset(buf[pos..]);

    // Bottom border
    pos += style.moveTo(buf[pos..], start_row + 8, start_col);
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], style.box.bottom_left);
    pos += style.hline(buf[pos..], modal_w - 2);
    pos += cp(buf[pos..], style.box.bottom_right);
    pos += style.reset(buf[pos..]);

    tty.writeAll(buf[0..pos]) catch {};
}

fn filteredCount(store: *const secrets_mod.SecretsStore, local_only: bool, cwd: []const u8) usize {
    if (!local_only) return store.count;
    var n: usize = 0;
    for (0..store.count) |i| {
        if (store.secrets[i].kind == .local and std.mem.eql(u8, store.secrets[i].dirSlice(), cwd)) n += 1;
    }
    return n;
}

fn resolveIndex(store: *const secrets_mod.SecretsStore, visual_idx: usize, local_only: bool, cwd: []const u8) ?usize {
    if (!local_only) return if (visual_idx < store.count) visual_idx else null;
    var n: usize = 0;
    for (0..store.count) |i| {
        if (store.secrets[i].kind == .local and std.mem.eql(u8, store.secrets[i].dirSlice(), cwd)) {
            if (n == visual_idx) return i;
            n += 1;
        }
    }
    return null;
}

const TermSize = struct { rows: usize, cols: usize };
fn visibleRows(ts: TermSize) usize { return if (ts.rows > 5) ts.rows - 5 else 1; }

fn renderTui(tty: std.fs.File, store: *const secrets_mod.SecretsStore, cursor: usize, scroll: usize, show_values: bool, local_only: bool, cwd: []const u8, ts: TermSize) void {
    var buf: [32768]u8 = undefined;
    var pos: usize = 0;
    const cols = ts.cols;
    const rows = ts.rows;

    pos += style.home(buf[pos..]);

    // Title
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], "  Secrets");
    if (local_only) pos += cp(buf[pos..], " (local)");
    const total = filteredCount(store, local_only, cwd);
    var cnt_buf: [32]u8 = undefined;
    const cnt_str = std.fmt.bufPrint(&cnt_buf, "{d} entries", .{total}) catch "";
    const tw: usize = if (local_only) 18 else 9;
    const cnt_pad = if (cols > tw + cnt_str.len + 4) cols - tw - cnt_str.len - 4 else 1;
    { var p: usize = 0; while (p < cnt_pad and pos < buf.len) : (p += 1) { buf[pos] = ' '; pos += 1; } }
    pos += cp(buf[pos..], cnt_str);
    pos += cp(buf[pos..], "  ");
    pos += style.reset(buf[pos..]);
    pos += style.clearLine(buf[pos..]);
    pos += style.crlf(buf[pos..]);

    // Column header
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], "  KIND   NAME                 ");
    if (show_values) pos += cp(buf[pos..], "VALUE                    ");
    pos += cp(buf[pos..], "DESCRIPTION");
    pos += style.reset(buf[pos..]);
    pos += style.clearLine(buf[pos..]);
    pos += style.crlf(buf[pos..]);

    // Separator
    pos += style.dim(buf[pos..]);
    pos += style.hline(buf[pos..], cols);
    pos += style.reset(buf[pos..]);
    pos += style.crlf(buf[pos..]);

    // Entries
    const max_vis = visibleRows(ts);
    const vis_end = @min(scroll + max_vis, total);
    var vi: usize = 0;
    for (0..store.count) |i| {
        const s = &store.secrets[i];
        if (local_only and (s.kind != .local or !std.mem.eql(u8, s.dirSlice(), cwd))) continue;
        if (vi < scroll) { vi += 1; continue; }
        if (vi >= vis_end) break;
        const is_sel = vi == cursor;

        if (is_sel) { pos += style.colored(buf[pos..], .cyan, " > "); } else pos += cp(buf[pos..], "   ");
        switch (s.kind) {
            .env => { pos += style.colored(buf[pos..], .green, "env "); pos += cp(buf[pos..], "  "); },
            .local => { pos += style.colored(buf[pos..], .blue, "local"); pos += cp(buf[pos..], "  "); },
            .password => { pos += style.colored(buf[pos..], .yellow, "pass "); pos += cp(buf[pos..], "  "); },
        }
        if (is_sel) pos += style.bold(buf[pos..]);
        const name = s.nameSlice();
        const nd = @min(name.len, 20);
        pos += cp(buf[pos..], name[0..nd]);
        { var pad: usize = nd; while (pad < 21 and pos < buf.len) : (pad += 1) { buf[pos] = ' '; pos += 1; } }
        if (is_sel) pos += style.reset(buf[pos..]);
        if (show_values) {
            const val = s.valueSlice();
            const vd = @min(val.len, 24);
            pos += cp(buf[pos..], val[0..vd]);
            { var pad: usize = vd; while (pad < 25 and pos < buf.len) : (pad += 1) { buf[pos] = ' '; pos += 1; } }
        }
        pos += style.dim(buf[pos..]);
        pos += cp(buf[pos..], s.descSlice());
        pos += style.reset(buf[pos..]);
        pos += style.clearLine(buf[pos..]);
        pos += style.crlf(buf[pos..]);
        vi += 1;
    }

    // Pad
    const used = 3 + (vis_end - scroll);
    { var r: usize = used; while (r + 2 < rows and pos < buf.len - 10) : (r += 1) { pos += style.clearLine(buf[pos..]); pos += style.crlf(buf[pos..]); } }

    // Status bar
    pos += style.moveTo(buf[pos..], rows, 1);
    pos += style.dim(buf[pos..]);
    pos += cp(buf[pos..], "  ");
    pos += style.unbold(buf[pos..]);
    pos += style.bold(buf[pos..]);
    pos += cp(buf[pos..], "q");
    pos += style.unbold(buf[pos..]);
    pos += cp(buf[pos..], " quit  ");
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

    tty.writeAll(buf[0..pos]) catch {};
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getTermSize(fd: posix.fd_t) TermSize {
    const ext = struct {
        const winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    };
    var ws: ext.winsize = undefined;
    if (ext.ioctl(fd, 0x40087468, &ws) == 0) {
        return .{ .rows = if (ws.ws_row > 0) ws.ws_row else 24, .cols = if (ws.ws_col > 0) ws.ws_col else 80 };
    }
    return .{ .rows = 24, .cols = 80 };
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}
