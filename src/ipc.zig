// ipc.zig — Unix domain socket IPC for Attyx integration.
//
// When running inside Attyx (ATTYX=1), Xyron opens a Unix socket
// alongside the interactive PTY. Attyx connects to query shell state
// (history, completions, environment, jobs) using the same binary
// protocol as headless mode.
//
// Architecture:
//   PTY stdin/stdout  → interactive rendering (ANSI, overlay, block UI)
//   Unix socket       → structured data queries (binary protocol)
//   stderr            → Attyx events (OSC 7339)

const std = @import("std");
const posix = std.posix;
const proto = @import("protocol.zig");
const complete_mod = @import("complete.zig");
const highlight = @import("highlight.zig");
const environ_mod = @import("environ.zig");
const complete_help = @import("complete_help.zig");
const history_mod = @import("history.zig");
const history_db_mod = @import("history_db.zig");
const jobs_mod = @import("jobs.zig");

/// References to shell state (set by shell.zig after init).
pub var env: ?*environ_mod.Environ = null;
pub var cmd_cache: ?*highlight.CommandCache = null;
pub var help_cache: ?*complete_help.HelpCache = null;
pub var history: ?*history_mod.History = null;
pub var history_db: ?*history_db_mod.HistoryDb = null;
pub var job_table: ?*jobs_mod.JobTable = null;

/// Xyron's socket path and fd.
var socket_path_buf: [256]u8 = undefined;
var socket_path_len: usize = 0;
var listen_fd: posix.fd_t = -1;

/// Attyx's socket path (received via handshake).
var attyx_socket_buf: [256]u8 = undefined;
var attyx_socket_len: usize = 0;
pub var attyx_connected: bool = false;

/// Get the listen fd for poll()-based multiplexing.
pub fn getListenFd() posix.fd_t {
    return listen_fd;
}

/// Get Xyron's socket path.
pub fn getSocketPath() ?[]const u8 {
    if (socket_path_len == 0) return null;
    return socket_path_buf[0..socket_path_len];
}

/// Get Attyx's socket path (after handshake).
pub fn getAttyxSocket() ?[]const u8 {
    if (attyx_socket_len == 0) return null;
    return attyx_socket_buf[0..attyx_socket_len];
}

/// Send a fire-and-forget event to Attyx. No response expected.
pub fn sendToAttyx(msg_type: proto.MsgType, payload: []const u8) ?[]const u8 {
    if (attyx_socket_len == 0) return null;

    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    @memcpy(addr.path[0..attyx_socket_len], attyx_socket_buf[0..attyx_socket_len]);
    addr.path[attyx_socket_len] = 0;

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return null;

    writeToFd(fd, msg_type, payload);
    return null;
}

/// Send a request to Attyx and wait for response.
pub fn requestFromAttyx(msg_type: proto.MsgType, payload: []const u8) ?[]const u8 {
    if (attyx_socket_len == 0) return null;

    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return null;
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    @memcpy(addr.path[0..attyx_socket_len], attyx_socket_buf[0..attyx_socket_len]);
    addr.path[attyx_socket_len] = 0;

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return null;

    writeToFd(fd, msg_type, payload);

    const S = struct { var resp_buf: [proto.MAX_PAYLOAD + proto.header_size]u8 = undefined; };
    const frame = proto.readFrame(fd, &S.resp_buf) orelse return null;
    return frame.payload;
}

/// Start the IPC listener. Creates a Unix socket and returns the path.
pub fn start() ?[]const u8 {
    // Build socket path: $XDG_RUNTIME_DIR/xyron-{pid}.sock or /tmp/xyron-{pid}.sock
    const pid = std.c.getpid();
    const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const path = std.fmt.bufPrint(&socket_path_buf, "{s}/xyron-{d}.sock", .{ runtime_dir, pid }) catch return null;
    socket_path_len = path.len;

    // Ensure null-terminated for bind
    if (socket_path_len >= socket_path_buf.len) return null;
    socket_path_buf[socket_path_len] = 0;

    // Remove stale socket
    std.fs.cwd().deleteFile(path) catch {};

    // Create socket
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0) catch return null;
    listen_fd = fd;

    // Bind
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    @memcpy(addr.path[0..socket_path_len], socket_path_buf[0..socket_path_len]);
    addr.path[socket_path_len] = 0;
    posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        posix.close(fd);
        listen_fd = -1;
        return null;
    };

    // Listen
    posix.listen(fd, 4) catch {
        posix.close(fd);
        listen_fd = -1;
        return null;
    };

    return path;
}

