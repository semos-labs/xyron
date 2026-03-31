// block_ui.zig — Warp-style block rendering for command output.
//
// Each command + output is rendered as a bordered box with the command
// as a title and color based on exit code (green=success, red=failure).
// Enabled via xyron.block_ui(true) in config.

const std = @import("std");
const posix = std.posix;

pub var enabled: bool = false;

/// Last rendered block — saved for overlay content restoration.
var saved_cmd: [512]u8 = undefined;
var saved_cmd_len: usize = 0;
var saved_output: [65536]u8 = undefined;
var saved_output_len: usize = 0;
var saved_exit_code: u8 = 0;
/// Total lines in the last rendered block (top + content + bottom).
pub var saved_block_lines: usize = 0;

/// Re-render the last block to restore content after overlay dismissal.
/// Caller should position the cursor before calling.
/// Re-render the last N lines of the saved block at the current cursor
/// position. Used to restore content after overlay dismissal.
/// Restore a range of lines from the last rendered block.
/// `start_line`: first block line to render (0-based)
/// `count`: number of lines to render
pub fn restoreBlockRange(stdout: std.fs.File, start_line: usize, count: usize) void {
    if (saved_cmd_len == 0 and saved_output_len == 0) return;
    if (saved_block_lines == 0 or count == 0) return;

    restoring = true;
    var render_buf: [65536]u8 = undefined;

    const term_w = getTermWidth();
    const border_color: []const u8 = if (saved_exit_code == 0) "\x1b[32m" else "\x1b[31m";
    const reset = "\x1b[0m";
    const output = saved_output[0..saved_output_len];

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
        pos += cpb(render_buf[pos..], saved_cmd[0..saved_cmd_len]);
        pos += cpb(render_buf[pos..], " ");
        pos += cpb(render_buf[pos..], border_color);
        const used = 2 + 1 + saved_cmd_len + 1;
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
    saved_cmd_len = @min(command.len, saved_cmd.len);
    @memcpy(saved_cmd[0..saved_cmd_len], command[0..saved_cmd_len]);
    saved_output_len = @min(output.len, saved_output.len);
    @memcpy(saved_output[0..saved_output_len], output[0..saved_output_len]);
    saved_exit_code = exit_code;
    // Count lines: top border (1) + output lines + bottom border (1)
    var lines: usize = 2; // top + bottom borders
    if (output.len > 0) {
        lines += 1; // at least 1 content line
        for (output) |ch| { if (ch == '\n') lines += 1; }
    }
    saved_block_lines = lines;
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

    // Bottom border: ╰────────────────────╯
    // Visual: ╰(1) + ─ * (term_w - 2) + ╯(1)
    stdout.writeAll(border_color) catch {};
    stdout.writeAll("\xe2\x95\xb0") catch {}; // ╰
    if (term_w > 2) {
        var i: usize = 0;
        while (i < term_w - 2) : (i += 1) {
            stdout.writeAll("\xe2\x94\x80") catch {}; // ─
        }
    }
    stdout.writeAll("\xe2\x95\xaf") catch {}; // ╯
    stdout.writeAll(reset) catch {};
    stdout.writeAll("\n") catch {};

    // Save for overlay restoration (skip if restoring to avoid alias panic)
    if (!restoring) saveBlockData(command, output, exit_code);
}

var restoring: bool = false;

/// Run a command, capture its output, and render as a block.
/// Returns exit code.
pub fn runAndRender(
    argv: []const []const u8,
    stdout: std.fs.File,
) u8 {
    // Build command string for display
    var cmd_display: [512]u8 = undefined;
    var cmd_len: usize = 0;
    for (argv, 0..) |arg, i| {
        if (i > 0 and cmd_len < cmd_display.len) { cmd_display[cmd_len] = ' '; cmd_len += 1; }
        const n = @min(arg.len, cmd_display.len - cmd_len);
        @memcpy(cmd_display[cmd_len..][0..n], arg[0..n]);
        cmd_len += n;
    }

    // Join argv for /bin/sh
    var sh_cmd: [4096]u8 = undefined;
    var sh_len: usize = 0;
    for (argv, 0..) |arg, i| {
        if (i > 0 and sh_len < sh_cmd.len) { sh_cmd[sh_len] = ' '; sh_len += 1; }
        const n = @min(arg.len, sh_cmd.len - sh_len);
        @memcpy(sh_cmd[sh_len..][0..n], arg[0..n]);
        sh_len += n;
    }

    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", sh_cmd[0..sh_len] },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        renderBlock(stdout, cmd_display[0..cmd_len], "xyron: failed to run command", 127);
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
        renderBlock(stdout, cmd_display[0..cmd_len], "xyron: wait failed", 127);
        return 127;
    };
    const code: u8 = switch (term) { .Exited => |c| c, else => 1 };

    // Trim trailing newline
    var output = out_buf[0..total];
    while (output.len > 0 and output[output.len - 1] == '\n') output = output[0 .. output.len - 1];

    renderBlock(stdout, cmd_display[0..cmd_len], output, code);
    return code;
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
        std.mem.eql(u8, base, "tmux");
}

fn getTermWidth() usize {
    const c_ext = struct {
        const winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    };
    var ws: c_ext.winsize = undefined;
    if (c_ext.ioctl(posix.STDOUT_FILENO, 0x40087468, &ws) == 0 and ws.ws_col > 0) return ws.ws_col;
    return 80;
}
