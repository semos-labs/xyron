// builtins/secrets_init.zig — Secrets init wizard.
//
// Guides user through GPG key setup and secrets file creation.

const std = @import("std");
const posix = std.posix;
const secrets_mod = @import("../secrets.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(stdout: std.fs.File, stderr: std.fs.File) Result {
    const alloc = std.heap.page_allocator;
    var store = secrets_mod.SecretsStore.init();

    // Already initialized?
    if (store.isInitialized()) {
        stdout.writeAll("\x1b[2m── Secrets already initialized ──\x1b[0m\n\n") catch {};
        stdout.writeAll("  Key:  \x1b[1m") catch {};
        stdout.writeAll(store.keyId()) catch {};
        stdout.writeAll("\x1b[0m\n") catch {};
        stdout.writeAll("  File: \x1b[2m") catch {};
        stdout.writeAll(store.filePath()) catch {};
        stdout.writeAll("\x1b[0m\n\n") catch {};
        stdout.writeAll("Run \x1b[1mxyron secrets open\x1b[0m to manage secrets.\n") catch {};
        return .{};
    }

    // Step 1: check GPG
    stdout.writeAll("\n\x1b[1m  Xyron Secrets Setup\x1b[0m\n\n") catch {};
    stdout.writeAll("  Secrets are encrypted with GPG. Let's get you set up.\n\n") catch {};
    stdout.writeAll("  \x1b[2mStep 1/3\x1b[0m  Checking GPG...\n") catch {};

    if (!gpgAvailable(alloc)) {
        stderr.writeAll("\n  \x1b[31mGPG is not installed.\x1b[0m\n") catch {};
        stderr.writeAll("  Install it with: \x1b[1mbrew install gnupg\x1b[0m (macOS)\n") catch {};
        stderr.writeAll("                   \x1b[1msudo apt install gpg\x1b[0m (Ubuntu/Debian)\n\n") catch {};
        return .{ .exit_code = 1 };
    }
    stdout.writeAll("           \x1b[32mGPG found.\x1b[0m\n\n") catch {};

    // Step 2: find or create a key
    stdout.writeAll("  \x1b[2mStep 2/3\x1b[0m  GPG key\n\n") catch {};

    const has_keys = gpgHasKeys(alloc);
    const tty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_only }) catch return .{ .exit_code = 1 };
    defer tty.close();

    var key_id_buf: [128]u8 = undefined;
    var key_id_len: usize = 0;

    if (has_keys) {
        stdout.writeAll("  You have existing GPG keys:\n\n") catch {};
        listGpgKeys(stdout, alloc);

        stdout.writeAll("\n  Enter key ID, email, or \x1b[1mn\x1b[0m to create a new one: ") catch {};

        var input: [256]u8 = undefined;
        const n = tty.read(&input) catch return .{ .exit_code = 1 };
        const answer = std.mem.trimRight(u8, input[0..n], "\n\r ");

        if (answer.len == 0) {
            stdout.writeAll("  Cancelled.\n") catch {};
            return .{};
        }

        if (std.mem.eql(u8, answer, "n") or std.mem.eql(u8, answer, "N")) {
            if (!createGpgKey(stdout, stderr, tty, alloc)) return .{ .exit_code = 1 };
            key_id_len = getLastGpgKeyId(alloc, &key_id_buf);
            if (key_id_len == 0) {
                stderr.writeAll("\n  \x1b[31mFailed to find newly created key.\x1b[0m\n") catch {};
                return .{ .exit_code = 1 };
            }
        } else {
            const kl = @min(answer.len, key_id_buf.len);
            @memcpy(key_id_buf[0..kl], answer[0..kl]);
            key_id_len = kl;
        }
    } else {
        stdout.writeAll("  No GPG keys found. Let's create one.\n\n") catch {};
        if (!createGpgKey(stdout, stderr, tty, alloc)) return .{ .exit_code = 1 };
        key_id_len = getLastGpgKeyId(alloc, &key_id_buf);
        if (key_id_len == 0) {
            stderr.writeAll("\n  \x1b[31mFailed to find newly created key.\x1b[0m\n") catch {};
            return .{ .exit_code = 1 };
        }
    }

    stdout.writeAll("\n") catch {};

    // Step 3: create the secrets file
    stdout.writeAll("  \x1b[2mStep 3/3\x1b[0m  Creating encrypted vault...\n") catch {};

    @memcpy(store.key_id[0..key_id_len], key_id_buf[0..key_id_len]);
    store.key_id_len = key_id_len;
    store.saveKeyId();

    store.save() catch {
        stderr.writeAll("           \x1b[31mFailed to create secrets file.\x1b[0m\n") catch {};
        return .{ .exit_code = 1 };
    };

    stdout.writeAll("           \x1b[32mDone!\x1b[0m\n\n") catch {};
    stdout.writeAll("  \x1b[2mKey:\x1b[0m  ") catch {};
    stdout.writeAll(key_id_buf[0..key_id_len]) catch {};
    stdout.writeAll("\n  \x1b[2mFile:\x1b[0m ") catch {};
    stdout.writeAll(store.filePath()) catch {};
    stdout.writeAll("\n\n") catch {};
    stdout.writeAll("  Add your first secret:\n") catch {};
    stdout.writeAll("    \x1b[1mxyron secrets add API_KEY sk-xxx --description \"OpenAI key\"\x1b[0m\n\n") catch {};
    stdout.writeAll("  Or browse with:\n") catch {};
    stdout.writeAll("    \x1b[1mxyron secrets open\x1b[0m\n\n") catch {};

    return .{};
}

