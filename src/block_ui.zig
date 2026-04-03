// block_ui.zig — Warp-style block rendering for command output.
//
// Each command + output is rendered as a bordered box with the command
// as a title and color based on exit code (green=success, red=failure).
// Enabled via xyron.block_ui(true) in config.

const std = @import("std");
const posix = std.posix;
const style = @import("style.zig");

pub var enabled: bool = false;

/// Set by executor before renderBlock — shown in bottom border.
pub var last_duration_ms: i64 = 0;

// ---------------------------------------------------------------------------
// Block output history — stores recent blocks for resize re-rendering
// ---------------------------------------------------------------------------

const MAX_STORED: usize = 64;
const OUTPUT_POOL: usize = 512 * 1024; // 512KB shared pool

const StoredBlock = struct {
    cmd: [256]u8 = undefined,
    cmd_len: usize = 0,
    output_start: usize = 0, // index into output_pool
    output_len: usize = 0,
    exit_code: u8 = 0,
    duration_ms: i64 = 0,
    line_count: usize = 0, // pre-computed: top + content + bottom
};

var stored_blocks: [MAX_STORED]StoredBlock = [_]StoredBlock{.{}} ** MAX_STORED;
var stored_count: usize = 0;
var stored_head: usize = 0; // ring buffer head (oldest)
var output_pool: [OUTPUT_POOL]u8 = undefined;
var pool_used: usize = 0;

/// Get the last stored block (for overlay restoration).
pub var saved_block_lines: usize = 0;

/// Store a block's data for later re-rendering.
fn storeBlock(command: []const u8, output: []const u8, exit_code: u8) void {
    // Make room in pool if needed
    while (pool_used + output.len > OUTPUT_POOL and stored_count > 0) {
        // Drop oldest block
        pool_used -= stored_blocks[stored_head].output_len;
        // Shift pool data
        const drop_len = stored_blocks[stored_head].output_len;
        const remaining = pool_used;
        if (remaining > 0 and drop_len > 0) {
            std.mem.copyForwards(u8, output_pool[0..remaining], output_pool[drop_len..][0..remaining]);
        }
        // Adjust all output_start pointers
        for (0..MAX_STORED) |i| {
            if (stored_blocks[i].output_len > 0 and stored_blocks[i].output_start >= drop_len) {
                stored_blocks[i].output_start -= drop_len;
            }
        }
        stored_head = (stored_head + 1) % MAX_STORED;
        stored_count -= 1;
    }

    if (output.len > OUTPUT_POOL) return; // too large

    const idx = (stored_head + stored_count) % MAX_STORED;
    var blk = &stored_blocks[idx];
    blk.cmd_len = @min(command.len, blk.cmd.len);
    @memcpy(blk.cmd[0..blk.cmd_len], command[0..blk.cmd_len]);
    blk.output_start = pool_used;
    blk.output_len = output.len;
    @memcpy(output_pool[pool_used..][0..output.len], output);
    pool_used += output.len;
    blk.exit_code = exit_code;
    blk.duration_ms = last_duration_ms;

    // Count lines
    var lines: usize = 2; // top + bottom borders
    if (output.len > 0) {
        lines += 1;
        for (output) |ch| { if (ch == '\n') lines += 1; }
    }
    blk.line_count = lines;
    saved_block_lines = lines;

    if (stored_count < MAX_STORED) stored_count += 1;
}

/// Get stored block by reverse index (0 = most recent).
fn getStoredBlock(reverse_idx: usize) ?*const StoredBlock {
    if (reverse_idx >= stored_count) return null;
    const idx = (stored_head + stored_count - 1 - reverse_idx) % MAX_STORED;
    return &stored_blocks[idx];
}

/// Get output slice for a stored block.
fn getBlockOutput(blk: *const StoredBlock) []const u8 {
    return output_pool[blk.output_start..][0..blk.output_len];
}

