// builtins/doctor_cmd.zig — `xyron doctor` CLI renderer.
//
// Runs the doctor engine and prints a structured, readable report.

const std = @import("std");
const doctor = @import("../project/doctor.zig");
const Result = @import("mod.zig").BuiltinResult;

fn write(f: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    f.writeAll(std.fmt.bufPrint(&buf, fmt, args) catch return) catch {};
}

pub fn run(stdout: std.fs.File) Result {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const report = doctor.runDoctor(arena.allocator());

    // Group checks by category for cleaner output
    var last_category: ?doctor.CheckCategory = null;

    for (report.checks) |chk| {
        // Print category header when it changes
        if (last_category == null or last_category.? != chk.category) {
            if (last_category != null) stdout.writeAll("\n") catch {};
            const cat_name = categoryLabel(chk.category);
            write(stdout, "\x1b[1m{s}\x1b[0m\n", .{cat_name});
            last_category = chk.category;
        }

        // Status indicator
        const indicator = switch (chk.status) {
            .pass => "\x1b[32mPASS\x1b[0m",
            .warn => "\x1b[33mWARN\x1b[0m",
            .fail => "\x1b[31mFAIL\x1b[0m",
        };

        write(stdout, "  {s}  {s}  \x1b[2m{s}\x1b[0m\n", .{ indicator, chk.name, chk.message });

        // Suggestion
        if (chk.suggestion) |sug| {
            write(stdout, "        \x1b[2m→ {s}\x1b[0m\n", .{sug});
        }
    }

    // Summary
    stdout.writeAll("\n") catch {};
    const summary_color: []const u8 = switch (report.status) {
        .healthy => "\x1b[32m",
        .warn => "\x1b[33m",
        .fail => "\x1b[31m",
    };
    const summary_label: []const u8 = switch (report.status) {
        .healthy => "healthy",
        .warn => "warnings",
        .fail => "issues found",
    };

    write(stdout, "{s}{s}\x1b[0m  \x1b[2m{d} checks: {d} passed, {d} warnings, {d} failed\x1b[0m\n", .{
        summary_color, summary_label, report.total, report.passed, report.warnings, report.failed,
    });

    return .{ .exit_code = if (report.failed > 0) 1 else 0 };
}

fn categoryLabel(cat: doctor.CheckCategory) []const u8 {
    return switch (cat) {
        .project => "Project",
        .context => "Context",
        .env => "Environment",
        .secrets => "Secrets",
        .commands => "Commands",
        .services => "Services",
        .git => "Git",
        .runtime => "Runtime",
    };
}
