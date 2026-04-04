// project/service_store.zig — Persisted service metadata store.
//
// Tracks running/stopped service instances across shell sessions.
// Stored as a simple JSON file at XDG_DATA_HOME/xyron/services.json.
// Scoped by project_id + service_name to avoid collisions.

const std = @import("std");
const types = @import("../types.zig");

pub const max_services = 64;

pub const ServiceState = enum {
    stopped,
    starting,
    running,
    failed,

    pub fn label(self: ServiceState) []const u8 {
        return switch (self) {
            .stopped => "stopped",
            .starting => "starting",
            .running => "running",
            .failed => "failed",
        };
    }
};

/// Metadata for a single service instance.
pub const ServiceInstance = struct {
    // Identity
    project_id: [std.fs.max_path_bytes]u8 = undefined,
    project_id_len: usize = 0,
    service_name: [128]u8 = undefined,
    service_name_len: usize = 0,

    // Runtime
    command: [1024]u8 = undefined,
    command_len: usize = 0,
    cwd: [std.fs.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,
    pid: i32 = 0,
    state: ServiceState = .stopped,
    started_at: i64 = 0,
    updated_at: i64 = 0,
    last_exit_code: u8 = 0,
    context_fingerprint: u64 = 0,

    // Log file path
    log_path: [std.fs.max_path_bytes]u8 = undefined,
    log_path_len: usize = 0,

    pub fn projectIdSlice(self: *const ServiceInstance) []const u8 {
        return self.project_id[0..self.project_id_len];
    }

    pub fn nameSlice(self: *const ServiceInstance) []const u8 {
        return self.service_name[0..self.service_name_len];
    }

    pub fn commandSlice(self: *const ServiceInstance) []const u8 {
        return self.command[0..self.command_len];
    }

    pub fn cwdSlice(self: *const ServiceInstance) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    pub fn logPathSlice(self: *const ServiceInstance) []const u8 {
        return self.log_path[0..self.log_path_len];
    }

    fn setStr(buf: []u8, src: []const u8) usize {
        const len = @min(src.len, buf.len);
        @memcpy(buf[0..len], src[0..len]);
        return len;
    }

    pub fn setProjectId(self: *ServiceInstance, id: []const u8) void {
        self.project_id_len = setStr(&self.project_id, id);
    }

    pub fn setName(self: *ServiceInstance, name: []const u8) void {
        self.service_name_len = setStr(&self.service_name, name);
    }

    pub fn setCommand(self: *ServiceInstance, cmd: []const u8) void {
        self.command_len = setStr(&self.command, cmd);
    }

    pub fn setCwd(self: *ServiceInstance, dir: []const u8) void {
        self.cwd_len = setStr(&self.cwd, dir);
    }

    pub fn setLogPath(self: *ServiceInstance, path: []const u8) void {
        self.log_path_len = setStr(&self.log_path, path);
    }

    /// Check if the process is actually alive via kill(pid, 0).
    pub fn isProcessAlive(self: *const ServiceInstance) bool {
        if (self.pid <= 0) return false;
        const result = std.c.kill(self.pid, 0);
        return result == 0;
    }
};

/// Global service store — flat array of instances persisted to disk.
pub const ServiceStore = struct {
    instances: [max_services]ServiceInstance = undefined,
    count: usize = 0,

    /// Find a service by project_id + name.
    pub fn find(self: *ServiceStore, project_id: []const u8, name: []const u8) ?*ServiceInstance {
        for (self.instances[0..self.count]) |*inst| {
            if (std.mem.eql(u8, inst.projectIdSlice(), project_id) and
                std.mem.eql(u8, inst.nameSlice(), name))
            {
                return inst;
            }
        }
        return null;
    }

    /// Get or create a service instance.
    pub fn getOrCreate(self: *ServiceStore, project_id: []const u8, name: []const u8) ?*ServiceInstance {
        if (self.find(project_id, name)) |existing| return existing;
        if (self.count >= max_services) return null;
        var inst = &self.instances[self.count];
        inst.* = .{};
        inst.setProjectId(project_id);
        inst.setName(name);
        self.count += 1;
        return inst;
    }

    /// List all services for a given project.
    pub fn listForProject(self: *ServiceStore, project_id: []const u8, out: []?*ServiceInstance) usize {
        var n: usize = 0;
        for (self.instances[0..self.count]) |*inst| {
            if (n >= out.len) break;
            if (std.mem.eql(u8, inst.projectIdSlice(), project_id)) {
                out[n] = inst;
                n += 1;
            }
        }
        return n;
    }

    /// Refresh state of all instances by checking if processes are alive.
    pub fn refreshStates(self: *ServiceStore) void {
        for (self.instances[0..self.count]) |*inst| {
            if (inst.state == .running or inst.state == .starting) {
                if (!inst.isProcessAlive()) {
                    // Process died — check exit status
                    inst.state = .failed;
                    inst.updated_at = types.timestampMs();
                }
            }
        }
    }

    /// Load store from disk.
    pub fn load(self: *ServiceStore) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = storePath(&path_buf) orelse return;

        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();

        const content = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return;

        // Simple line-based format: one service per line
        // project_id\tname\tpid\tstate\tcommand\tcwd\tstarted_at\tfingerprint\tlog_path
        var iter = std.mem.splitScalar(u8, content, '\n');
        self.count = 0;
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            if (self.count >= max_services) break;
            self.parseLine(line);
        }
    }

    /// Save store to disk.
    pub fn save(self: *ServiceStore) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = storePath(&path_buf) orelse return;

        // Ensure directory exists
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
            std.fs.makeDirAbsolute(path[0..sep]) catch {};
        }

        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();

        var write_buf: [4096]u8 = undefined;
        for (self.instances[0..self.count]) |*inst| {
            const line = std.fmt.bufPrint(&write_buf, "{s}\t{s}\t{d}\t{s}\t{s}\t{s}\t{d}\t{d}\t{s}\n", .{
                inst.projectIdSlice(),
                inst.nameSlice(),
                inst.pid,
                inst.state.label(),
                inst.commandSlice(),
                inst.cwdSlice(),
                inst.started_at,
                inst.context_fingerprint,
                inst.logPathSlice(),
            }) catch continue;
            file.writeAll(line) catch {};
        }
    }

    fn parseLine(self: *ServiceStore, line: []const u8) void {
        var fields: [9][]const u8 = undefined;
        var field_count: usize = 0;
        var iter = std.mem.splitScalar(u8, line, '\t');
        while (iter.next()) |field| {
            if (field_count >= 9) break;
            fields[field_count] = field;
            field_count += 1;
        }
        if (field_count < 6) return; // minimum fields

        var inst = &self.instances[self.count];
        inst.* = .{};
        inst.setProjectId(fields[0]);
        inst.setName(fields[1]);
        inst.pid = std.fmt.parseInt(i32, fields[2], 10) catch 0;
        inst.state = parseState(fields[3]);
        inst.setCommand(fields[4]);
        inst.setCwd(fields[5]);
        if (field_count > 6) inst.started_at = std.fmt.parseInt(i64, fields[6], 10) catch 0;
        if (field_count > 7) inst.context_fingerprint = std.fmt.parseInt(u64, fields[7], 10) catch 0;
        if (field_count > 8) inst.setLogPath(fields[8]);
        self.count += 1;
    }

    fn parseState(s: []const u8) ServiceState {
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "starting")) return .starting;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        return .stopped;
    }
};