/// Re-render the last block on SIGWINCH. Only re-renders if it fits
/// on screen. Older blocks in scrollback stay as-is (terminal limitation).
pub fn reRenderVisible(stdout: std.fs.File) void {
    const blk = getStoredBlock(0) orelse return; // most recent block
    const term_h = getTermHeight();
    const prompt_lines: usize = 3; // estimate: prompt + input + gap

    // Only re-render if the last block fits on screen
    if (blk.line_count + prompt_lines > term_h) return;

    // Scroll down to push old reflowed content into scrollback,
    // then render the last block fresh at the top of a clean area.
    // This avoids fighting with Attyx's reflow.
    var i: usize = 0;
    while (i < term_h) : (i += 1) stdout.writeAll("\n") catch {};

    // Now render the block using normal renderBlock (writes to stdout)
    restoring = true;
    renderBlock(stdout, blk.cmd[0..blk.cmd_len], getBlockOutput(blk), blk.exit_code);
    restoring = false;
}

fn getTermHeight() usize {
    return style.getTermSize(posix.STDOUT_FILENO).rows;
}

/// Render a block at specific screen rows using absolute positioning.
/// Returns the next available row after the block.
fn renderBlockAtRow(stdout: std.fs.File, start_row: usize, command: []const u8, output: []const u8, exit_code: u8) usize {
    const term_w = getTermWidth();
    const border_color: []const u8 = if (exit_code == 0) "\x1b[32m" else "\x1b[31m";
    const reset = "\x1b[0m";
    var row = start_row;

    // Position + clear + render for each line
    var line_buf: [8192]u8 = undefined;
    var pos: usize = 0;

    // Helper to position cursor at row
    const posAt = struct {
        fn f(buf: []u8, p: *usize, r: usize) void {
            const seq = std.fmt.bufPrint(buf[p.*..], "\x1b[{d};1H\x1b[2K", .{r}) catch return;
            p.* += seq.len;
        }
    }.f;

    // Top border
    pos = 0;
    posAt(&line_buf, &pos, row);
    pos += cpb(line_buf[pos..], border_color);
    pos += cpb(line_buf[pos..], "\xe2\x95\xad\xe2\x94\x80");
    pos += cpb(line_buf[pos..], reset);
    pos += cpb(line_buf[pos..], " ");
    pos += cpb(line_buf[pos..], command);
    pos += cpb(line_buf[pos..], " ");
    pos += cpb(line_buf[pos..], border_color);
    const used = 2 + 1 + command.len + 1;
    if (term_w > used + 1) {
        var i: usize = 0;
        while (i < term_w - used - 1) : (i += 1) pos += cpb(line_buf[pos..], "\xe2\x94\x80");
    }
    pos += cpb(line_buf[pos..], "\xe2\x95\xae");
    pos += cpb(line_buf[pos..], reset);
    stdout.writeAll(line_buf[0..pos]) catch {};
    row += 1;

    // Content lines
    if (output.len > 0) {
        var line_iter = std.mem.splitScalar(u8, output, '\n');
        while (line_iter.next()) |line| {
            pos = 0;
            posAt(&line_buf, &pos, row);
            pos += cpb(line_buf[pos..], border_color);
            pos += cpb(line_buf[pos..], "\xe2\x94\x82");
            pos += cpb(line_buf[pos..], reset);
            pos += cpb(line_buf[pos..], " ");

            const max_line = if (term_w > 4) term_w - 4 else 1;
            const vis_len = visibleLen(line);
            if (vis_len > max_line) {
                pos += cpb(line_buf[pos..], truncateToVisible(line, max_line));
            } else {
                pos += cpb(line_buf[pos..], line);
                const pad = max_line - vis_len;
                var p: usize = 0;
                while (p < pad) : (p += 1) {
                    if (pos < line_buf.len) { line_buf[pos] = ' '; pos += 1; }
                }
            }
            pos += cpb(line_buf[pos..], " ");
            pos += cpb(line_buf[pos..], border_color);
            pos += cpb(line_buf[pos..], "\xe2\x94\x82");
            pos += cpb(line_buf[pos..], reset);
            stdout.writeAll(line_buf[0..pos]) catch {};
            row += 1;
        }
    }

    // Bottom border
    pos = 0;
    posAt(&line_buf, &pos, row);
    pos += cpb(line_buf[pos..], border_color);
    pos += cpb(line_buf[pos..], "\xe2\x95\xb0");
    if (term_w > 2) {
        var i: usize = 0;
        while (i < term_w - 2) : (i += 1) pos += cpb(line_buf[pos..], "\xe2\x94\x80");
    }
    pos += cpb(line_buf[pos..], "\xe2\x95\xaf");
    pos += cpb(line_buf[pos..], reset);
    stdout.writeAll(line_buf[0..pos]) catch {};
    row += 1;

    return row;
}

