// builtins/secrets_init.zig — Secrets init wizard.
//
// Guides user through GPG key setup and secrets file creation.

const std = @import("std");
const posix = std.posix;
const secrets_mod = @import("../secrets.zig");
const style = @import("../style.zig");
const Result = @import("mod.zig").BuiltinResult;

/// Local copy helper — same as style.zig's internal cp.
fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

pub fn run(stdout: std.fs.File, stderr: std.fs.File) Result {
    const alloc = std.heap.page_allocator;
    var store = secrets_mod.SecretsStore.init();

    // Already initialized?
    if (store.isInitialized()) {
        {
            var sbuf: [256]u8 = undefined;
            var sp: usize = 0;
            sp += style.dimText(&sbuf, "── Secrets already initialized ──");
            sp += cp(sbuf[sp..], "\n\n");
            stdout.writeAll(sbuf[0..sp]) catch {};
        }
        {
            var sbuf: [256]u8 = undefined;
            var sp: usize = 0;
            sp += cp(sbuf[0..], "  Key:  ");
            sp += style.boldText(sbuf[sp..], store.keyId());
            sp += cp(sbuf[sp..], "\n");
            stdout.writeAll(sbuf[0..sp]) catch {};
        }
        {
            var sbuf: [256]u8 = undefined;
            var sp: usize = 0;
            sp += cp(sbuf[0..], "  File: ");
            sp += style.dimText(sbuf[sp..], store.filePath());
            sp += cp(sbuf[sp..], "\n\n");
            stdout.writeAll(sbuf[0..sp]) catch {};
        }
        {
            var sbuf: [256]u8 = undefined;
            var sp: usize = 0;
            sp += cp(sbuf[0..], "Run ");
            sp += style.boldText(sbuf[sp..], "xyron secrets open");
            sp += cp(sbuf[sp..], " to manage secrets.\n");
            stdout.writeAll(sbuf[0..sp]) catch {};
        }
        return .{};
    }

    // Step 1: check GPG
    {
        var sbuf: [256]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "\n");
        sp += style.boldText(sbuf[sp..], "  Xyron Secrets Setup");
        sp += cp(sbuf[sp..], "\n\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }
    stdout.writeAll("  Secrets are encrypted with GPG. Let's get you set up.\n\n") catch {};
    {
        var sbuf: [128]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "  ");
        sp += style.dimText(sbuf[sp..], "Step 1/3");
        sp += cp(sbuf[sp..], "  Checking GPG...\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }

    if (!gpgAvailable(alloc)) {
        {
            var sbuf: [128]u8 = undefined;
            var sp: usize = 0;
            sp += cp(sbuf[0..], "\n  ");
            sp += style.colored(sbuf[sp..], .red, "GPG is not installed.");
            sp += cp(sbuf[sp..], "\n");
            stderr.writeAll(sbuf[0..sp]) catch {};
        }
        {
            var sbuf: [128]u8 = undefined;
            var sp: usize = 0;
            sp += cp(sbuf[0..], "  Install it with: ");
            sp += style.boldText(sbuf[sp..], "brew install gnupg");
            sp += cp(sbuf[sp..], " (macOS)\n");
            stderr.writeAll(sbuf[0..sp]) catch {};
        }
        {
            var sbuf: [128]u8 = undefined;
            var sp: usize = 0;
            sp += cp(sbuf[0..], "                   ");
            sp += style.boldText(sbuf[sp..], "sudo apt install gpg");
            sp += cp(sbuf[sp..], " (Ubuntu/Debian)\n\n");
            stderr.writeAll(sbuf[0..sp]) catch {};
        }
        return .{ .exit_code = 1 };
    }
    {
        var sbuf: [128]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "           ");
        sp += style.colored(sbuf[sp..], .green, "GPG found.");
        sp += cp(sbuf[sp..], "\n\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }

    // Step 2: find or create a key
    {
        var sbuf: [128]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "  ");
        sp += style.dimText(sbuf[sp..], "Step 2/3");
        sp += cp(sbuf[sp..], "  GPG key\n\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }

    const has_keys = gpgHasKeys(alloc);
    const tty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_only }) catch return .{ .exit_code = 1 };
    defer tty.close();

    var key_id_buf: [128]u8 = undefined;
    var key_id_len: usize = 0;

    if (has_keys) {
        stdout.writeAll("  You have existing GPG keys:\n\n") catch {};
        listGpgKeys(stdout, alloc);

        {
            var sbuf: [128]u8 = undefined;
            var sp: usize = 0;
            sp += cp(sbuf[0..], "\n  Enter key ID, email, or ");
            sp += style.boldText(sbuf[sp..], "n");
            sp += cp(sbuf[sp..], " to create a new one: ");
            stdout.writeAll(sbuf[0..sp]) catch {};
        }

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
                {
                    var sbuf: [128]u8 = undefined;
                    var sp: usize = 0;
                    sp += cp(sbuf[0..], "\n  ");
                    sp += style.colored(sbuf[sp..], .red, "Failed to find newly created key.");
                    sp += cp(sbuf[sp..], "\n");
                    stderr.writeAll(sbuf[0..sp]) catch {};
                }
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
            {
                var sbuf: [128]u8 = undefined;
                var sp: usize = 0;
                sp += cp(sbuf[0..], "\n  ");
                sp += style.colored(sbuf[sp..], .red, "Failed to find newly created key.");
                sp += cp(sbuf[sp..], "\n");
                stderr.writeAll(sbuf[0..sp]) catch {};
            }
            return .{ .exit_code = 1 };
        }
    }

    stdout.writeAll("\n") catch {};

    // Step 3: create the secrets file
    {
        var sbuf: [128]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "  ");
        sp += style.dimText(sbuf[sp..], "Step 3/3");
        sp += cp(sbuf[sp..], "  Creating encrypted vault...\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }

    @memcpy(store.key_id[0..key_id_len], key_id_buf[0..key_id_len]);
    store.key_id_len = key_id_len;
    store.saveKeyId();

    store.save() catch {
        {
            var sbuf: [128]u8 = undefined;
            var sp: usize = 0;
            sp += cp(sbuf[0..], "           ");
            sp += style.colored(sbuf[sp..], .red, "Failed to create secrets file.");
            sp += cp(sbuf[sp..], "\n");
            stderr.writeAll(sbuf[0..sp]) catch {};
        }
        return .{ .exit_code = 1 };
    };

    {
        var sbuf: [128]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "           ");
        sp += style.colored(sbuf[sp..], .green, "Done!");
        sp += cp(sbuf[sp..], "\n\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }
    {
        var sbuf: [256]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "  ");
        sp += style.dimText(sbuf[sp..], "Key:");
        sp += cp(sbuf[sp..], "  ");
        sp += cp(sbuf[sp..], key_id_buf[0..key_id_len]);
        sp += cp(sbuf[sp..], "\n  ");
        sp += style.dimText(sbuf[sp..], "File:");
        sp += cp(sbuf[sp..], " ");
        sp += cp(sbuf[sp..], store.filePath());
        sp += cp(sbuf[sp..], "\n\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }
    stdout.writeAll("  Add your first secret:\n") catch {};
    {
        var sbuf: [256]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "    ");
        sp += style.boldText(sbuf[sp..], "xyron secrets add API_KEY sk-xxx --description \"OpenAI key\"");
        sp += cp(sbuf[sp..], "\n\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }
    stdout.writeAll("  Or browse with:\n") catch {};
    {
        var sbuf: [128]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "    ");
        sp += style.boldText(sbuf[sp..], "xyron secrets open");
        sp += cp(sbuf[sp..], "\n\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }

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
                    // Build: "    <yellow>idx.</yellow> field\n"
                    var nbuf: [256]u8 = undefined;
                    var np: usize = 0;
                    np += cp(nbuf[0..], "    ");
                    const idx_str = std.fmt.bufPrint(nbuf[np + style.fg(nbuf[np..], .yellow) ..], "{d}.", .{idx}) catch "";
                    np += style.fg(nbuf[np..], .yellow);
                    np += idx_str.len;
                    np += style.reset(nbuf[np..]);
                    np += cp(nbuf[np..], " ");
                    np += cp(nbuf[np..], field);
                    np += cp(nbuf[np..], "\n");
                    stdout.writeAll(nbuf[0..np]) catch {};
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

    {
        var sbuf: [128]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "\n  ");
        sp += style.dimText(sbuf[sp..], "Generating key (this may take a moment)...");
        sp += cp(sbuf[sp..], "\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }

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
        {
            var sbuf: [128]u8 = undefined;
            var sp: usize = 0;
            sp += cp(sbuf[0..], "  ");
            sp += style.colored(sbuf[sp..], .red, "Failed to start gpg.");
            sp += cp(sbuf[sp..], "\n");
            stderr.writeAll(sbuf[0..sp]) catch {};
        }
        return false;
    };

    if (child.stdin) |stdin| {
        stdin.writeAll(batch) catch {};
        stdin.close();
        child.stdin = null;
    }

    const term = child.wait() catch return false;
    if (switch (term) { .Exited => |cc| cc, else => 1 } != 0) {
        {
            var sbuf: [128]u8 = undefined;
            var sp: usize = 0;
            sp += cp(sbuf[0..], "  ");
            sp += style.colored(sbuf[sp..], .red, "Key generation failed.");
            sp += cp(sbuf[sp..], "\n");
            stderr.writeAll(sbuf[0..sp]) catch {};
        }
        return false;
    }

    {
        var sbuf: [64]u8 = undefined;
        var sp: usize = 0;
        sp += cp(sbuf[0..], "  ");
        sp += style.colored(sbuf[sp..], .green, "Key created!");
        sp += cp(sbuf[sp..], "\n");
        stdout.writeAll(sbuf[0..sp]) catch {};
    }
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
