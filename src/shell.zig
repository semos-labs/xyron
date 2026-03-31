// shell.zig — Interactive REPL loop.
//
// Phase 7: Lua integration. Initializes Lua VM, loads config,
// fires hooks on command/cwd/job events, dispatches Lua commands.

const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");
const parser = @import("parser.zig");
const planner_mod = @import("planner.zig");
const executor = @import("executor.zig");
const attyx_mod = @import("attyx.zig");
const prompt_mod = @import("prompt.zig");
const term = @import("term.zig");
const input = @import("input.zig");
const editor_mod = @import("editor.zig");
const environ_mod = @import("environ.zig");
const expand = @import("expand.zig");
const history_mod = @import("history.zig");
const history_db_mod = @import("history_db.zig");
const jobs_mod = @import("jobs.zig");
const lua_api = @import("lua_api.zig");
const lua_hooks = @import("lua_hooks.zig");
const lua_commands = @import("lua_commands.zig");
const highlight = @import("highlight.zig");
const aliases_mod = @import("aliases.zig");
const complete_help = @import("complete_help.zig");
const block_mod = @import("block.zig");
const overlay = @import("overlay.zig");
const ipc = @import("ipc.zig");

pub const Shell = struct {
    allocator: std.mem.Allocator,
    ids: types.IdGenerator,
    attyx: attyx_mod.Attyx,
    env: environ_mod.Environ,
    history: history_mod.History,
    history_db: history_db_mod.HistoryDb,
    job_table: jobs_mod.JobTable,
    blocks: block_mod.BlockTable,
    cmd_cache: highlight.CommandCache,
    help_cache: complete_help.HelpCache,
    lua: lua_api.LuaState,
    last_exit_code: u8,
    last_duration_ms: i64,
    running: bool,
    ipc_enabled: bool,

    pub fn init(allocator: std.mem.Allocator) !Shell {
        var attyx = attyx_mod.Attyx.init();
        executor.initShellPgid();
        installSignalHandlers();

        var sid_buf: [32]u8 = undefined;
        const ts = types.timestampMs();
        const pid = std.c.getpid();
        const sid_len = std.fmt.count("{d}-{d}", .{ pid, ts });
        _ = std.fmt.bufPrint(&sid_buf, "{d}-{d}", .{ pid, ts }) catch {};

        var hdb = history_db_mod.HistoryDb.init(allocator, sid_buf[0..sid_len]);
        var hist = history_mod.History{};
        loadRecentHistory(&hdb, &hist);
        attyx.historyInitialized(hdb.totalEntries());

        var env_inst = try environ_mod.Environ.init(allocator, &attyx);

        // Initialize Lua
        const lua = lua_api.init(&env_inst, attyx.enabled);
        loadLuaConfig(lua);

        return .{
            .allocator = allocator,
            .ids = .{},
            .attyx = attyx,
            .env = env_inst,
            .history = hist,
            .history_db = hdb,
            .job_table = .{},
            .blocks = .{},
            .cmd_cache = highlight.CommandCache.init(allocator),
            .help_cache = complete_help.HelpCache.init(hdb.db),
            .lua = lua,
            .last_exit_code = 0,
            .last_duration_ms = 0,
            .running = true,
            .ipc_enabled = false,
        };
    }

    fn activeJobCount(self: *const Shell) usize {
        var count: usize = 0;
        for (self.job_table.allJobs()) |*j| {
            if (j.state == .running or j.state == .stopped) count += 1;
        }
        return count;
    }

    pub fn deinit(self: *Shell) void {
        self.cmd_cache.deinit();
        lua_api.deinit(self.lua);
        self.history_db.deinit();
        self.env.deinit();
    }

    pub fn run(self: *Shell) !void {
        const stdout = std.fs.File.stdout();
        lua_api.setBlockTable(&self.blocks);
        lua_api.setHistoryDb(&self.history_db);

        // Start IPC socket if --ipc flag was passed
        if (self.ipc_enabled) {
            ipc.env = &self.env;
            ipc.cmd_cache = &self.cmd_cache;
            ipc.help_cache = &self.help_cache;
            ipc.history = &self.history;
            ipc.history_db = &self.history_db;
            ipc.job_table = &self.job_table;
            if (ipc.start()) |path| {
                // Notify via OSC if inside Attyx
                if (self.attyx.enabled) {
                    var evt_buf: [512]u8 = undefined;
                    const evt = std.fmt.bufPrint(&evt_buf,
                        "\x1b]7339;xyron:{{\"event\":\"ipc_ready\",\"socket\":\"{s}\"}}\x07",
                        .{path},
                    ) catch "";
                    self.attyx.stderr.writeAll(evt) catch {};
                }
            }
        }
        defer ipc.stop();

        term.enableRawMode() catch {
            try self.runCooked();
            return;
        };
        defer term.disableRawMode();

        // Set beam (line) cursor on startup, restore block on exit
        stdout.writeAll("\x1b[6 q") catch {};
        defer stdout.writeAll("\x1b[2 q") catch {};

        var ed = editor_mod.Editor{};
        ed.vim_enabled = lua_api.vim_mode_enabled;

        while (self.running) {
            // Invalidate command cache if PATH changed
            if (self.env.path_dirty) {
                self.cmd_cache.invalidate();
                self.env.path_dirty = false;
            }

            self.reapAndNotify(stdout);
            if (self.ipc_enabled) ipc.poll();

            // Re-render blocks on terminal resize
            if (winch_pending) {
                winch_pending = false;
                const block_ui_mod = @import("block_ui.zig");
                if (block_ui_mod.enabled) {
                    block_ui_mod.reRenderVisible(stdout);
                    // Update cursor estimate after re-render
                    input.cursor_row_estimate = overlay.getTermSize().rows;
                }
                input.prompt_fresh = true;
            }

            // Build prompt from segments
            var pctx = prompt_mod.buildContext(self.last_exit_code, self.last_duration_ms, self.activeJobCount());
            pctx.vim_normal = ed.vim_enabled and ed.mode == .normal;
            var prompt_buf: [prompt_mod.MAX_PROMPT]u8 = undefined;
            const prompt_result = prompt_mod.render(&prompt_buf, &pctx, self.lua);
            const prompt_str = prompt_result.text;
            input.prompt_extra_lines = if (prompt_result.line_count > 1) prompt_result.line_count - 1 else 0;

            // First prompt — estimate near top
            if (input.cursor_row_estimate == 0) {
                input.cursor_row_estimate = prompt_result.line_count;
            }

            // Store prompt state for live re-rendering in vim mode
            input.prompt_fresh = true;
            input.prompt_last_exit = self.last_exit_code;
            input.history_db_ref = &self.history_db;
            input.prompt_last_duration = self.last_duration_ms;
            input.prompt_job_count = self.activeJobCount();
            input.prompt_lua = self.lua;

            const hl_ctx = input.HighlightCtx{ .cache = &self.cmd_cache, .env = &self.env, .help_cache = &self.help_cache };
            input.refreshLine(stdout, prompt_str, &ed, &hl_ctx);

            const result = input.readLine(&ed, prompt_str, &self.history, &hl_ctx) catch |err| {
                var msg_buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "\r\nxyron: input error: {s}\r\n", .{@errorName(err)}) catch "\r\nxyron: input error\r\n";
                stdout.writeAll(msg) catch {};
                continue;
            };

            switch (result) {
                .line => |line| {
                    if (line.len > 0) {
                        var line_copy: [editor_mod.MAX_LINE]u8 = undefined;
                        @memcpy(line_copy[0..line.len], line);
                        self.executeLine(line_copy[0..line.len]);
                        // Estimate cursor row after command execution.
                        // In block UI mode, use the saved block line count for accuracy.
                        // Otherwise assume the output filled the screen.
                        const trimmed_cmd = std.mem.trim(u8, line, " \t\r\n");
                        const block_ui_mod = @import("block_ui.zig");
                        if (std.mem.eql(u8, trimmed_cmd, "clear") or std.mem.eql(u8, trimmed_cmd, "reset")) {
                            input.cursor_row_estimate = 1 + input.prompt_extra_lines;
                        } else if (block_ui_mod.enabled and block_ui_mod.saved_block_lines > 0) {
                            // Block rendered: previous row + block lines + prompt lines
                            const new_row = input.cursor_row_estimate + block_ui_mod.saved_block_lines + 1 + input.prompt_extra_lines;
                            const term_rows = overlay.getTermSize().rows;
                            input.cursor_row_estimate = @min(new_row, term_rows);
                        } else if (block_ui_mod.storedOutputLines() > 0) {
                            // Non-block: use stored output line count
                            const out_lines = block_ui_mod.storedOutputLines();
                            const new_row = input.cursor_row_estimate + out_lines + 1 + input.prompt_extra_lines;
                            const term_rows = overlay.getTermSize().rows;
                            input.cursor_row_estimate = @min(new_row, term_rows);
                        } else {
                            input.cursor_row_estimate = overlay.getTermSize().rows;
                        }

                        // Check for replay (history rerun)
                        const hist_cmd = @import("builtins/history.zig");
                        if (hist_cmd.replay_pending) {
                            hist_cmd.replay_pending = false;
                            self.executeLine(hist_cmd.replay_command[0..hist_cmd.replay_len]);
                        }
                    }
                    ed.clear();
                },
                .interrupt => {},
                .eof => break,
            }
        }
    }

    fn runCooked(self: *Shell) !void {
        const stdin = std.fs.File.stdin();
        const stdout = std.fs.File.stdout();
        const stderr = std.fs.File.stderr();
        var read_buf: [8192]u8 = undefined;
        var reader = stdin.reader(&read_buf);

        while (self.running) {
            self.reapAndNotify(stdout);
            const pctx = prompt_mod.buildContext(self.last_exit_code, self.last_duration_ms, self.activeJobCount());
            prompt_mod.renderPrompt(stdout, &pctx, self.lua);
            const maybe_line = reader.interface.takeDelimiter('\n') catch |err| {
                var msg_buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "xyron: read error: {s}\n", .{@errorName(err)}) catch "xyron: read error\n";
                stderr.writeAll(msg) catch {};
                continue;
            };
            const line = maybe_line orelse { stdout.writeAll("\n") catch {}; break; };
            self.executeLine(line);
        }
    }

    fn executeLine(self: *Shell, line: []const u8) void {
        const stderr = std.fs.File.stderr();
        const stdout = std.fs.File.stdout();
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;

        self.history.push(trimmed);

        // Alias expansion: replace first word if it's an alias
        var expanded_buf: [editor_mod.MAX_LINE]u8 = undefined;
        var input_to_parse = trimmed;
        {
            // Find the first word
            var end: usize = 0;
            while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t') : (end += 1) {}
            if (aliases_mod.get(trimmed[0..end])) |expansion| {
                // Build: expansion + rest of input
                var pos: usize = 0;
                const el = @min(expansion.len, expanded_buf.len);
                @memcpy(expanded_buf[0..el], expansion[0..el]);
                pos += el;
                // Append the rest (after the alias name)
                const rest = trimmed[end..];
                const rl = @min(rest.len, expanded_buf.len - pos);
                @memcpy(expanded_buf[pos..][0..rl], rest[0..rl]);
                pos += rl;
                input_to_parse = expanded_buf[0..pos];
            }
        }

        // Detect bash/sh commands and delegate to /bin/sh
        if (shouldDelegateToSh(input_to_parse)) {
            self.runViaSh(input_to_parse, trimmed);
            return;
        }

        // Parse
        var pipeline = parser.parse(self.allocator, input_to_parse) catch |err| {
            const msg = switch (err) {
                parser.ParseError.EmptyInput => return,
                parser.ParseError.MissingRedirectTarget => "xyron: syntax error: missing redirect target\n",
                parser.ParseError.EmptyPipelineSegment => "xyron: syntax error: empty pipeline segment\n",
                parser.ParseError.UnexpectedPipe => "xyron: syntax error: unexpected pipe\n",
                else => "xyron: parse error\n",
            };
            stderr.writeAll(msg) catch {};
            return;
        };
        defer pipeline.deinit(self.allocator);

        // Expand
        var expanded = expand.expandPipeline(self.allocator, &pipeline, &self.env) catch {
            stderr.writeAll("xyron: expansion error\n") catch {};
            return;
        };
        defer expand.freeExpandedPipeline(self.allocator, &expanded);

        // Check for single Lua command (not in pipeline, not background)
        if (expanded.commands.len == 1 and !expanded.background) {
            const cmd = &expanded.commands[0];
            if (cmd.argv.len > 0 and lua_commands.isLuaCommand(cmd.argv[0])) {
                const code = lua_commands.execute(self.lua, cmd.argv[0], cmd.argv);
                self.last_exit_code = code;
                _ = self.history_db.recordCommand(trimmed, "", code, 0, types.timestampMs(), false, &.{});
                return;
            }
        }

        var cwd_before_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_before = posix.getcwd(&cwd_before_buf) catch "";

        var exec_plan = planner_mod.plan(self.allocator, &expanded, &self.ids, trimmed, cwd_before) catch {
            stderr.writeAll("xyron: planning error\n") catch {};
            return;
        };
        defer exec_plan.deinit(self.allocator);

        const start_ts = types.timestampMs();

        // Create command block
        const block_id = self.blocks.create(exec_plan.group_id, trimmed, cwd_before, exec_plan.background);

        // Fire Lua hook: on_command_start
        lua_hooks.fireCommandStart(self.lua, exec_plan.group_id, trimmed, cwd_before, start_ts);

        // Execute
        term.suspendRawMode();
        defer term.resumeRawMode();

        const result = executor.executeGroup(&exec_plan, &self.attyx, &self.env, &self.history_db, &self.job_table);
        self.last_exit_code = result.exit_code;
        self.last_duration_ms = result.duration_ms;

        if (result.backgrounded) {
            // Block stays running — will be finalized when job completes
            if (self.blocks.findById(block_id)) |blk| blk.is_background = true;
            const job_id = self.job_table.createJob(
                exec_plan.group_id, trimmed, result.pids[0..result.pid_count], result.pgid, true,
            );
            if (job_id) |id| {
                if (self.blocks.findById(block_id)) |blk| blk.job_id = id;
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "[{d}] {s}\n", .{ id, trimmed }) catch "";
                stdout.writeAll(msg) catch {};
                self.attyx.jobStarted(id, exec_plan.group_id, trimmed, cwd_before);
                lua_hooks.fireJobStateChange(self.lua, id, exec_plan.group_id, trimmed, "", "running", types.timestampMs());
            }
            _ = self.history_db.recordCommand(trimmed, cwd_before, 0, 0, start_ts, false, &.{});
            return;
        }

        if (result.stopped) {
            // Block interrupted (Ctrl+Z)
            if (self.blocks.findById(block_id)) |blk| blk.interrupt();
            const job_id = self.job_table.createJob(
                exec_plan.group_id, trimmed, result.pids[0..result.pid_count], result.pgid, true,
            );
            if (job_id) |id| {
                if (self.job_table.findById(id)) |job| job.state = .stopped;
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "\r\n[{d}]  Stopped  {s}\r\n", .{ id, trimmed }) catch "";
                stdout.writeAll(msg) catch {};
                self.attyx.jobSuspended(id, exec_plan.group_id);
                lua_hooks.fireJobStateChange(self.lua, id, exec_plan.group_id, trimmed, "running", "stopped", types.timestampMs());
            }
            return;
        }

        // Block completed
        if (self.blocks.findById(block_id)) |blk| blk.finish(result.exit_code);

        // Fire Lua hook: on_command_finish
        lua_hooks.fireCommandFinish(self.lua, exec_plan.group_id, trimmed, cwd_before, result.exit_code, result.duration_ms, types.timestampMs());

        _ = self.history_db.recordCommand(trimmed, cwd_before, result.exit_code, result.duration_ms, start_ts, false, &.{});
        if (self.history_db.totalEntries() > 0) {
            self.attyx.historyEntryRecorded(self.history_db.totalEntries(), trimmed, cwd_before, result.exit_code, result.duration_ms);
        }

        if (result.should_exit) { self.running = false; return; }

        // Detect cwd changes
        var cwd_after_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_after = posix.getcwd(&cwd_after_buf) catch "";
        if (!std.mem.eql(u8, cwd_before, cwd_after)) {
            self.attyx.cwdChanged(cwd_before, cwd_after);
            lua_hooks.fireCwdChange(self.lua, cwd_before, cwd_after, types.timestampMs());
        }
    }

    fn reapAndNotify(self: *Shell, stdout: std.fs.File) void {
        const reaped = self.job_table.reapCompleted();
        for (reaped.ids[0..reaped.count]) |id| {
            if (self.job_table.findById(id)) |job| {
                // Finalize any associated command block
                for (self.blocks.blocks[0..self.blocks.count]) |*blk| {
                    if (blk.job_id == job.id and blk.status == .running) {
                        blk.finish(job.exit_code);
                    }
                }
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "[{d}]  Done  {s}\n", .{ job.id, job.rawInputSlice() }) catch continue;
                stdout.writeAll(msg) catch {};
                self.attyx.jobFinished(job.id, job.exit_code, job.end_time - job.start_time);
                lua_hooks.fireJobStateChange(self.lua, job.id, job.group_id, job.rawInputSlice(), "running", "completed", types.timestampMs());
            }
        }
    }

    /// Run a command via /bin/sh -c. Used for bash/sh syntax delegation.
    fn runViaSh(self: *Shell, cmd: []const u8, raw: []const u8) void {
        const stdout = std.fs.File.stdout();
        const start = types.timestampMs();

        const block_ui_mod = @import("block_ui.zig");
        if (block_ui_mod.enabled and !block_ui_mod.isPassthrough(&.{cmd})) {
            // Block UI: capture output
            var sh_buf: [4096]u8 = undefined;
            const sh_cmd = std.fmt.bufPrintZ(&sh_buf, "{s}", .{cmd}) catch {
                self.last_exit_code = 127;
                return;
            };
            var child = std.process.Child.init(
                &.{ "/bin/sh", "-c", sh_cmd },
                std.heap.page_allocator,
            );
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            child.spawn() catch {
                block_ui_mod.renderBlock(stdout, raw, "xyron: failed to run via sh", 127);
                self.last_exit_code = 127;
                return;
            };

            var out_buf: [65536]u8 = undefined;
            var total: usize = 0;
            if (child.stdout) |f| {
                while (total < out_buf.len) {
                    const n = f.read(out_buf[total..]) catch break;
                    if (n == 0) break;
                    total += n;
                }
            }
            if (child.stderr) |f| {
                while (total < out_buf.len) {
                    const n = f.read(out_buf[total..]) catch break;
                    if (n == 0) break;
                    total += n;
                }
            }

            const term_result = child.wait() catch {
                block_ui_mod.renderBlock(stdout, raw, "xyron: wait failed", 127);
                self.last_exit_code = 127;
                return;
            };
            const code: u8 = switch (term_result) { .Exited => |c| c, else => 1 };

            var output = out_buf[0..total];
            while (output.len > 0 and output[output.len - 1] == '\n') output = output[0 .. output.len - 1];

            block_ui_mod.renderBlock(stdout, raw, output, code);
            self.last_exit_code = code;
        } else {
            // Non-block: run directly
            var sh_buf: [4096]u8 = undefined;
            const sh_cmd = std.fmt.bufPrintZ(&sh_buf, "{s}", .{cmd}) catch {
                self.last_exit_code = 127;
                return;
            };
            var child = std.process.Child.init(
                &.{ "/bin/sh", "-c", sh_cmd },
                std.heap.page_allocator,
            );
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            term.suspendRawMode();
            child.spawn() catch {
                term.enableRawMode() catch {};
                stdout.writeAll("xyron: failed to run via sh\n") catch {};
                self.last_exit_code = 127;
                return;
            };
            const term_result = child.wait() catch {
                term.enableRawMode() catch {};
                self.last_exit_code = 127;
                return;
            };
            term.enableRawMode() catch {};
            self.last_exit_code = switch (term_result) { .Exited => |c| c, else => 1 };
        }

        self.last_duration_ms = types.timestampMs() - start;
        _ = self.history_db.recordCommand(raw, "", self.last_exit_code, self.last_duration_ms, types.timestampMs(), false, &.{});
    }
};

