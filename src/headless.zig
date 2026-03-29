// headless.zig — Headless runtime mode.
//
// Xyron runs as a backend: no terminal UI, no line editor. Reads
// binary protocol requests from stdin, dispatches to the existing
// runtime, emits events and output to stdout. Attyx acts as frontend.

const std = @import("std");
const posix = std.posix;
const proto = @import("protocol.zig");

// C externs not available in Zig's std.c on macOS
const c_ext = struct {
    extern "c" fn openpty(master: *posix.fd_t, slave: *posix.fd_t, name: ?*anyopaque, termp: ?*anyopaque, winp: ?*anyopaque) c_int;
    extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;
    extern "c" fn setsid() posix.pid_t;
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern "c" fn kill(pid: posix.pid_t, sig: c_int) c_int;
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _exit(status: c_int) noreturn;
};
const types = @import("types.zig");
const parser = @import("parser.zig");
const planner_mod = @import("planner.zig");
const environ_mod = @import("environ.zig");
const expand = @import("expand.zig");
const history_db_mod = @import("history_db.zig");
const history_mod = @import("history.zig");
const jobs_mod = @import("jobs.zig");
const lua_api = @import("lua_api.zig");
const lua_hooks = @import("lua_hooks.zig");
const attyx_mod = @import("attyx.zig");
const prompt_mod = @import("prompt.zig");

const STDIN = posix.STDIN_FILENO;
const STDOUT = posix.STDOUT_FILENO;

const is_macos = @import("builtin").os.tag == .macos;
const TIOCSCTTY: c_ulong = if (is_macos) 0x20007461 else 0x540E;
const TIOCSWINSZ: c_ulong = if (is_macos) 0x80087467 else 0x5414;