/// Stop the IPC listener and remove the socket file.
pub fn stop() void {
    if (listen_fd >= 0) {
        posix.close(listen_fd);
        listen_fd = -1;
    }
    if (socket_path_len > 0) {
        std.fs.cwd().deleteFile(socket_path_buf[0..socket_path_len]) catch {};
        socket_path_len = 0;
    }
}

/// Poll for and handle pending IPC requests. Non-blocking.
/// Call from the shell's main loop (between prompts or during idle).
pub fn poll() void {
    if (listen_fd < 0) return;

    // Accept new connections (non-blocking)
    while (true) {
        const client_fd = posix.accept(listen_fd, null, null, posix.SOCK.NONBLOCK) catch break;
        handleClient(client_fd);
        posix.close(client_fd);
    }
}

fn handleClient(fd: posix.fd_t) void {
    // Read frames until EOF
    var frame_buf: [proto.MAX_PAYLOAD + proto.header_size]u8 = undefined;

    while (true) {
        // Make fd blocking for reads (simpler than polling)
        const frame = proto.readFrame(fd, &frame_buf) orelse break;
        if (!frame.msg_type.isRequest()) continue;

        switch (frame.msg_type) {
            .handshake => handleHandshake(fd, frame.payload),
            .overlay_select => handleOverlaySelect(fd, frame.payload),
            .overlay_dismiss => handleOverlayDismiss(fd),
            .get_completions => handleGetCompletions(fd, frame.payload),
            .get_ghost => handleGetGhost(fd, frame.payload),
            .get_shell_state => handleGetShellState(fd, frame.payload),
            .get_history => handleGetHistory(fd, frame.payload),
            .query_history => handleQueryHistory(fd, frame.payload),
            .list_jobs => handleListJobs(fd, frame.payload),
            else => {
                // Unknown request — send error
                var buf: [256]u8 = undefined;
                var w = proto.PayloadWriter.init(&buf);
                var r = proto.PayloadReader.init(frame.payload);
                w.writeInt(r.readInt()); // req_id
                w.writeStr("unsupported in IPC mode");
                writeToFd(fd, .resp_error, w.written());
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Request handlers (same logic as headless.zig but writes to client fd)
// ---------------------------------------------------------------------------

/// Attyx pane ID for this shell instance.
var attyx_pane_id_buf: [64]u8 = undefined;
var attyx_pane_id_len: usize = 0;

/// Get the Attyx pane ID (after handshake).
pub fn getAttyxPaneId() ?[]const u8 {
    if (attyx_pane_id_len == 0) return null;
    return attyx_pane_id_buf[0..attyx_pane_id_len];
}

/// Pending overlay action from Attyx (checked by the input loop).
pub const OverlayAction = enum { none, dismiss, select };
pub var pending_overlay_action: OverlayAction = .none;
pub var pending_overlay_index: usize = 0;

fn handleOverlaySelect(fd: posix.fd_t, payload: []const u8) void {
    var r = proto.PayloadReader.init(payload);
    const index: usize = @intCast(@max(r.readInt(), 0));
    pending_overlay_action = .select;
    pending_overlay_index = index;
    // ACK
    var buf: [16]u8 = undefined;
    var w = proto.PayloadWriter.init(&buf);
    w.writeU8(1); // ok
    writeToFd(fd, .resp_success, w.written());
}

fn handleOverlayDismiss(fd: posix.fd_t) void {
    pending_overlay_action = .dismiss;
    var buf: [16]u8 = undefined;
    var w = proto.PayloadWriter.init(&buf);
    w.writeU8(1);
    writeToFd(fd, .resp_success, w.written());
}

fn handleHandshake(fd: posix.fd_t, payload: []const u8) void {
    var r = proto.PayloadReader.init(payload);
    const attyx_path = r.readStr();
    const pane_id = r.readStr();

    // Store Attyx socket path
    const len = @min(attyx_path.len, attyx_socket_buf.len);
    @memcpy(attyx_socket_buf[0..len], attyx_path[0..len]);
    attyx_socket_len = len;

    // Store pane ID
    const pid_len = @min(pane_id.len, attyx_pane_id_buf.len);
    @memcpy(attyx_pane_id_buf[0..pid_len], pane_id[0..pid_len]);
    attyx_pane_id_len = pid_len;

    attyx_connected = true;

    // Respond with xyron's socket path, name, version
    var buf: [512]u8 = undefined;
    var w = proto.PayloadWriter.init(&buf);
    w.writeStr(if (getSocketPath()) |p| p else "");
    w.writeStr("xyron");
    w.writeStr("0.1.0");
    writeToFd(fd, .resp_success, w.written());
}

fn handleGetCompletions(fd: posix.fd_t, payload: []const u8) void {
    var r = proto.PayloadReader.init(payload);
    const req_id = r.readInt();
    const buffer = r.readStr();
    const cursor: usize = @intCast(@max(r.readInt(), 0));

    const e = env orelse return;
    const cc = cmd_cache orelse return;

    const result = complete_mod.getCompletions(buffer, @min(cursor, buffer.len), e, cc, help_cache);

    var buf: [proto.MAX_PAYLOAD]u8 = undefined;
    var w = proto.PayloadWriter.init(&buf);
    w.writeInt(req_id);
    w.writeU8(@intFromEnum(result.context.kind));
    w.writeInt(@intCast(result.context.word_start));
    w.writeInt(@intCast(result.context.word_end));
    w.writeInt(@intCast(result.sorted_count));

    const max_send = @min(result.sorted_count, 50);
    for (0..max_send) |i| {
        const idx = result.sorted_indices[i];
        const cand = &result.candidates.items[idx];
        w.writeStr(cand.textSlice());
        w.writeStr(cand.descSlice());
        w.writeU8(@intFromEnum(cand.kind));
        w.writeInt(result.sorted_scores[i]);
    }

    writeToFd(fd, .resp_success, w.written());
}

fn handleGetGhost(fd: posix.fd_t, payload: []const u8) void {
    var r = proto.PayloadReader.init(payload);
    const req_id = r.readInt();
    const buffer = r.readStr();

    var buf: [1024]u8 = undefined;
    var w = proto.PayloadWriter.init(&buf);
    w.writeInt(req_id);

    if (history) |h| {
        if (h.findGhost(buffer)) |s| {
            w.writeU8(1);
            w.writeStr(s);
        } else {
            w.writeU8(0);
        }
    } else {
        w.writeU8(0);
    }

    writeToFd(fd, .resp_success, w.written());
}

fn handleGetShellState(fd: posix.fd_t, payload: []const u8) void {
    var r = proto.PayloadReader.init(payload);
    const req_id = r.readInt();

    var buf: [1024]u8 = undefined;
    var w = proto.PayloadWriter.init(&buf);
    w.writeInt(req_id);

    // CWD
    var cwd_buf: [512]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "?";
    w.writeStr(cwd);

    // Last exit code
    const input_mod = @import("input.zig");
    w.writeU8(input_mod.prompt_last_exit);

    // Job count
    var job_count: i64 = 0;
    if (job_table) |jt| {
        for (jt.allJobs()) |*j| {
            if (j.state == .running or j.state == .stopped) job_count += 1;
        }
    }
    w.writeInt(job_count);

    writeToFd(fd, .resp_success, w.written());
}

fn handleGetHistory(fd: posix.fd_t, payload: []const u8) void {
    var r = proto.PayloadReader.init(payload);
    const req_id = r.readInt();
    const limit = r.readInt();

    const hdb = history_db orelse {
        var buf: [64]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeInt(0);
        writeToFd(fd, .resp_success, w.written());
        return;
    };

    var entries: [50]history_db_mod.HistoryEntry = undefined;
    var str_buf: [50 * 256]u8 = undefined;
    const count = hdb.recentEntries(entries[0..@min(@as(usize, @intCast(limit)), 50)], &str_buf);

    var buf: [proto.MAX_PAYLOAD]u8 = undefined;
    var w = proto.PayloadWriter.init(&buf);
    w.writeInt(req_id);
    w.writeInt(@intCast(count));

    for (entries[0..count]) |*e| {
        w.writeInt(e.id);
        w.writeStr(e.raw_input);
        w.writeStr(e.cwd);
        w.writeInt(e.exit_code);
        w.writeInt(e.started_at);
    }

    writeToFd(fd, .resp_success, w.written());
}

fn handleQueryHistory(fd: posix.fd_t, payload: []const u8) void {
    var r = proto.PayloadReader.init(payload);
    const req_id = r.readInt();
    const text = r.readStr();
    const cwd_filter = r.readStr();
    const failed = r.readU8();
    const limit = r.readInt();

    const hdb = history_db orelse {
        var buf: [64]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeInt(0);
        writeToFd(fd, .resp_success, w.written());
        return;
    };

    var query = history_db_mod.HistoryQuery{};
    if (text.len > 0) query.text_contains = text;
    if (cwd_filter.len > 0) query.cwd_filter = cwd_filter;
    if (failed == 1) query.only_failed = true;
    query.limit = @min(@as(usize, @intCast(limit)), 50);

    var entries: [50]history_db_mod.HistoryEntry = undefined;
    var str_buf: [50 * 256]u8 = undefined;
    const count = hdb.query(&query, entries[0..50], &str_buf);

    var buf: [proto.MAX_PAYLOAD]u8 = undefined;
    var w = proto.PayloadWriter.init(&buf);
    w.writeInt(req_id);
    w.writeInt(@intCast(count));

    for (entries[0..count]) |*e| {
        w.writeInt(e.id);
        w.writeStr(e.raw_input);
        w.writeStr(e.cwd);
        w.writeInt(e.exit_code);
        w.writeInt(e.started_at);
    }

    writeToFd(fd, .resp_success, w.written());
}

fn handleListJobs(fd: posix.fd_t, payload: []const u8) void {
    var r = proto.PayloadReader.init(payload);
    const req_id = r.readInt();

    var buf: [proto.MAX_PAYLOAD]u8 = undefined;
    var w = proto.PayloadWriter.init(&buf);
    w.writeInt(req_id);

    const jt = job_table orelse {
        w.writeInt(0);
        writeToFd(fd, .resp_success, w.written());
        return;
    };

    const jobs = jt.allJobs();
    w.writeInt(@intCast(jobs.len));

    for (jobs) |*j| {
        w.writeInt(@intCast(j.id));
        w.writeStr(j.rawInputSlice());
        w.writeU8(@intFromEnum(j.state));
        w.writeU8(j.exit_code);
    }

    writeToFd(fd, .resp_success, w.written());
}

// ---------------------------------------------------------------------------
// Write helper
// ---------------------------------------------------------------------------

fn writeToFd(fd: posix.fd_t, msg_type: proto.MsgType, payload: []const u8) void {
    var hdr: [proto.header_size]u8 = undefined;
    const len: u32 = @intCast(payload.len);
    hdr[0] = @truncate(len);
    hdr[1] = @truncate(len >> 8);
    hdr[2] = @truncate(len >> 16);
    hdr[3] = @truncate(len >> 24);
    hdr[4] = @intFromEnum(msg_type);
    _ = posix.write(fd, &hdr) catch {};
    _ = posix.write(fd, payload) catch {};
}
