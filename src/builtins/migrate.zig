// migrate — analyze and convert bash/sh scripts for Xyron.
//
// Usage:
//   migrate analyze <file>     Compatibility report
//   migrate convert <file>     Auto-convert safe patterns
//   migrate analyze -          Read from stdin (piped)

const std = @import("std");
const mig = @import("../migrate.zig");
const rich = @import("../rich_output.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len < 2) {
        stdout.writeAll("xyron: migrate: usage:\n") catch {};
        stdout.writeAll("  migrate analyze <file>   Compatibility report\n") catch {};
        stdout.writeAll("  migrate convert <file>   Convert to Xyron/Lua\n") catch {};
        return .{ .exit_code = 1 };
    }

    const subcmd = args[0];
    const path = args[1];

    // Read input
    var file_buf: [65536]u8 = undefined;
    const input = readInput(path, &file_buf) orelse {
        var buf: [256]u8 = undefined;
        stderr.writeAll(std.fmt.bufPrint(&buf, "xyron: migrate: cannot read: {s}\n", .{path}) catch "") catch {};
        return .{ .exit_code = 1 };
    };

    if (std.mem.eql(u8, subcmd, "analyze")) {
        return runAnalyze(input, stdout);
    }
    if (std.mem.eql(u8, subcmd, "convert")) {
        return runConvert(input, stdout);
    }

    stderr.writeAll("xyron: migrate: unknown subcommand\n") catch {};
    return .{ .exit_code = 1 };
}

fn runAnalyze(input: []const u8, stdout: std.fs.File) Result {
    const report = mig.analyze(input);

    // Summary
    var buf: [256]u8 = undefined;
    const status_str: []const u8 = switch (report.overallStatus()) {
        .supported => "\x1b[1;32mFully compatible\x1b[0m",
        .partial => "\x1b[1;33mPartially compatible\x1b[0m",
        .unsupported => "\x1b[1;31mContains unsupported constructs\x1b[0m",
    };
    stdout.writeAll("\n  Status: ") catch {};
    stdout.writeAll(status_str) catch {};
    stdout.writeAll(std.fmt.bufPrint(&buf, "\n  Findings: {d} supported, {d} partial, {d} unsupported\n\n", .{ report.supported_count, report.partial_count, report.unsupported_count }) catch "\n") catch {};

    // Findings table
    if (report.count == 0) return .{};

    var tbl = rich.Table{};
    tbl.addColumn(.{ .header = "line", .align_ = .right, .color = "\x1b[2m" });
    tbl.addColumn(.{ .header = "status", .color = "" });
    tbl.addColumn(.{ .header = "kind", .color = "\x1b[36m" });
    tbl.addColumn(.{ .header = "message", .color = "" });

    for (report.findings[0..report.count]) |*f| {
        const r = tbl.addRow();
        var ln_buf: [8]u8 = undefined;
        tbl.setCell(r, 0, std.fmt.bufPrint(&ln_buf, "{d}", .{f.line}) catch "?");
        const sc: []const u8 = switch (f.status) {
            .supported => "\x1b[32m",
            .partial => "\x1b[33m",
            .unsupported => "\x1b[31m",
        };
        const sl: []const u8 = switch (f.status) {
            .supported => "OK",
            .partial => "PARTIAL",
            .unsupported => "UNSUPPORTED",
        };
        tbl.setCellColor(r, 1, sl, sc);
        tbl.setCell(r, 2, f.kind);
        tbl.setCell(r, 3, f.message);
    }
    tbl.render(stdout);
    return .{};
}

fn runConvert(input: []const u8, stdout: std.fs.File) Result {
    var out_buf: [65536]u8 = undefined;
    const n = mig.convert(input, &out_buf);
    stdout.writeAll(out_buf[0..n]) catch {};
    return .{};
}

fn readInput(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch
        std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const n = file.readAll(buf) catch return null;
    return buf[0..n];
}
