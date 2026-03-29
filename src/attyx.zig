// attyx.zig — Attyx terminal integration layer.
//
// Emits structured lifecycle events via OSC 7339 escape sequences.
// Phase 3 adds env_changed events for export/unset operations.

const std = @import("std");
const types = @import("types.zig");
const planner = @import("planner.zig");

pub const Attyx = struct {
    enabled: bool,
    stderr: std.fs.File,

    pub fn init() Attyx {
        const enabled = blk: {
            const val = std.posix.getenv("ATTYX") orelse break :blk false;
            break :blk std.mem.eql(u8, val, "1");
        };
        return .{ .enabled = enabled, .stderr = std.fs.File.stderr() };
    }

    pub fn disabled() Attyx {
        return .{ .enabled = false, .stderr = std.fs.File.stderr() };
    }

    // ------------------------------------------------------------------
    // Command group lifecycle events
    // ------------------------------------------------------------------

    pub fn groupStarted(self: *const Attyx, p: *const planner.ExecutionPlan) void {
        if (!self.enabled) return;
        var buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"command_group_started\"," ++
                "\"group_id\":{d},\"raw\":\"{s}\",\"cwd\":\"{s}\"," ++
                "\"timestamp_ms\":{d}}}\x07",
            .{ p.group_id, p.raw_input, p.cwd, p.timestamp_ms },
        ) catch return;
        self.stderr.writeAll(msg) catch {};
    }

    pub fn stepStarted(self: *const Attyx, p: *const planner.ExecutionPlan, step: *const planner.PlanStep) void {
        if (!self.enabled) return;
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        pos += copy(buf[pos..], "\x1b]7339;xyron:{\"event\":\"command_step_started\",\"group_id\":");
        pos += fmt(buf[pos..], "{d}", .{p.group_id});
        pos += copy(buf[pos..], ",\"step_id\":");
        pos += fmt(buf[pos..], "{d}", .{step.step_id});
        pos += copy(buf[pos..], ",\"argv\":[");
        for (step.argv, 0..) |arg, i| {
            if (i > 0) pos += copy(buf[pos..], ",");
            pos += copy(buf[pos..], "\"");
            pos += copy(buf[pos..], arg);
            pos += copy(buf[pos..], "\"");
        }
        pos += copy(buf[pos..], "],\"cwd\":\"");
        pos += copy(buf[pos..], p.cwd);
        pos += copy(buf[pos..], "\",\"timestamp_ms\":");
        pos += fmt(buf[pos..], "{d}", .{types.timestampMs()});
        pos += copy(buf[pos..], "}\x07");
        self.stderr.writeAll(buf[0..pos]) catch {};
    }

    pub fn stepFinished(self: *const Attyx, p: *const planner.ExecutionPlan, step: *const planner.PlanStep, exit_code: u8, duration_ms: i64) void {
        if (!self.enabled) return;
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"command_step_finished\"," ++
                "\"group_id\":{d},\"step_id\":{d},\"exit_code\":{d}," ++
                "\"duration_ms\":{d},\"timestamp_ms\":{d}}}\x07",
            .{ p.group_id, step.step_id, exit_code, duration_ms, types.timestampMs() },
        ) catch return;
        self.stderr.writeAll(msg) catch {};
    }

    pub fn groupFinished(self: *const Attyx, p: *const planner.ExecutionPlan, exit_code: u8, duration_ms: i64) void {
        if (!self.enabled) return;
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"command_group_finished\"," ++
                "\"group_id\":{d},\"exit_code\":{d},\"duration_ms\":{d}," ++
                "\"timestamp_ms\":{d}}}\x07",
            .{ p.group_id, exit_code, duration_ms, types.timestampMs() },
        ) catch return;
        self.stderr.writeAll(msg) catch {};
    }

    // ------------------------------------------------------------------
    // CWD change event + standard OSC 7
    // ------------------------------------------------------------------

    pub fn cwdChanged(self: *const Attyx, old_cwd: []const u8, new_cwd: []const u8) void {
        if (!self.enabled) return;
        var buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"cwd_changed\"," ++
                "\"old_cwd\":\"{s}\",\"new_cwd\":\"{s}\"," ++
                "\"timestamp_ms\":{d}}}\x07",
            .{ old_cwd, new_cwd, types.timestampMs() },
        ) catch return;
        self.stderr.writeAll(msg) catch {};

        // Standard OSC 7
        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&hostname_buf) catch "localhost";
        var osc_buf: [2048]u8 = undefined;
        const osc = std.fmt.bufPrint(&osc_buf, "\x1b]7;file://{s}{s}\x07", .{ hostname, new_cwd }) catch return;
        self.stderr.writeAll(osc) catch {};
    }

    // ------------------------------------------------------------------
    // Environment change events (Phase 3)
    // ------------------------------------------------------------------

    /// Emit env_changed event when a variable is set or unset.
    pub fn envChanged(self: *const Attyx, change_kind: []const u8, key: []const u8, value: []const u8) void {
        if (!self.enabled) return;
        var buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"env_changed\"," ++
                "\"kind\":\"{s}\",\"key\":\"{s}\",\"value\":\"{s}\"," ++
                "\"timestamp_ms\":{d}}}\x07",
            .{ change_kind, key, value, types.timestampMs() },
        ) catch return;
        self.stderr.writeAll(msg) catch {};
    }

    // ------------------------------------------------------------------
    // Job events (Phase 5)
    // ------------------------------------------------------------------

    pub fn jobStarted(self: *const Attyx, job_id: u32, group_id: u64, raw: []const u8, cwd: []const u8) void {
        if (!self.enabled) return;
        var buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"job_started\"," ++
                "\"job_id\":{d},\"group_id\":{d},\"raw\":\"{s}\"," ++
                "\"cwd\":\"{s}\",\"timestamp_ms\":{d}}}\x07",
            .{ job_id, group_id, raw, cwd, types.timestampMs() },
        ) catch return;
        self.stderr.writeAll(msg) catch {};
    }

    pub fn jobSuspended(self: *const Attyx, job_id: u32, group_id: u64) void {
        if (!self.enabled) return;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"job_suspended\"," ++
                "\"job_id\":{d},\"group_id\":{d}," ++
                "\"timestamp_ms\":{d}}}\x07",
            .{ job_id, group_id, types.timestampMs() },
        ) catch return;
        self.stderr.writeAll(msg) catch {};
    }

    pub fn jobResumed(self: *const Attyx, job_id: u32, group_id: u64, mode: []const u8) void {
        if (!self.enabled) return;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"job_resumed\"," ++
                "\"job_id\":{d},\"group_id\":{d}," ++
                "\"mode\":\"{s}\",\"timestamp_ms\":{d}}}\x07",
            .{ job_id, group_id, mode, types.timestampMs() },
        ) catch return;
        self.stderr.writeAll(msg) catch {};
    }

    pub fn jobFinished(self: *const Attyx, job_id: u32, exit_code: u8, duration_ms: i64) void {
        if (!self.enabled) return;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"job_finished\"," ++
                "\"job_id\":{d},\"exit_code\":{d},\"duration_ms\":{d}," ++
                "\"timestamp_ms\":{d}}}\x07",
            .{ job_id, exit_code, duration_ms, types.timestampMs() },
        ) catch return;
        self.stderr.writeAll(msg) catch {};
    }

    // ------------------------------------------------------------------
    // History events (Phase 4)
    // ------------------------------------------------------------------

    /// Emit after a command is recorded to the history database.
    pub fn historyEntryRecorded(self: *const Attyx, cmd_id: i64, raw: []const u8, cwd: []const u8, exit_code: u8, duration_ms: i64) void {
        if (!self.enabled) return;
        var buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"history_entry_recorded\"," ++
                "\"command_id\":{d},\"raw\":\"{s}\",\"cwd\":\"{s}\"," ++
                "\"exit_code\":{d},\"duration_ms\":{d}," ++
                "\"timestamp_ms\":{d}}}\x07",
            .{ cmd_id, raw, cwd, exit_code, duration_ms, types.timestampMs() },
        ) catch return;
        self.stderr.writeAll(msg) catch {};
    }

    /// Emit on shell startup after history DB is initialized.
    pub fn historyInitialized(self: *const Attyx, total_entries: i64) void {
        if (!self.enabled) return;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            "\x1b]7339;xyron:{{\"event\":\"history_initialized\"," ++
                "\"total_entries\":{d},\"timestamp_ms\":{d}}}\x07",
            .{ total_entries, types.timestampMs() },
        ) catch return;
        self.stderr.writeAll(msg) catch {};
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    fn copy(dest: []u8, src: []const u8) usize {
        const len = @min(src.len, dest.len);
        @memcpy(dest[0..len], src[0..len]);
        return len;
    }

    fn fmt(dest: []u8, comptime f: []const u8, args: anytype) usize {
        const result = std.fmt.bufPrint(dest, f, args) catch return 0;
        return result.len;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "disabled attyx does not panic" {
    const ax = Attyx.disabled();
    ax.envChanged("set", "FOO", "bar");
    ax.cwdChanged("/old", "/new");
}

test "init does not crash" {
    const ax = Attyx.init();
    _ = ax.enabled;
}
