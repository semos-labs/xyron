// ps — structured process listing.
// Runs /bin/ps with controlled format, structures the output.

const std = @import("std");
const rich = @import("../rich_output.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File) Result {
    // Build ps command with controlled output format
    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[0] = "/bin/ps"; argc += 1;

    if (args.len == 0) {
        // Default: show user processes with useful columns
        argv_buf[argc] = "-eo"; argc += 1;
        argv_buf[argc] = "pid,user,%cpu,%mem,stat,command"; argc += 1;
    } else {
        // Pass user args through
        for (args) |arg| {
            if (argc >= 31) break;
            argv_buf[argc] = arg;
            argc += 1;
        }
    }

    // Run ps and capture output
    var child = std.process.Child.init(argv_buf[0..argc], std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return .{ .exit_code = 127 };

    var out_buf: [65536]u8 = undefined;
    var total: usize = 0;
    if (child.stdout) |f| {
        // Read what fits in our buffer
        while (total < out_buf.len) {
            const n = f.read(out_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        // Drain any remaining output to prevent pipe deadlock
        var drain: [4096]u8 = undefined;
        while (true) {
            const n = f.read(&drain) catch break;
            if (n == 0) break;
        }
    }
    const term = child.wait() catch return .{ .exit_code = 127 };
    const code: u8 = switch (term) { .Exited => |c| c, else => 1 };

    if (total == 0) return .{ .exit_code = code };

    // Parse: first line = headers, rest = data
    var lines_buf: [512][]const u8 = undefined;
    var line_count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, out_buf[0..total], '\n');
    while (line_iter.next()) |line| {
        if (line_count >= 512 or line.len == 0) continue;
        lines_buf[line_count] = line;
        line_count += 1;
    }
    if (line_count < 2) return .{ .exit_code = code };

    // Detect column positions from header
    const header = lines_buf[0];
    var col_starts: [12]usize = undefined;
    var col_count: usize = 0;
    var in_space = true;
    for (header, 0..) |ch, hi| {
        if (ch == ' ') {
            in_space = true;
        } else {
            if (in_space and col_count < 12) {
                col_starts[col_count] = hi;
                col_count += 1;
            }
            in_space = false;
        }
    }
    if (col_count == 0) return .{ .exit_code = code };

    var tbl = rich.Table{};
    for (0..col_count) |c| {
        const start = col_starts[c];
        const end = if (c + 1 < col_count) col_starts[c + 1] else header.len;
        const hdr = std.mem.trim(u8, header[start..end], " ");
        // Color based on column name
        const color: []const u8 = if (std.mem.eql(u8, hdr, "%CPU") or std.mem.eql(u8, hdr, "%MEM")) "\x1b[33m" else if (std.mem.eql(u8, hdr, "PID")) "\x1b[36m" else "";
        tbl.addColumn(.{ .header = hdr, .color = color });
    }

    for (1..line_count) |li| {
        const line = lines_buf[li];
        const r = tbl.addRow();
        for (0..col_count) |c| {
            const start = if (col_starts[c] < line.len) col_starts[c] else line.len;
            const end = if (c + 1 < col_count and col_starts[c + 1] < line.len) col_starts[c + 1] else line.len;
            if (start >= line.len) continue;
            tbl.setCell(r, c, std.mem.trim(u8, line[start..end], " "));
        }
    }
    tbl.render(stdout);
    return .{ .exit_code = code };
}