/// Re-render the last block to restore content after overlay dismissal.
/// Caller should position the cursor before calling.
/// Re-render the last N lines of the saved block at the current cursor
/// position. Used to restore content after overlay dismissal.
/// Restore a range of lines from the last rendered block.
/// `start_line`: first block line to render (0-based)
/// `count`: number of lines to render
pub fn restoreBlockRange(stdout: std.fs.File, start_line: usize, count: usize) void {
    const blk = getStoredBlock(0) orelse return; // most recent block
    if (blk.line_count == 0 or count == 0) return;

    restoring = true;
    var render_buf: [65536]u8 = undefined;

    const term_w = getTermWidth();
    const border_color: []const u8 = if (blk.exit_code == 0) "\x1b[32m" else "\x1b[31m";
    const reset = "\x1b[0m";
    const output = getBlockOutput(blk);

    const end_line = start_line + count;
    var current_line: usize = 0;
    var rendered: usize = 0;

    // --- Top border (line 0) ---
    if (current_line >= start_line and current_line < end_line) {
        var pos: usize = 0;
        pos += cpb(render_buf[pos..], border_color);
        pos += cpb(render_buf[pos..], "\xe2\x95\xad\xe2\x94\x80");
        pos += cpb(render_buf[pos..], reset);
        pos += cpb(render_buf[pos..], " ");
        pos += cpb(render_buf[pos..], blk.cmd[0..blk.cmd_len]);
        pos += cpb(render_buf[pos..], " ");
        pos += cpb(render_buf[pos..], border_color);
        const used = 2 + 1 + blk.cmd_len + 1;
        if (term_w > used + 1) {
            var i: usize = 0;
            while (i < term_w - used - 1) : (i += 1) pos += cpb(render_buf[pos..], "\xe2\x94\x80");
        }
        pos += cpb(render_buf[pos..], "\xe2\x95\xae");
        pos += cpb(render_buf[pos..], reset);
        stdout.writeAll(render_buf[0..pos]) catch {};
        rendered += 1;
        if (rendered < count) stdout.writeAll("\r\n") catch {};
    }
    current_line += 1;

    // --- Content lines ---
    if (output.len > 0) {
        var line_iter = std.mem.splitScalar(u8, output, '\n');
        while (line_iter.next()) |line| {
            if (current_line >= start_line and current_line < end_line) {
                var pos: usize = 0;
                pos += cpb(render_buf[pos..], border_color);
                pos += cpb(render_buf[pos..], "\xe2\x94\x82");
                pos += cpb(render_buf[pos..], reset);
                pos += cpb(render_buf[pos..], " ");

                const max_line = if (term_w > 4) term_w - 4 else 1;
                const vis_len = visibleLen(line);
                if (vis_len > max_line) {
                    pos += cpb(render_buf[pos..], truncateToVisible(line, max_line));
                } else {
                    pos += cpb(render_buf[pos..], line);
                    const pad = max_line - vis_len;
                    var p: usize = 0;
                    while (p < pad) : (p += 1) {
                        if (pos < render_buf.len) { render_buf[pos] = ' '; pos += 1; }
                    }
                }

                pos += cpb(render_buf[pos..], " ");
                pos += cpb(render_buf[pos..], border_color);
                pos += cpb(render_buf[pos..], "\xe2\x94\x82");
                pos += cpb(render_buf[pos..], reset);
                stdout.writeAll(render_buf[0..pos]) catch {};
                rendered += 1;
                if (rendered < count) stdout.writeAll("\r\n") catch {};
            }
            current_line += 1;
            if (rendered >= count) break;
        }
    }

    // --- Bottom border (last line) ---
    if (current_line >= start_line and current_line < end_line) {
        var pos: usize = 0;
        pos += cpb(render_buf[pos..], border_color);
        pos += cpb(render_buf[pos..], "\xe2\x95\xb0");
        if (term_w > 2) {
            var i: usize = 0;
            while (i < term_w - 2) : (i += 1) pos += cpb(render_buf[pos..], "\xe2\x94\x80");
        }
        pos += cpb(render_buf[pos..], "\xe2\x95\xaf");
        pos += cpb(render_buf[pos..], reset);
        stdout.writeAll(render_buf[0..pos]) catch {};
    }

    restoring = false;
}