// ---------------------------------------------------------------------------
// GPG helpers
// ---------------------------------------------------------------------------

fn gpgAvailable(alloc: std.mem.Allocator) bool {
    var child = std.process.Child.init(&.{ "gpg", "--version" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) { .Exited => |cc| cc == 0, else => false };
}

fn gpgHasKeys(alloc: std.mem.Allocator) bool {
    var child = std.process.Child.init(&.{ "gpg", "--list-keys", "--with-colons" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |f| {
        while (total < buf.len) {
            const n = f.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    _ = child.wait() catch {};
    return std.mem.indexOf(u8, buf[0..total], "pub:") != null;
}

fn listGpgKeys(stdout: std.fs.File, alloc: std.mem.Allocator) void {
    var child = std.process.Child.init(
        &.{ "gpg", "--list-keys", "--keyid-format", "long", "--with-colons" },
        alloc,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;

    var out_buf: [8192]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |f| {
        while (total < out_buf.len) {
            const rn = f.read(out_buf[total..]) catch break;
            if (rn == 0) break;
            total += rn;
        }
    }
    _ = child.wait() catch {};

    var line_iter = std.mem.splitScalar(u8, out_buf[0..total], '\n');
    var idx: usize = 1;
    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "uid:")) {
            var field_iter = std.mem.splitScalar(u8, line, ':');
            var fi: usize = 0;
            while (field_iter.next()) |field| : (fi += 1) {
                if (fi == 9 and field.len > 0) {
                    var nbuf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&nbuf, "    \x1b[33m{d}.\x1b[0m {s}\n", .{ idx, field }) catch "";
                    stdout.writeAll(msg) catch {};
                    idx += 1;
                }
            }
        }
    }
}

fn createGpgKey(stdout: std.fs.File, stderr: std.fs.File, tty: std.fs.File, alloc: std.mem.Allocator) bool {
    stdout.writeAll("  Enter your name: ") catch {};
    var name_buf: [128]u8 = undefined;
    const name_n = tty.read(&name_buf) catch return false;
    const name = std.mem.trimRight(u8, name_buf[0..name_n], "\n\r ");
    if (name.len == 0) { stderr.writeAll("  Name required.\n") catch {}; return false; }

    stdout.writeAll("  Enter your email: ") catch {};
    var email_buf: [128]u8 = undefined;
    const email_n = tty.read(&email_buf) catch return false;
    const email = std.mem.trimRight(u8, email_buf[0..email_n], "\n\r ");
    if (email.len == 0) { stderr.writeAll("  Email required.\n") catch {}; return false; }

    stdout.writeAll("\n  \x1b[2mGenerating key (this may take a moment)...\x1b[0m\n") catch {};

    var batch_buf: [512]u8 = undefined;
    const batch = std.fmt.bufPrint(&batch_buf,
        "Key-Type: eddsa\nKey-Curve: ed25519\nSubkey-Type: ecdh\nSubkey-Curve: cv25519\n" ++
        "Name-Real: {s}\nName-Email: {s}\nExpire-Date: 0\n%no-protection\n%commit\n",
        .{ name, email },
    ) catch return false;

    var child = std.process.Child.init(&.{ "gpg", "--batch", "--gen-key" }, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        stderr.writeAll("  \x1b[31mFailed to start gpg.\x1b[0m\n") catch {};
        return false;
    };

    if (child.stdin) |stdin| {
        stdin.writeAll(batch) catch {};
        stdin.close();
        child.stdin = null;
    }

    const term = child.wait() catch return false;
    if (switch (term) { .Exited => |cc| cc, else => 1 } != 0) {
        stderr.writeAll("  \x1b[31mKey generation failed.\x1b[0m\n") catch {};
        return false;
    }

    stdout.writeAll("  \x1b[32mKey created!\x1b[0m\n") catch {};
    return true;
}

fn getLastGpgKeyId(alloc: std.mem.Allocator, out: *[128]u8) usize {
    var child = std.process.Child.init(
        &.{ "gpg", "--list-keys", "--with-colons", "--keyid-format", "long" },
        alloc,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |f| {
        while (total < buf.len) {
            const n = f.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    _ = child.wait() catch {};

    var last_uid: []const u8 = "";
    var line_iter = std.mem.splitScalar(u8, buf[0..total], '\n');
    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "uid:")) {
            var field_iter = std.mem.splitScalar(u8, line, ':');
            var fi: usize = 0;
            while (field_iter.next()) |field| : (fi += 1) {
                if (fi == 9) last_uid = field;
            }
        }
    }

    // Extract email from "Name <email>"
    if (std.mem.indexOf(u8, last_uid, "<")) |start| {
        if (std.mem.indexOf(u8, last_uid[start..], ">")) |end| {
            const email = last_uid[start + 1 .. start + end];
            const n = @min(email.len, out.len);
            @memcpy(out[0..n], email[0..n]);
            return n;
        }
    }

    const n = @min(last_uid.len, out.len);
    if (n > 0) @memcpy(out[0..n], last_uid[0..n]);
    return n;
}