pub const HeadlessRuntime = struct {
    allocator: std.mem.Allocator,
    ids: types.IdGenerator,
    env: environ_mod.Environ,
    history_db: history_db_mod.HistoryDb,
    job_table: jobs_mod.JobTable,
    lua: lua_api.LuaState,
    json_mode: bool,
    session_id: [32]u8,
    session_id_len: usize,
    last_exit_code: u8 = 0,

    // Active command PTY state
    cmd_master_fd: posix.fd_t = -1,
    cmd_pid: posix.pid_t = 0,
    cmd_group_id: u64 = 0,
    cmd_input_buf: [256]u8 = undefined,
    cmd_input_len: usize = 0,
    cmd_start_ms: i64 = 0,
    pty_rows: u16 = 24,
    pty_cols: u16 = 80,

    pub fn init(allocator: std.mem.Allocator, json_mode: bool) !HeadlessRuntime {
        var attyx = attyx_mod.Attyx.disabled(); // no OSC events in headless

        var sid_buf: [32]u8 = undefined;
        const ts = types.timestampMs();
        const pid = std.c.getpid();
        const sid_len = std.fmt.count("{d}-{d}", .{ pid, ts });
        _ = std.fmt.bufPrint(&sid_buf, "{d}-{d}", .{ pid, ts }) catch {};

        const hdb = history_db_mod.HistoryDb.init(allocator, sid_buf[0..sid_len]);
        var env_inst = try environ_mod.Environ.init(allocator, &attyx);
        const lua = lua_api.init(&env_inst, false);

        // Load config
        loadConfig(lua);

        return .{
            .allocator = allocator,
            .ids = .{},
            .env = env_inst,
            .history_db = hdb,
            .job_table = .{},
            .lua = lua,
            .json_mode = json_mode,
            .session_id = sid_buf,
            .session_id_len = sid_len,
        };
    }

    pub fn deinit(self: *HeadlessRuntime) void {
        lua_api.deinit(self.lua);
        self.history_db.deinit();
        self.env.deinit();
    }

    /// Main headless loop — poll both stdin (protocol) and active PTY, multiplex.
    pub fn run(self: *HeadlessRuntime) void {
        self.emitReady();

        var frame_buf: [proto.MAX_PAYLOAD + proto.header_size]u8 = undefined;
        var pty_buf: [16384]u8 = undefined;

        while (true) {
            // Build poll set: always stdin, optionally active command PTY
            var fds: [2]posix.pollfd = undefined;
            fds[0] = .{ .fd = STDIN, .events = posix.POLL.IN, .revents = 0 };
            var nfds: usize = 1;
            if (self.cmd_master_fd >= 0) {
                fds[1] = .{ .fd = self.cmd_master_fd, .events = posix.POLL.IN, .revents = 0 };
                nfds = 2;
            }

            _ = posix.poll(fds[0..nfds], 16) catch break;

            // Drain PTY output from active command
            if (nfds > 1 and (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0)) {
                self.drainPtyOutput(&pty_buf);
            }

            // Check if child exited
            if (self.cmd_master_fd >= 0) self.checkChildExit();

            // Handle protocol requests
            if (fds[0].revents & posix.POLL.IN != 0) {
                const frame = proto.readFrame(STDIN, &frame_buf) orelse break;
                self.dispatchFrame(frame);
            }
            if (fds[0].revents & posix.POLL.HUP != 0) break;
        }
    }

    fn dispatchFrame(self: *HeadlessRuntime, frame: proto.Frame) void {
        switch (frame.msg_type) {
            .init_session => self.handleInitSession(frame.payload),
            .run_command => self.handleRunCommand(frame.payload),
            .send_input => self.handleSendInput(frame.payload),
            .resize => self.handleResize(frame.payload),
            .list_jobs => self.handleListJobs(frame.payload),
            .get_history => self.handleGetHistory(frame.payload),
            .get_shell_state => self.handleGetShellState(frame.payload),
            .get_prompt => self.handleGetPrompt(frame.payload),
            .interrupt => self.handleInterrupt(frame.payload),
            else => self.sendError(0, "unknown request"),
        }
    }

    // ------------------------------------------------------------------
    // Request handlers
    // ------------------------------------------------------------------

    fn handleInitSession(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const req_id = r.readInt();

        var buf: [1024]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeStr(self.session_id[0..self.session_id_len]);
        w.writeStr("xyron");
        w.writeStr("0.1.0");
        w.writeInt(@intCast(self.history_db.totalEntries()));

        proto.writeFrame(STDOUT, .resp_success, w.written());
    }

    fn handleRunCommand(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const req_id = r.readInt();
        const input = r.readStr();

        if (input.len == 0) {
            self.sendError(req_id, "empty command");
            return;
        }

        // Stash command input for finish event
        const copy_len = @min(input.len, self.cmd_input_buf.len);
        @memcpy(self.cmd_input_buf[0..copy_len], input[0..copy_len]);
        self.cmd_input_len = copy_len;

        const group_id = self.ids.next();
        self.cmd_group_id = group_id;
        self.cmd_start_ms = types.timestampMs();
        self.emitCommandStarted(group_id, input);

        // Spawn command in a PTY
        self.spawnCommandPty(input) catch {
            self.sendError(req_id, "spawn failed");
            self.emitCommandFinished(group_id, input, 127, 0);
            self.emitPrompt();
            return;
        };

        // Ack the request — output streams via evt_output_chunk, finish via evt_command_finished
        var buf: [16]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        proto.writeFrame(STDOUT, .resp_success, w.written());
    }

    fn handleSendInput(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const data = r.readStr();
        if (self.cmd_master_fd >= 0 and data.len > 0) {
            _ = posix.write(self.cmd_master_fd, data) catch {};
        }
    }

    fn handleResize(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const rows: u16 = @intCast(@min(@max(r.readInt(), 1), 500));
        const cols: u16 = @intCast(@min(@max(r.readInt(), 1), 500));
        self.pty_rows = rows;
        self.pty_cols = cols;
        if (self.cmd_master_fd >= 0) {
            setPtySize(self.cmd_master_fd, rows, cols);
        }
    }

    fn handleListJobs(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const req_id = r.readInt();

        var buf: [4096]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);

        const all_jobs = self.job_table.allJobs();
        w.writeInt(@intCast(all_jobs.len));
        for (all_jobs) |*j| {
            w.writeInt(@intCast(j.id));
            w.writeStr(j.rawInputSlice());
            w.writeU8(@intFromEnum(j.state));
            w.writeU8(j.exit_code);
        }

        proto.writeFrame(STDOUT, .resp_success, w.written());
    }

    fn handleGetHistory(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const req_id = r.readInt();
        const limit = r.readInt();

        var entries: [50]history_db_mod.HistoryEntry = undefined;
        var str_buf: [50 * 256]u8 = undefined;
        const count = self.history_db.recentEntries(entries[0..@min(@as(usize, @intCast(limit)), 50)], &str_buf);

        var buf: [8192]u8 = undefined;
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

        proto.writeFrame(STDOUT, .resp_success, w.written());
    }

    fn handleGetShellState(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const req_id = r.readInt();

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = posix.getcwd(&cwd_buf) catch "?";

        var buf: [4096]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeStr(cwd);
        w.writeU8(self.last_exit_code);
        w.writeInt(@intCast(self.job_table.allJobs().len));

        proto.writeFrame(STDOUT, .resp_success, w.written());
    }

    fn handleGetPrompt(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const req_id = r.readInt();

        var pbuf: [prompt_mod.MAX_PROMPT]u8 = undefined;
        const pctx = prompt_mod.buildContext(self.last_exit_code, 0, self.job_table.allJobs().len);
        const result = prompt_mod.render(&pbuf, &pctx, self.lua);

        var buf: [proto.MAX_PAYLOAD]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeStr(result.text); // full ANSI-colored prompt string
        w.writeInt(@intCast(result.visible_len));
        w.writeInt(@intCast(result.line_count));

        proto.writeFrame(STDOUT, .resp_success, w.written());
    }

    fn handleInterrupt(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const req_id = r.readInt();

        if (self.cmd_pid > 0) {
            // Send SIGINT to the foreground process group
            const pgid = c_ext.tcgetpgrp(self.cmd_master_fd);
            if (pgid > 0) {
                _ = c_ext.kill(-pgid, std.posix.SIG.INT);
            } else {
                _ = c_ext.kill(self.cmd_pid, std.posix.SIG.INT);
            }
        }

        var buf: [16]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        proto.writeFrame(STDOUT, .resp_success, w.written());
    }

    // ------------------------------------------------------------------
    // PTY-based command execution
    // ------------------------------------------------------------------

    fn spawnCommandPty(self: *HeadlessRuntime, input: []const u8) !void {
        // Null-terminate input for execvp — input points into frame buffer
        var cmd_buf: [4096]u8 = undefined;
        if (input.len >= cmd_buf.len) return error.CommandTooLong;
        @memcpy(cmd_buf[0..input.len], input);
        cmd_buf[input.len] = 0;
        const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);

        // Open PTY pair
        var master: posix.fd_t = undefined;
        var slave: posix.fd_t = undefined;
        if (c_ext.openpty(&master, &slave, null, null, null) != 0)
            return error.OpenPtyFailed;

        setPtySize(master, self.pty_rows, self.pty_cols);

        const pid = try posix.fork();
        if (pid == 0) {
            // --- Child ---
            posix.close(master);
            _ = c_ext.setsid();
            _ = c_ext.ioctl(slave, TIOCSCTTY, @as(?*anyopaque, null));

            // Redirect stdio to slave
            for ([_]posix.fd_t{ posix.STDIN_FILENO, posix.STDOUT_FILENO, posix.STDERR_FILENO }) |fd| {
                _ = posix.dup2(slave, fd) catch {};
            }
            if (slave > 2) posix.close(slave);

            _ = c_ext.setenv("TERM", "xterm-256color", 1);
            _ = c_ext.setenv("COLORTERM", "truecolor", 1);

            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z };
            _ = c_ext.execvp("/bin/sh", &argv);
            c_ext._exit(127);
        }

        // --- Parent ---
        posix.close(slave);

        // Set non-blocking on master
        const F_GETFL: c_int = 3;
        const F_SETFL: c_int = 4;
        const O_NONBLOCK: c_int = 0x0004;
        const c_fcntl = struct {
            extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
        };
        const flags = c_fcntl.fcntl(master, F_GETFL);
        _ = c_fcntl.fcntl(master, F_SETFL, flags | O_NONBLOCK);

        self.cmd_master_fd = master;
        self.cmd_pid = pid;
    }

    fn drainPtyOutput(self: *HeadlessRuntime, buf: *[16384]u8) void {
        while (true) {
            const n = posix.read(self.cmd_master_fd, buf) catch break;
            if (n == 0) break;
            self.emitOutputChunk("stdout", buf[0..n]);
        }
    }

    fn checkChildExit(self: *HeadlessRuntime) void {
        const result = posix.waitpid(self.cmd_pid, posix.W.NOHANG);
        if (result.pid == 0) return; // still running

        // Drain remaining output
        var buf: [16384]u8 = undefined;
        self.drainPtyOutput(&buf);

        const W = posix.W;
        const code: u8 = if (W.IFEXITED(result.status)) W.EXITSTATUS(result.status) else 1;
        const duration = types.timestampMs() - self.cmd_start_ms;
        const input = self.cmd_input_buf[0..self.cmd_input_len];

        lua_hooks.fireCommandFinish(self.lua, 0, input, "", code, duration, types.timestampMs());

        self.last_exit_code = code;
        self.emitCommandFinished(self.cmd_group_id, input, code, duration);

        // Record in history
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = posix.getcwd(&cwd_buf) catch "";
        _ = self.history_db.recordCommand(input, cwd, code, duration, types.timestampMs(), false, &.{});

        self.emitPrompt();

        posix.close(self.cmd_master_fd);
        self.cmd_master_fd = -1;
        self.cmd_pid = 0;
    }

    // ------------------------------------------------------------------
    // Event emission
    // ------------------------------------------------------------------

    fn emitReady(self: *HeadlessRuntime) void {
        var buf: [256]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeStr(self.session_id[0..self.session_id_len]);
        w.writeStr("0.1.0");
        proto.writeFrame(STDOUT, .evt_ready, w.written());
        // Send initial prompt
        self.emitPrompt();
    }

    fn emitPrompt(self: *HeadlessRuntime) void {
        var pbuf: [prompt_mod.MAX_PROMPT]u8 = undefined;
        const pctx = prompt_mod.buildContext(self.last_exit_code, 0, self.job_table.allJobs().len);
        const result = prompt_mod.render(&pbuf, &pctx, self.lua);

        var buf: [proto.MAX_PAYLOAD]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeStr(result.text);
        w.writeInt(@intCast(result.visible_len));
        w.writeInt(@intCast(result.line_count));
        proto.writeFrame(STDOUT, .evt_prompt, w.written());
    }

    fn emitCommandStarted(self: *HeadlessRuntime, group_id: u64, input: []const u8) void {
        _ = self;
        var buf: [1024]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(@intCast(group_id));
        w.writeStr(input);
        w.writeInt(types.timestampMs());
        proto.writeFrame(STDOUT, .evt_command_started, w.written());
    }

    fn emitCommandFinished(_: *HeadlessRuntime, group_id: u64, input: []const u8, exit_code: u8, duration_ms: i64) void {
        var buf: [1024]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(@intCast(group_id));
        w.writeStr(input);
        w.writeU8(exit_code);
        w.writeInt(duration_ms);
        w.writeInt(types.timestampMs());
        proto.writeFrame(STDOUT, .evt_command_finished, w.written());
    }

    fn emitOutputChunk(_: *HeadlessRuntime, stream: []const u8, data: []const u8) void {
        var buf: [proto.MAX_PAYLOAD]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeStr(stream);
        w.writeStr(data);
        w.writeInt(types.timestampMs());
        proto.writeFrame(STDOUT, .evt_output_chunk, w.written());
    }

    fn sendError(_: *HeadlessRuntime, req_id: i64, msg: []const u8) void {
        var buf: [256]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeStr(msg);
        proto.writeFrame(STDOUT, .resp_error, w.written());
    }
};

fn setPtySize(fd: posix.fd_t, rows: u16, cols: u16) void {
    const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
    var ws = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    _ = c_ext.ioctl(fd, TIOCSWINSZ, &ws);
}

fn loadConfig(lua: lua_api.LuaState) void {
    const home = posix.getenv("HOME") orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_home = posix.getenv("XDG_CONFIG_HOME");
    const path = if (config_home) |xdg|
        std.fmt.bufPrintZ(&buf, "{s}/xyron/config.lua", .{xdg}) catch return
    else
        std.fmt.bufPrintZ(&buf, "{s}/.config/xyron/config.lua", .{home}) catch return;
    std.fs.accessAbsolute(path, .{}) catch return;
    _ = lua_api.loadConfig(lua, path);
}