fn cpb(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

fn saveBlockData(command: []const u8, output: []const u8, exit_code: u8) void {
    storeBlock(command, output, exit_code);
}

/// Store output without rendering (for non-block mode capture).
pub fn storeOutputOnly(command: []const u8, output: []const u8, exit_code: u8) void {
    storeBlock(command, output, exit_code);
}

/// Capture command output, print it raw (no borders), and store for
/// overlay restoration. Used in non-block mode.
pub fn runCaptureAndPrintRaw(
    display: []const u8,
    steps: []const @import("planner.zig").PlanStep,
    stdout: std.fs.File,
) u8 {
    _ = stdout;
    // Build shell command from pipeline steps
    var sh_cmd: [4096]u8 = undefined;
    var sh_len: usize = 0;
    for (steps, 0..) |*step, si| {
        if (si > 0 and sh_len < sh_cmd.len - 3) {
            sh_cmd[sh_len] = ' ';
            sh_cmd[sh_len + 1] = '|';
            sh_cmd[sh_len + 2] = ' ';
            sh_len += 3;
        }
        for (step.argv, 0..) |arg, ai| {
            if (ai > 0 and sh_len < sh_cmd.len) { sh_cmd[sh_len] = ' '; sh_len += 1; }
            const n = @min(arg.len, sh_cmd.len - sh_len);
            @memcpy(sh_cmd[sh_len..][0..n], arg[0..n]);
            sh_len += n;
        }
    }

    // Inherit stdout/stderr so output streams in real-time
    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", sh_cmd[0..sh_len] },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return 127;
    const term = child.wait() catch return 127;
    const code: u8 = switch (term) { .Exited => |c| c, else => 1 };

    storeBlock(display, "", code);
    return code;
}

/// Restore stored content without block borders (for non-block mode).
pub fn restoreRawRange(stdout: std.fs.File, start_line: usize, count: usize) void {
    const blk = getStoredBlock(0) orelse return;
    if (blk.line_count == 0 or count == 0) return;
    const output = getBlockOutput(blk);
    if (output.len == 0) return;

    var iter = std.mem.splitScalar(u8, output, '\n');
    var line_idx: usize = 0;
    var rendered: usize = 0;
    while (iter.next()) |line| {
        if (line_idx >= start_line and rendered < count) {
            if (rendered > 0) stdout.writeAll("\r\n") catch {};
            stdout.writeAll(line) catch {};
            rendered += 1;
        }
        line_idx += 1;
        if (rendered >= count) break;
    }
}

/// Get the total line count of stored output (without borders).
pub fn storedOutputLines() usize {
    const blk = getStoredBlock(0) orelse return 0;
    const output = getBlockOutput(blk);
    if (output.len == 0) return 0;
    var lines: usize = 1;
    for (output) |ch| { if (ch == '\n') lines += 1; }
    return lines;
}

/// Render a command block with bordered output.
pub fn renderBlock(
    stdout: std.fs.File,
    command: []const u8,
    output: []const u8,
    exit_code: u8,
) void {
    const term_w = getTermWidth();
    const border_color: []const u8 = if (exit_code == 0) "\x1b[32m" else "\x1b[31m";
    const reset = "\x1b[0m";

    // Border rendering
    // Visual widths: ╭(1) ─(1) space(1) cmd space(1) ─...─ ╮(1)

    // Top border: ╭─ command ──────────────╮
    stdout.writeAll(border_color) catch {};
    stdout.writeAll("\xe2\x95\xad\xe2\x94\x80") catch {}; // ╭─
    stdout.writeAll(reset) catch {};
    stdout.writeAll(" ") catch {};
    stdout.writeAll(command) catch {};
    stdout.writeAll(" ") catch {};
    stdout.writeAll(border_color) catch {};

    // Fill remaining width with ─ (all values in visual columns)
    const used = 2 + 1 + command.len + 1; // ╭─ + space + cmd + space
    if (term_w > used + 1) {
        const fill = term_w - used - 1; // leave room for ╮
        var i: usize = 0;
        while (i < fill) : (i += 1) {
            stdout.writeAll("\xe2\x94\x80") catch {}; // ─
        }
    }
    stdout.writeAll("\xe2\x95\xae") catch {}; // ╮
    stdout.writeAll(reset) catch {};
    stdout.writeAll("\n") catch {};

    // Output lines with │ borders
    // Visual: │(1) space(1) content space(1) │(1) = content + 4
    if (output.len > 0) {
        var line_iter = std.mem.splitScalar(u8, output, '\n');
        while (line_iter.next()) |line| {
            stdout.writeAll(border_color) catch {};
            stdout.writeAll("\xe2\x94\x82") catch {}; // │
            stdout.writeAll(reset) catch {};
            stdout.writeAll(" ") catch {};

            const max_line = if (term_w > 4) term_w - 4 else 1;
            const vis_len = visibleLen(line);
            if (vis_len > max_line) {
                // Truncate by visual width
                stdout.writeAll(truncateToVisible(line, max_line)) catch {};
            } else {
                stdout.writeAll(line) catch {};
                // Pad to width using visual length
                const pad = max_line - vis_len;
                var p: usize = 0;
                while (p < pad) : (p += 1) stdout.writeAll(" ") catch {};
            }

            stdout.writeAll(" ") catch {};
            stdout.writeAll(border_color) catch {};
            stdout.writeAll("\xe2\x94\x82") catch {}; // │
            stdout.writeAll(reset) catch {};
            stdout.writeAll("\n") catch {};
        }
    }

    // Bottom border: ╰──────── 1.2s ╯  (with duration if > 500ms)
    stdout.writeAll(border_color) catch {};
    stdout.writeAll("\xe2\x95\xb0") catch {}; // ╰

    // Format duration label
    const prompt_mod = @import("prompt.zig");
    var dur_buf: [32]u8 = undefined;
    var dur_label: []const u8 = "";
    if (last_duration_ms >= 500) {
        dur_label = prompt_mod.formatDuration(&dur_buf, last_duration_ms);
    }

    if (term_w > 2) {
        const dur_vis = if (dur_label.len > 0) dur_label.len + 2 else 0; // " Xs "
        const fill = if (term_w > 2 + dur_vis) term_w - 2 - dur_vis else 0;
        var i: usize = 0;
        while (i < fill) : (i += 1) stdout.writeAll("\xe2\x94\x80") catch {}; // ─

        if (dur_label.len > 0) {
            stdout.writeAll(reset) catch {};
            stdout.writeAll("\x1b[2;33m") catch {}; // dim yellow
            stdout.writeAll(" ") catch {};
            stdout.writeAll(dur_label) catch {};
            stdout.writeAll(" ") catch {};
            stdout.writeAll("\x1b[0m") catch {};
            stdout.writeAll(border_color) catch {};
        }
    }
    stdout.writeAll("\xe2\x95\xaf") catch {}; // ╯
    stdout.writeAll(reset) catch {};
    stdout.writeAll("\n") catch {};

    // Save for overlay restoration (skip if restoring to avoid alias panic)
    if (!restoring) saveBlockData(command, output, exit_code);
}

var restoring: bool = false;

/// Run a command (single or pipeline), capture output, render as block.
/// `display` is the raw input string for the block title.
/// `steps` contains the pipeline steps.
pub fn runAndRender(
    display: []const u8,
    steps: []const @import("planner.zig").PlanStep,
    stdout: std.fs.File,
) u8 {
    // Build shell command from all pipeline steps
    var sh_cmd: [4096]u8 = undefined;
    var sh_len: usize = 0;
    for (steps, 0..) |*step, si| {
        if (si > 0 and sh_len < sh_cmd.len - 3) {
            sh_cmd[sh_len] = ' ';
            sh_cmd[sh_len + 1] = '|';
            sh_cmd[sh_len + 2] = ' ';
            sh_len += 3;
        }
        for (step.argv, 0..) |arg, ai| {
            if (ai > 0 and sh_len < sh_cmd.len) { sh_cmd[sh_len] = ' '; sh_len += 1; }
            const n = @min(arg.len, sh_cmd.len - sh_len);
            @memcpy(sh_cmd[sh_len..][0..n], arg[0..n]);
            sh_len += n;
        }
    }

    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", sh_cmd[0..sh_len] },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        renderBlock(stdout, display, "xyron: failed to run command", 127);
        return 127;
    };

    // Read stdout + stderr
    var out_buf: [65536]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |f| {
        while (total < out_buf.len) {
            const n = f.read(out_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        // Drain excess
        var drain: [4096]u8 = undefined;
        while (true) { const n = f.read(&drain) catch break; if (n == 0) break; }
    }
    // Append stderr
    if (child.stderr) |f| {
        while (total < out_buf.len) {
            const n = f.read(out_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        var drain: [4096]u8 = undefined;
        while (true) { const n = f.read(&drain) catch break; if (n == 0) break; }
    }

    const term = child.wait() catch {
        renderBlock(stdout, display, "xyron: wait failed", 127);
        return 127;
    };
    const code: u8 = switch (term) { .Exited => |c| c, else => 1 };

    // Trim trailing newline
    var output = out_buf[0..total];
    while (output.len > 0 and output[output.len - 1] == '\n') output = output[0 .. output.len - 1];

    renderBlock(stdout, display, output, code);
    return code;
}

/// Run a pipeline using forkPipeline (supports builtins like json),
/// capture stdout via pipe, render as block. Returns exit code.
pub fn forkAndRender(
    exec_plan: *const @import("planner.zig").ExecutionPlan,
    ax: *const @import("attyx.zig").Attyx,
    env: *@import("environ.zig").Environ,
    stdout: std.fs.File,
) u8 {
    const executor = @import("executor.zig");

    // Create a pipe to capture the pipeline's stdout
    const pipe_fds = posix.pipe2(.{}) catch {
        renderBlock(stdout, exec_plan.raw_input, "xyron: pipe failed", 127);
        return 127;
    };

    // Redirect stdout to the pipe write end for the child processes
    const orig_stdout = posix.dup(posix.STDOUT_FILENO) catch {
        posix.close(pipe_fds[0]);
        posix.close(pipe_fds[1]);
        renderBlock(stdout, exec_plan.raw_input, "xyron: dup failed", 127);
        return 127;
    };
    posix.dup2(pipe_fds[1], posix.STDOUT_FILENO) catch {};
    posix.close(pipe_fds[1]);

    // Fork the pipeline (it writes to our redirected stdout = pipe)
    const result = executor.forkPipelineForBlock(exec_plan, ax, env);

    // Restore stdout
    posix.dup2(orig_stdout, posix.STDOUT_FILENO) catch {};
    posix.close(orig_stdout);

    // Wait for pipeline
    const W = posix.W;
    var last_code: u8 = 0;
    for (0..result.pid_count) |i| {
        const wait = posix.waitpid(result.pids[i], 0);
        if (wait.pid == 0) continue;
        if (W.IFEXITED(wait.status)) last_code = W.EXITSTATUS(wait.status);
    }

    // Read captured output from pipe
    const read_end = std.fs.File{ .handle = pipe_fds[0] };
    var out_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < out_buf.len) {
        const n = read_end.read(out_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    posix.close(pipe_fds[0]);

    // Trim trailing newlines
    var output = out_buf[0..total];
    while (output.len > 0 and output[output.len - 1] == '\n') output = output[0 .. output.len - 1];

    renderBlock(stdout, exec_plan.raw_input, output, last_code);
    return last_code;
}

/// Count visible columns in a string, skipping ANSI escape sequences
/// and UTF-8 continuation bytes.
fn visibleLen(s: []const u8) usize {
    var vis: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\x1b') {
            // Skip ESC [ ... final_byte (CSI) or ESC + single char (e.g. ESC])
            if (i + 1 < s.len and s[i + 1] == '[') {
                i += 2;
                while (i < s.len and s[i] >= 0x20 and s[i] <= 0x3F) : (i += 1) {}
                if (i < s.len) i += 1; // skip final byte
            } else {
                i += 2; // ESC + one char
            }
        } else if (s[i] & 0xC0 == 0x80) {
            // UTF-8 continuation byte — not a new character
            i += 1;
        } else {
            vis += 1;
            i += 1;
        }
    }
    return vis;
}

/// Truncate a string to a maximum visible width, preserving ANSI sequences
/// and not splitting UTF-8 characters.
fn truncateToVisible(s: []const u8, max_vis: usize) []const u8 {
    var vis: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\x1b') {
            if (i + 1 < s.len and s[i + 1] == '[') {
                i += 2;
                while (i < s.len and s[i] >= 0x20 and s[i] <= 0x3F) : (i += 1) {}
                if (i < s.len) i += 1;
            } else {
                i += 2;
            }
        } else if (s[i] & 0xC0 == 0x80) {
            i += 1;
        } else {
            if (vis >= max_vis) return s[0..i];
            vis += 1;
            i += 1;
        }
    }
    return s;
}

/// Commands that should bypass block UI and run directly (terminal control, etc.)
pub fn isPassthrough(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const cmd = argv[0];
    // Extract basename (e.g. "/usr/bin/clear" → "clear")
    const base = if (std.mem.lastIndexOfScalar(u8, cmd, '/')) |i| cmd[i + 1 ..] else cmd;
    return std.mem.eql(u8, base, "clear") or
        std.mem.eql(u8, base, "reset") or
        std.mem.eql(u8, base, "tput") or
        std.mem.eql(u8, base, "vim") or
        std.mem.eql(u8, base, "nvim") or
        std.mem.eql(u8, base, "nano") or
        std.mem.eql(u8, base, "less") or
        std.mem.eql(u8, base, "more") or
        std.mem.eql(u8, base, "man") or
        std.mem.eql(u8, base, "top") or
        std.mem.eql(u8, base, "htop") or
        std.mem.eql(u8, base, "ssh") or
        std.mem.eql(u8, base, "tmux") or
        std.mem.eql(u8, base, "fz");
}

fn getTermWidth() usize {
    return style.getTermSize(posix.STDOUT_FILENO).cols;
}