fn loadLuaConfig(L: lua_api.LuaState) void {
    // XDG_CONFIG_HOME/xyron/config.lua, falling back to ~/.config/xyron/config.lua
    const config_home = std.posix.getenv("XDG_CONFIG_HOME");
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    const path = if (config_home) |xdg|
        std.fmt.bufPrintZ(&buf, "{s}/xyron/config.lua", .{xdg}) catch return
    else blk: {
        const home = std.posix.getenv("HOME") orelse return;
        break :blk std.fmt.bufPrintZ(&buf, "{s}/.config/xyron/config.lua", .{home}) catch return;
    };

    std.fs.accessAbsolute(path, .{}) catch return;

    // Set package.path so require() resolves relative to the config dir.
    // e.g. require("theme") loads ~/.config/xyron/theme.lua
    const config_dir = if (config_home) |xdg|
        std.fmt.bufPrint(buf[512..], "{s}/xyron", .{xdg}) catch ""
    else
        std.fmt.bufPrint(buf[512..], "{s}/.config/xyron", .{std.posix.getenv("HOME") orelse ""}) catch "";

    if (config_dir.len > 0) {
        lua_api.setPackagePath(L, config_dir);
    }

    _ = lua_api.loadConfig(L, path);
}

fn loadRecentHistory(hdb: *history_db_mod.HistoryDb, hist: *history_mod.History) void {
    var entries: [200]history_db_mod.HistoryEntry = undefined;
    var str_buf: [200 * 256]u8 = undefined;
    const count = hdb.recentEntries(&entries, &str_buf);
    var i = count;
    while (i > 0) { i -= 1; hist.push(entries[i].raw_input); }
}

