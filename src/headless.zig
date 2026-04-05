// headless.zig — Headless runtime mode.
//
// Xyron runs as a backend: no terminal UI, no line editor. Reads
// binary protocol requests from stdin, dispatches to the existing
// runtime, emits events and output to stdout. Attyx acts as frontend.

const std = @import("std");
const posix = std.posix;
const proto = @import("protocol.zig");
const complete_mod = @import("complete.zig");
const highlight_mod = @import("highlight.zig");
const complete_help_mod = @import("complete_help.zig");

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
const ast = @import("ast.zig");
const planner_mod = @import("planner.zig");
const environ_mod = @import("environ.zig");
const expand = @import("expand.zig");
const builtins = @import("builtins/mod.zig");
const executor = @import("executor.zig");
const history_db_mod = @import("history_db.zig");
const history_mod = @import("history.zig");
const jobs_mod = @import("jobs.zig");
const lua_api = @import("lua_api.zig");
const lua_hooks = @import("lua_hooks.zig");
const lua_commands = @import("lua_commands.zig");
const attyx_mod = @import("attyx.zig");
const prompt_mod = @import("prompt.zig");

const STDIN = posix.STDIN_FILENO;
const STDOUT = posix.STDOUT_FILENO;

const style_mod = @import("style.zig");

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
    cmd_cache: highlight_mod.CommandCache,
    help_cache: complete_help_mod.HelpCache,
    // Note: History struct is ~4MB, too large for stack.
    // Use a heap-allocated pointer instead.
    history_buf: ?*history_mod.History = null,

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

        const hist_ptr = if (history_mod.History.init(allocator)) |h| blk: {
            const ptr = allocator.create(history_mod.History) catch break :blk @as(?*history_mod.History, null);
            ptr.* = h;
            break :blk ptr;
        } else |_| null;

        return .{
            .allocator = allocator,
            .ids = .{},
            .env = env_inst,
            .history_db = hdb,
            .job_table = .{},
            .cmd_cache = highlight_mod.CommandCache.init(allocator),
            .help_cache = complete_help_mod.HelpCache.init(hdb.db),
            .history_buf = hist_ptr,
            .lua = lua,
            .json_mode = json_mode,
            .session_id = sid_buf,
            .session_id_len = sid_len,
        };
    }

    pub fn deinit(self: *HeadlessRuntime) void {
        self.cmd_cache.deinit();
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
            .get_completions => self.handleGetCompletions(frame.payload),
            .get_ghost => self.handleGetGhost(frame.payload),
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

        // Parse → Expand through xyron's full pipeline
        var pipeline = parser.parse(self.allocator, input) catch {
            // Parse failed — fall back to /bin/sh -c
            self.spawnCommandPtyRaw(input) catch {
                self.sendError(req_id, "spawn failed");
                self.emitCommandFinished(group_id, input, 127, 0);
                self.emitPrompt();
                return;
            };
            var buf2: [16]u8 = undefined;
            var w2 = proto.PayloadWriter.init(&buf2);
            w2.writeInt(req_id);
            proto.writeFrame(STDOUT, .resp_success, w2.written());
            return;
        };
        defer pipeline.deinit(self.allocator);

        var expanded = expand.expandPipeline(self.allocator, &pipeline, &self.env) catch {
            // Expand failed — fall back to /bin/sh -c
            self.spawnCommandPtyRaw(input) catch {
                self.sendError(req_id, "spawn failed");
                self.emitCommandFinished(group_id, input, 127, 0);
                self.emitPrompt();
                return;
            };
            var buf2: [16]u8 = undefined;
            var w2 = proto.PayloadWriter.init(&buf2);
            w2.writeInt(req_id);
            proto.writeFrame(STDOUT, .resp_success, w2.written());
            return;
        };
        defer expand.freeExpandedPipeline(self.allocator, &expanded);

        // Check for single builtin command (no pipeline, no background)
        if (expanded.commands.len == 1 and !expanded.background) {
            const cmd = &expanded.commands[0];
            if (cmd.argv.len > 0 and builtins.isBuiltin(cmd.argv[0])) {
                self.executeBuiltin(req_id, input, group_id, cmd.argv);
                return;
            }
        }

        // External command: spawn in PTY with expanded argv
        self.spawnCommandPtyArgv(&expanded) catch {
            // Fall back to /bin/sh -c
            self.spawnCommandPtyRaw(input) catch {
                self.sendError(req_id, "spawn failed");
                self.emitCommandFinished(group_id, input, 127, 0);
                self.emitPrompt();
                return;
            };
            var buf2: [16]u8 = undefined;
            var w2 = proto.PayloadWriter.init(&buf2);
            w2.writeInt(req_id);
            proto.writeFrame(STDOUT, .resp_success, w2.written());
            return;
        };

        // Ack — output streams via evt_output_chunk, finish via evt_command_finished
        var buf: [16]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        proto.writeFrame(STDOUT, .resp_success, w.written());
    }

    /// Execute a builtin command in-process, capturing output via pipe.
    fn executeBuiltin(self: *HeadlessRuntime, req_id: i64, input: []const u8, group_id: u64, argv: []const []const u8) void {
        // Create a pipe to capture builtin stdout
        const out_pipe = posix.pipe() catch {
            self.sendError(req_id, "pipe failed");
            return;
        };
        // Create File from write end
        const write_file = std.fs.File{ .handle = out_pipe[1] };
        const stderr_file = std.fs.File{ .handle = posix.STDERR_FILENO };

        const result = builtins.execute(argv, write_file, stderr_file, &self.env, &self.history_db, &self.job_table);
        posix.close(out_pipe[1]); // close write end so read gets EOF

        // Read captured output
        var out_buf: [32768]u8 = undefined;
        var out_len: usize = 0;
        while (out_len < out_buf.len) {
            const n = posix.read(out_pipe[0], out_buf[out_len..]) catch break;
            if (n == 0) break;
            out_len += n;
        }
        posix.close(out_pipe[0]);

        if (out_len > 0) {
            // Convert bare LF to CRLF — builtins write through a pipe (no PTY
            // to do the ONLCR translation), but the terminal engine expects CR+LF.
            var crlf_buf: [65536]u8 = undefined;
            var crlf_len: usize = 0;
            for (out_buf[0..out_len]) |byte| {
                if (byte == '\n' and (crlf_len == 0 or crlf_buf[crlf_len - 1] != '\r')) {
                    if (crlf_len < crlf_buf.len) { crlf_buf[crlf_len] = '\r'; crlf_len += 1; }
                }
                if (crlf_len < crlf_buf.len) { crlf_buf[crlf_len] = byte; crlf_len += 1; }
            }
            self.emitOutputChunk("stdout", crlf_buf[0..crlf_len]);
        }

        const duration = types.timestampMs() - self.cmd_start_ms;
        const code = result.exit_code;
        self.last_exit_code = code;

        lua_hooks.fireCommandFinish(self.lua, 0, input, "", code, duration, types.timestampMs());
        self.emitCommandFinished(group_id, input, code, duration);

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = posix.getcwd(&cwd_buf) catch "";
        _ = self.history_db.recordCommand(input, cwd, code, duration, types.timestampMs(), false, &.{});

        self.emitPrompt();

        // Respond
        var buf: [64]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeU8(code);
        w.writeInt(duration);
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
    // Completion and ghost text API
    // ------------------------------------------------------------------

    fn handleGetCompletions(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const req_id = r.readInt();
        const buffer = r.readStr();
        const cursor: usize = @intCast(@max(r.readInt(), 0));

        const result = complete_mod.getCompletions(
            buffer,
            @min(cursor, buffer.len),
            &self.env,
            &self.cmd_cache,
            &self.help_cache,
        );

        // Response schema:
        // req_id:i64
        // context_kind:u8 (0=command, 1=argument, 2=flag, 3=env_var, 4=redirect, 5=none)
        // word_start:i64
        // word_end:i64
        // count:i64
        // per candidate:
        //   text:str
        //   description:str
        //   kind:u8 (0=builtin, 1=lua_cmd, 2=alias, 3=external_cmd, 4=file, 5=directory, 6=env_var, 7=flag)
        //   score:i64

        var buf: [proto.MAX_PAYLOAD]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        w.writeU8(@intFromEnum(result.context.kind));
        w.writeInt(@intCast(result.context.word_start));
        w.writeInt(@intCast(result.context.word_end));
        w.writeInt(@intCast(result.sorted_count));

        const max_send = @min(result.sorted_count, 50); // cap at 50 for payload size
        for (0..max_send) |i| {
            const idx = result.sorted_indices[i];
            const cand = &result.candidates.items[idx];
            w.writeStr(cand.textSlice());
            w.writeStr(cand.descSlice());
            w.writeU8(@intFromEnum(cand.kind));
            w.writeInt(result.sorted_scores[i]);
        }

        proto.writeFrame(STDOUT, .resp_success, w.written());
    }

    fn handleGetGhost(self: *HeadlessRuntime, payload: []const u8) void {
        var r = proto.PayloadReader.init(payload);
        const req_id = r.readInt();
        const buffer = r.readStr();

        // Find ghost suggestion from in-memory history
        const suggestion = if (self.history_buf) |h| h.findGhost(buffer) else null;

        var buf: [1024]u8 = undefined;
        var w = proto.PayloadWriter.init(&buf);
        w.writeInt(req_id);
        if (suggestion) |s| {
            w.writeU8(1); // has_suggestion
            w.writeStr(s); // full suggestion (including typed prefix)
        } else {
            w.writeU8(0); // no suggestion
        }

        proto.writeFrame(STDOUT, .resp_success, w.written());
    }

    // ------------------------------------------------------------------
    // PTY-based command execution
    // ------------------------------------------------------------------

    /// Spawn an external command in a PTY using expanded argv from the planner.
    fn spawnCommandPtyArgv(self: *HeadlessRuntime, expanded: *const ast.Pipeline) !void {
        // For pipelines, fall back to /bin/sh -c with the raw input
        if (expanded.commands.len != 1) {
            return self.spawnCommandPtyRaw(self.cmd_input_buf[0..self.cmd_input_len]);
        }

        const cmd = &expanded.commands[0];
        if (cmd.argv.len == 0) return error.EmptyCommand;

        // Build null-terminated argv array for execvp
        var argv_buf: [33]?[*:0]const u8 = .{null} ** 33;
        var argv_z_storage: [32][256]u8 = undefined;
        const argc = @min(cmd.argv.len, 32);
        for (0..argc) |i| {
            const arg = cmd.argv[i];
            if (arg.len >= 256) return error.ArgTooLong;
            @memcpy(argv_z_storage[i][0..arg.len], arg);
            argv_z_storage[i][arg.len] = 0;
            argv_buf[i] = @ptrCast(&argv_z_storage[i]);
        }
        argv_buf[argc] = null;

        return self.spawnPty(@ptrCast(&argv_buf));
    }

    /// Spawn a command via /bin/sh -c (fallback for pipelines).
    fn spawnCommandPtyRaw(self: *HeadlessRuntime, input: []const u8) !void {
        var cmd_buf: [4096]u8 = undefined;
        if (input.len >= cmd_buf.len) return error.CommandTooLong;
        @memcpy(cmd_buf[0..input.len], input);
        cmd_buf[input.len] = 0;
        const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);

        var argv_buf = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z };
        return self.spawnPty(@ptrCast(&argv_buf));
    }

    /// Low-level PTY spawn with a null-terminated argv array.
    fn spawnPty(self: *HeadlessRuntime, argv: [*:null]const ?[*:0]const u8) !void {
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
            _ = c_ext.ioctl(slave, style_mod.TIOCSCTTY, @as(?*anyopaque, null));

            for ([_]posix.fd_t{ posix.STDIN_FILENO, posix.STDOUT_FILENO, posix.STDERR_FILENO }) |fd| {
                _ = posix.dup2(slave, fd) catch {};
            }
            if (slave > 2) posix.close(slave);

            _ = c_ext.setenv("TERM", "xterm-256color", 1);
            _ = c_ext.setenv("COLORTERM", "truecolor", 1);

            _ = c_ext.execvp(argv[0].?, argv);
            c_ext._exit(127);
        }

        // --- Parent ---
        posix.close(slave);

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

        // Record in history + push to in-memory buffer for ghost text
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = posix.getcwd(&cwd_buf) catch "";
        _ = self.history_db.recordCommand(input, cwd, code, duration, types.timestampMs(), false, &.{});
        if (self.history_buf) |h| h.push(input);

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
    var ws = style_mod.Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    _ = c_ext.ioctl(fd, style_mod.TIOCSWINSZ, &ws);
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
