// secrets.zig — Encrypted secrets manager.
//
// Stores secrets in a GPG-encrypted JSON file. On load, decrypts with
// `gpg --decrypt`. On save, encrypts with `gpg --encrypt --recipient <key-id>`.
//
// Secret types:
//   env    — loaded into environment on shell startup
//   local  — loaded when cd'ing into the specified directory
//   password — stored only, queried on demand

const std = @import("std");
const posix = std.posix;

pub const SecretKind = enum { env, local, password };

pub const Secret = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    value: [512]u8 = undefined,
    value_len: usize = 0,
    description: [256]u8 = undefined,
    desc_len: usize = 0,
    directory: [std.fs.max_path_bytes]u8 = undefined,
    dir_len: usize = 0,
    kind: SecretKind = .env,

    pub fn nameSlice(self: *const Secret) []const u8 { return self.name[0..self.name_len]; }
    pub fn valueSlice(self: *const Secret) []const u8 { return self.value[0..self.value_len]; }
    pub fn descSlice(self: *const Secret) []const u8 { return self.description[0..self.desc_len]; }
    pub fn dirSlice(self: *const Secret) []const u8 { return self.directory[0..self.dir_len]; }
};

pub const MAX_SECRETS = 256;

pub const SecretsStore = struct {
    secrets: [MAX_SECRETS]Secret = undefined,
    count: usize = 0,
    key_id: [128]u8 = undefined,
    key_id_len: usize = 0,
    file_path: [std.fs.max_path_bytes]u8 = undefined,
    file_path_len: usize = 0,
    modified: bool = false,

    pub fn init() SecretsStore {
        var store = SecretsStore{};
        // Resolve file path: $XDG_DATA_HOME/xyron/secrets.gpg
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const data_home = std.posix.getenv("XDG_DATA_HOME") orelse blk: {
            const home = std.posix.getenv("HOME") orelse return store;
            break :blk std.fmt.bufPrint(&path_buf, "{s}/.local/share", .{home}) catch return store;
        };
        const path = std.fmt.bufPrint(&store.file_path, "{s}/xyron/secrets.gpg", .{data_home}) catch return store;
        store.file_path_len = path.len;

        // Load key ID from config
        store.loadKeyId();
        return store;
    }

    pub fn filePath(self: *const SecretsStore) []const u8 {
        return self.file_path[0..self.file_path_len];
    }

    pub fn keyId(self: *const SecretsStore) []const u8 {
        return self.key_id[0..self.key_id_len];
    }

    /// Load secrets from encrypted file.
    pub fn load(self: *SecretsStore) !void {
        if (self.file_path_len == 0) return error.NoPath;
        if (self.key_id_len == 0) return error.NoKeyId;

        // Decrypt with GPG
        const alloc = std.heap.page_allocator;
        var child = std.process.Child.init(
            &.{ "gpg", "--quiet", "--batch", "--decrypt", self.filePath() },
            alloc,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return error.GpgFailed;

        var out_buf: [65536]u8 = undefined;
        var total: usize = 0;
        if (child.stdout) |f| {
            while (total < out_buf.len) {
                const n = f.read(out_buf[total..]) catch break;
                if (n == 0) break;
                total += n;
            }
        }

        const term = child.wait() catch return error.GpgFailed;
        if (switch (term) { .Exited => |c| c, else => 1 } != 0) return error.GpgFailed;

        // Parse JSON
        self.parseJson(out_buf[0..total]);
    }

    /// Save secrets to encrypted file.
    pub fn save(self: *SecretsStore) !void {
        if (self.file_path_len == 0) return error.NoPath;
        if (self.key_id_len == 0) return error.NoKeyId;

        // Serialize to JSON
        var json_buf: [65536]u8 = undefined;
        const json = self.toJson(&json_buf);

        // Encrypt with GPG
        const alloc = std.heap.page_allocator;
        var child = std.process.Child.init(
            &.{ "gpg", "--quiet", "--batch", "--yes", "--encrypt",
                "--recipient", self.keyId(),
                "--output", self.filePath() },
            alloc,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return error.GpgFailed;

        if (child.stdin) |stdin| {
            stdin.writeAll(json) catch {};
            stdin.close();
            child.stdin = null;
        }

        const term = child.wait() catch return error.GpgFailed;
        if (switch (term) { .Exited => |c| c, else => 1 } != 0) return error.GpgFailed;

        self.modified = false;
    }

    /// Add a secret.
    pub fn add(self: *SecretsStore, name: []const u8, value: []const u8, desc: []const u8, dir: []const u8, kind: SecretKind) bool {
        if (self.count >= MAX_SECRETS) return false;
        var s = &self.secrets[self.count];
        s.* = Secret{};
        setField(&s.name, &s.name_len, name);
        setField(&s.value, &s.value_len, value);
        setField(&s.description, &s.desc_len, desc);
        setField(&s.directory, &s.dir_len, dir);
        s.kind = kind;
        self.count += 1;
        self.modified = true;
        return true;
    }

    /// Remove a secret by index.
    pub fn remove(self: *SecretsStore, idx: usize) void {
        if (idx >= self.count) return;
        // Shift down
        var i = idx;
        while (i + 1 < self.count) : (i += 1) {
            self.secrets[i] = self.secrets[i + 1];
        }
        self.count -= 1;
        self.modified = true;
    }

    /// Find a secret by name. Returns index or null.
    pub fn findByName(self: *const SecretsStore, name: []const u8) ?usize {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.secrets[i].nameSlice(), name)) return i;
        }
        return null;
    }

    /// Get all env secrets (for loading into environment).
    pub fn getEnvSecrets(self: *const SecretsStore, out: []Secret) usize {
        var n: usize = 0;
        for (0..self.count) |i| {
            if (self.secrets[i].kind == .env and n < out.len) {
                out[n] = self.secrets[i];
                n += 1;
            }
        }
        return n;
    }

    /// Get local secrets that apply to a directory.
    /// A secret matches if the cwd is the secret's directory or a subdirectory of it.
    pub fn getLocalSecrets(self: *const SecretsStore, cwd: []const u8, out: []Secret) usize {
        var n: usize = 0;
        for (0..self.count) |i| {
            const s = &self.secrets[i];
            if (s.kind != .local or n >= out.len) continue;
            const sdir = s.dirSlice();
            // cwd matches if it equals the secret dir or is a child of it
            if (std.mem.eql(u8, cwd, sdir) or
                (cwd.len > sdir.len and std.mem.startsWith(u8, cwd, sdir) and cwd[sdir.len] == '/'))
            {
                out[n] = self.secrets[i];
                n += 1;
            }
        }
        return n;
    }

    /// Check if secrets file exists.
    pub fn fileExists(self: *const SecretsStore) bool {
        if (self.file_path_len == 0) return false;
        std.fs.cwd().access(self.filePath(), .{}) catch return false;
        return true;
    }

    /// Check if GPG key is configured.
    pub fn isInitialized(self: *const SecretsStore) bool {
        return self.key_id_len > 0;
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    fn loadKeyId(self: *SecretsStore) void {
        // Read from $XDG_CONFIG_HOME/xyron/secrets.conf or ~/.config/xyron/secrets.conf
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_home = std.posix.getenv("XDG_CONFIG_HOME") orelse blk: {
            const home = std.posix.getenv("HOME") orelse return;
            break :blk std.fmt.bufPrint(&path_buf, "{s}/.config", .{home}) catch return;
        };
        var conf_path: [std.fs.max_path_bytes]u8 = undefined;
        const cp = std.fmt.bufPrint(&conf_path, "{s}/xyron/secrets.conf", .{config_home}) catch return;

        const file = std.fs.cwd().openFile(cp, .{}) catch return;
        defer file.close();

        var buf: [256]u8 = undefined;
        const n = file.readAll(&buf) catch return;
        const content = std.mem.trimRight(u8, buf[0..n], "\n\r ");
        const len = @min(content.len, self.key_id.len);
        @memcpy(self.key_id[0..len], content[0..len]);
        self.key_id_len = len;
    }

    pub fn saveKeyId(self: *const SecretsStore) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_home = std.posix.getenv("XDG_CONFIG_HOME") orelse blk: {
            const home = std.posix.getenv("HOME") orelse return;
            break :blk std.fmt.bufPrint(&path_buf, "{s}/.config", .{home}) catch return;
        };
        var dir_path: [std.fs.max_path_bytes]u8 = undefined;
        const dp = std.fmt.bufPrint(&dir_path, "{s}/xyron", .{config_home}) catch return;
        std.fs.cwd().makePath(dp) catch {};

        var conf_path: [std.fs.max_path_bytes]u8 = undefined;
        const cp2 = std.fmt.bufPrint(&conf_path, "{s}/xyron/secrets.conf", .{config_home}) catch return;

        const file = std.fs.cwd().createFile(cp2, .{}) catch return;
        defer file.close();
        file.writeAll(self.keyId()) catch {};
    }

    pub fn setFieldPub(buf: []u8, len: *usize, src: []const u8) void {
        setField(buf, len, src);
    }

    fn setField(buf: []u8, len: *usize, src: []const u8) void {
        const n = @min(src.len, buf.len);
        @memcpy(buf[0..n], src[0..n]);
        len.* = n;
    }

    // -----------------------------------------------------------------------
    // JSON serialization (manual — no allocator needed)
    // -----------------------------------------------------------------------

    fn toJson(self: *const SecretsStore, buf: *[65536]u8) []const u8 {
        var pos: usize = 0;
        pos += cpb(buf[pos..], "[");
        for (0..self.count) |i| {
            if (i > 0) pos += cpb(buf[pos..], ",");
            pos += cpb(buf[pos..], "\n{\"name\":\"");
            pos += jsonEscape(buf[pos..], self.secrets[i].nameSlice());
            pos += cpb(buf[pos..], "\",\"value\":\"");
            pos += jsonEscape(buf[pos..], self.secrets[i].valueSlice());
            pos += cpb(buf[pos..], "\",\"desc\":\"");
            pos += jsonEscape(buf[pos..], self.secrets[i].descSlice());
            pos += cpb(buf[pos..], "\",\"dir\":\"");
            pos += jsonEscape(buf[pos..], self.secrets[i].dirSlice());
            pos += cpb(buf[pos..], "\",\"kind\":\"");
            pos += cpb(buf[pos..], @tagName(self.secrets[i].kind));
            pos += cpb(buf[pos..], "\"}");
        }
        pos += cpb(buf[pos..], "\n]");
        return buf[0..pos];
    }

    fn parseJson(self: *SecretsStore, data: []const u8) void {
        self.count = 0;
        // Simple JSON array parser — expects [{"name":"...","value":"...","desc":"...","dir":"...","kind":"..."},...]
        var i: usize = 0;
        while (i < data.len and self.count < MAX_SECRETS) {
            // Find next object
            while (i < data.len and data[i] != '{') : (i += 1) {}
            if (i >= data.len) break;
            i += 1; // skip {

            var s = &self.secrets[self.count];
            s.* = Secret{};

            // Parse fields
            while (i < data.len and data[i] != '}') {
                // Find key
                while (i < data.len and data[i] != '"') : (i += 1) {}
                if (i >= data.len) break;
                i += 1;
                const key_start = i;
                while (i < data.len and data[i] != '"') : (i += 1) {}
                const key = data[key_start..i];
                i += 1; // skip "

                // Skip :
                while (i < data.len and data[i] != '"') : (i += 1) {}
                i += 1;

                // Read value
                const val_start = i;
                while (i < data.len and data[i] != '"') {
                    if (data[i] == '\\' and i + 1 < data.len) { i += 2; continue; }
                    i += 1;
                }
                const val = data[val_start..i];
                if (i < data.len) i += 1;

                if (std.mem.eql(u8, key, "name")) { setField(&s.name, &s.name_len, val); }
                else if (std.mem.eql(u8, key, "value")) { setField(&s.value, &s.value_len, val); }
                else if (std.mem.eql(u8, key, "desc")) { setField(&s.description, &s.desc_len, val); }
                else if (std.mem.eql(u8, key, "dir")) { setField(&s.directory, &s.dir_len, val); }
                else if (std.mem.eql(u8, key, "kind")) {
                    if (std.mem.eql(u8, val, "local")) { s.kind = .local; }
                    else if (std.mem.eql(u8, val, "password")) { s.kind = .password; }
                    else { s.kind = .env; }
                }
            }
            if (i < data.len) i += 1; // skip }
            if (s.name_len > 0) self.count += 1;
        }
    }
};