/// Detect if a command should be delegated to /bin/sh.
/// Catches: `bash ...`, `sh ...`, `./script.sh`, and bash syntax patterns.
fn shouldDelegateToSh(line: []const u8) bool {
    // First word
    var end: usize = 0;
    while (end < line.len and line[end] != ' ' and line[end] != '\t') : (end += 1) {}
    const cmd = line[0..end];

    // Explicit sh/bash invocation
    if (std.mem.eql(u8, cmd, "sh") or std.mem.eql(u8, cmd, "bash") or
        std.mem.eql(u8, cmd, "zsh") or std.mem.eql(u8, cmd, "/bin/sh") or
        std.mem.eql(u8, cmd, "/bin/bash") or std.mem.eql(u8, cmd, "/bin/zsh"))
        return true;

    // Script file with .sh extension
    if (std.mem.endsWith(u8, cmd, ".sh")) return true;

    // Common bash syntax patterns that xyron doesn't support
    if (std.mem.startsWith(u8, line, "if [") or std.mem.startsWith(u8, line, "if [["))
        return true;
    if (std.mem.startsWith(u8, line, "for ") and std.mem.indexOf(u8, line, " in ") != null)
        return true;
    if (std.mem.startsWith(u8, line, "while ") or std.mem.startsWith(u8, line, "until "))
        return true;
    if (std.mem.startsWith(u8, line, "case "))
        return true;
    if (std.mem.indexOf(u8, line, "$(") != null)
        return true;
    if (std.mem.indexOf(u8, line, "&&") != null or std.mem.indexOf(u8, line, "||") != null)
        return true;
    if (std.mem.indexOf(u8, line, "<<") != null) // heredoc
        return true;

    return false;
}

/// Flag set by SIGWINCH handler — checked in the main loop.
var winch_pending: bool = false;

fn installSignalHandlers() void {
    const ignore = posix.Sigaction{
        .handler = .{ .handler = noop },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &ignore, null);
    posix.sigaction(posix.SIG.TSTP, &ignore, null);
    posix.sigaction(posix.SIG.TTOU, &ignore, null);
    posix.sigaction(posix.SIG.TTIN, &ignore, null);

    // SIGWINCH: re-render blocks on terminal resize
    const winch_act = posix.Sigaction{
        .handler = .{ .handler = handleWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &winch_act, null);
}

fn noop(_: i32) callconv(.c) void {}

fn handleWinch(_: i32) callconv(.c) void {
    winch_pending = true;
}