fn storePath(buf: []u8) ?[]const u8 {
    const data_home = std.posix.getenv("XDG_DATA_HOME");
    if (data_home) |xdg| {
        return std.fmt.bufPrintZ(buf, "{s}/xyron/services.store", .{xdg}) catch null;
    }
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.local/share/xyron/services.store", .{home}) catch null;
}

// Global singleton
var global_store: ServiceStore = .{};
var store_loaded: bool = false;

pub fn getStore() *ServiceStore {
    if (!store_loaded) {
        global_store.load();
        global_store.refreshStates();
        store_loaded = true;
    }
    return &global_store;
}

// =============================================================================
// Tests
// =============================================================================

test "ServiceInstance identity" {
    var inst = ServiceInstance{};
    inst.setProjectId("/home/user/app");
    inst.setName("web");
    try std.testing.expectEqualStrings("/home/user/app", inst.projectIdSlice());
    try std.testing.expectEqualStrings("web", inst.nameSlice());
}

test "ServiceStore find and create" {
    var store = ServiceStore{};
    const inst = store.getOrCreate("/tmp/proj", "db").?;
    inst.state = .running;
    inst.pid = 1234;

    try std.testing.expectEqual(@as(usize, 1), store.count);
    const found = store.find("/tmp/proj", "db").?;
    try std.testing.expectEqual(@as(i32, 1234), found.pid);

    // Different project, same name — no collision
    _ = store.getOrCreate("/tmp/other", "db");
    try std.testing.expectEqual(@as(usize, 2), store.count);
}

test "ServiceStore listForProject" {
    var store = ServiceStore{};
    _ = store.getOrCreate("/tmp/proj", "web");
    _ = store.getOrCreate("/tmp/proj", "db");
    _ = store.getOrCreate("/tmp/other", "api");

    var out: [8]?*ServiceInstance = .{null} ** 8;
    const n = store.listForProject("/tmp/proj", &out);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "ServiceState labels" {
    try std.testing.expectEqualStrings("running", ServiceState.running.label());
    try std.testing.expectEqualStrings("stopped", ServiceState.stopped.label());
    try std.testing.expectEqualStrings("failed", ServiceState.failed.label());
}