fn cpb(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

fn jsonEscape(dest: []u8, src: []const u8) usize {
    var pos: usize = 0;
    for (src) |ch| {
        if (pos + 2 > dest.len) break;
        if (ch == '"' or ch == '\\') {
            dest[pos] = '\\';
            pos += 1;
        }
        dest[pos] = ch;
        pos += 1;
    }
    return pos;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "add and find" {
    var store = SecretsStore{};
    _ = store.add("API_KEY", "abc123", "My API key", "", .env);
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expect(store.findByName("API_KEY") != null);
    try std.testing.expect(store.findByName("MISSING") == null);
}

test "remove" {
    var store = SecretsStore{};
    _ = store.add("A", "1", "", "", .env);
    _ = store.add("B", "2", "", "", .env);
    store.remove(0);
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expectEqualStrings("B", store.secrets[0].nameSlice());
}

test "json roundtrip" {
    var store = SecretsStore{};
    _ = store.add("KEY", "val\"ue", "desc", "/tmp", .local);
    var json_buf: [65536]u8 = undefined;
    const json = store.toJson(&json_buf);

    var store2 = SecretsStore{};
    store2.parseJson(json);
    try std.testing.expectEqual(@as(usize, 1), store2.count);
    try std.testing.expectEqualStrings("KEY", store2.secrets[0].nameSlice());
    try std.testing.expectEqual(SecretKind.local, store2.secrets[0].kind);
}
