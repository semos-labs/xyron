// protocol.zig — Binary protocol for headless Xyron ↔ Attyx communication.
//
// Framing matches Attyx IPC: [4B payload_len LE][1B msg_type][payload...]
// Optional JSON debug mode uses newline-delimited JSON instead.

const std = @import("std");
const posix = std.posix;

pub const header_size: usize = 5;

// ---------------------------------------------------------------------------
// Message types
// ---------------------------------------------------------------------------

pub const MsgType = enum(u8) {
    // Requests: Attyx → Xyron (0x01–0x1F)
    init_session = 0x01,
    run_command = 0x02,
    send_input = 0x03,
    interrupt = 0x04,
    suspend_job = 0x05,
    resume_job = 0x06,
    list_jobs = 0x07,
    get_history = 0x08,
    get_shell_state = 0x09,
    inspect_job = 0x0A,
    get_prompt = 0x0B,
    resize = 0x0C,

    // Responses: Xyron → Attyx (0x80–0x8F)
    resp_success = 0x80,
    resp_error = 0x81,

    // Events: Xyron → Attyx (0xA0–0xBF)
    evt_command_started = 0xA0,
    evt_command_finished = 0xA1,
    evt_output_chunk = 0xA2,
    evt_cwd_changed = 0xA3,
    evt_env_changed = 0xA4,
    evt_job_started = 0xA5,
    evt_job_finished = 0xA6,
    evt_job_suspended = 0xA7,
    evt_job_resumed = 0xA8,
    evt_history_recorded = 0xA9,
    evt_prompt = 0xAB,
    evt_ready = 0xAA,

    pub fn isRequest(self: MsgType) bool {
        return @intFromEnum(self) < 0x80;
    }
};

// ---------------------------------------------------------------------------
// Binary frame read/write
// ---------------------------------------------------------------------------

pub const MAX_PAYLOAD: usize = 65536;

pub const Frame = struct {
    msg_type: MsgType,
    payload: []const u8,
};

/// Read one frame from an fd. Returns null on EOF.
pub fn readFrame(fd: posix.fd_t, buf: *[MAX_PAYLOAD + header_size]u8) ?Frame {
    // Read header (5 bytes)
    var hdr: [header_size]u8 = undefined;
    var read_total: usize = 0;
    while (read_total < header_size) {
        const n = posix.read(fd, hdr[read_total..]) catch return null;
        if (n == 0) return null; // EOF
        read_total += n;
    }

    const payload_len = std.mem.readInt(u32, hdr[0..4], .little);
    if (payload_len > MAX_PAYLOAD) return null;

    const msg_type: MsgType = @enumFromInt(hdr[4]);

    // Read payload
    var payload_read: usize = 0;
    while (payload_read < payload_len) {
        const n = posix.read(fd, buf[payload_read..payload_len]) catch return null;
        if (n == 0) return null;
        payload_read += n;
    }

    return .{ .msg_type = msg_type, .payload = buf[0..payload_len] };
}

/// Write one frame to an fd.
pub fn writeFrame(fd: posix.fd_t, msg_type: MsgType, payload: []const u8) void {
    var hdr: [header_size]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len), .little);
    hdr[4] = @intFromEnum(msg_type);
    _ = posix.write(fd, &hdr) catch return;
    if (payload.len > 0) _ = posix.write(fd, payload) catch {};
}

// ---------------------------------------------------------------------------
// Payload encoding helpers — simple TLV: [u16 len][bytes...] for strings,
// [i64 LE] for ints. Type is implicit from message schema.
// ---------------------------------------------------------------------------

pub const PayloadWriter = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) PayloadWriter {
        return .{ .buf = buf };
    }

    pub fn writeStr(self: *PayloadWriter, s: []const u8) void {
        const len: u16 = @intCast(@min(s.len, std.math.maxInt(u16)));
        if (self.pos + 2 + len > self.buf.len) return;
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], len, .little);
        self.pos += 2;
        @memcpy(self.buf[self.pos..][0..len], s[0..len]);
        self.pos += len;
    }

    pub fn writeInt(self: *PayloadWriter, v: i64) void {
        if (self.pos + 8 > self.buf.len) return;
        std.mem.writeInt(i64, self.buf[self.pos..][0..8], v, .little);
        self.pos += 8;
    }

    pub fn writeU8(self: *PayloadWriter, v: u8) void {
        if (self.pos >= self.buf.len) return;
        self.buf[self.pos] = v;
        self.pos += 1;
    }

    pub fn written(self: *const PayloadWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

pub const PayloadReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) PayloadReader {
        return .{ .data = data };
    }

    pub fn readStr(self: *PayloadReader) []const u8 {
        if (self.pos + 2 > self.data.len) return "";
        const len = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        if (self.pos + len > self.data.len) return "";
        const s = self.data[self.pos..][0..len];
        self.pos += len;
        return s;
    }

    pub fn readInt(self: *PayloadReader) i64 {
        if (self.pos + 8 > self.data.len) return 0;
        const v = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    pub fn readU8(self: *PayloadReader) u8 {
        if (self.pos >= self.data.len) return 0;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
};

// ---------------------------------------------------------------------------
// JSON debug mode — same semantics, newline-delimited JSON
// ---------------------------------------------------------------------------

pub const JsonWriter = struct {
    fd: posix.fd_t,

    pub fn writeEvent(self: *const JsonWriter, event_type: []const u8, fields: []const Field) void {
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        pos += cp(buf[pos..], "{\"type\":\"");
        pos += cp(buf[pos..], event_type);
        pos += cp(buf[pos..], "\"");
        for (fields) |f| {
            pos += cp(buf[pos..], ",\"");
            pos += cp(buf[pos..], f.key);
            pos += cp(buf[pos..], "\":");
            switch (f.value) {
                .str => |s| {
                    pos += cp(buf[pos..], "\"");
                    pos += cp(buf[pos..], s);
                    pos += cp(buf[pos..], "\"");
                },
                .int => |v| {
                    const n = std.fmt.bufPrint(buf[pos..], "{d}", .{v}) catch break;
                    pos += n.len;
                },
            }
        }
        pos += cp(buf[pos..], "}\n");
        _ = posix.write(self.fd, buf[0..pos]) catch {};
    }

    pub const Field = struct {
        key: []const u8,
        value: FieldValue,
    };

    pub const FieldValue = union(enum) {
        str: []const u8,
        int: i64,
    };
};

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "payload write and read roundtrip" {
    var buf: [256]u8 = undefined;
    var w = PayloadWriter.init(&buf);
    w.writeStr("hello");
    w.writeInt(42);
    w.writeU8(1);

    var r = PayloadReader.init(w.written());
    try std.testing.expectEqualStrings("hello", r.readStr());
    try std.testing.expectEqual(@as(i64, 42), r.readInt());
    try std.testing.expectEqual(@as(u8, 1), r.readU8());
}

test "frame header encoding" {
    var hdr: [header_size]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 10, .little);
    hdr[4] = @intFromEnum(MsgType.run_command);
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, hdr[0..4], .little));
    try std.testing.expectEqual(MsgType.run_command, @as(MsgType, @enumFromInt(hdr[4])));
}
