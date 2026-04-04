// builtins/explain_cmd.zig — `xyron context explain` CLI renderer.
//
// Renders context introspection from the explain engine.
// Two modes: summary (no args) and single key (with KEY arg).

const std = @import("std");
const explain = @import("../project/explain.zig");
const ctx = @import("../project/context.zig");
const Result = @import("mod.zig").BuiltinResult;

fn write(f: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    f.writeAll(std.fmt.bufPrint(&buf, fmt, args) catch return) catch {};
}

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len > 0 and (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help"))) {
        stdout.writeAll(
            \\xyron context explain — inspect active context
            \\
            \\Usage:
            \\  xyron context explain           Show context summary
            \\  xyron context explain <KEY>      Explain a specific key
            \\
        ) catch {};
        return .{};
    }

    if (args.len > 0) {
        return runKeyExplain(args[0], stdout, stderr);
    }
    return runSummary(stdout, stderr);
}

// =============================================================================
// Summary view
// =============================================================================

fn runSummary(stdout: std.fs.File, stderr: std.fs.File) Result {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const result = explain.explainSummary(arena.allocator());

    switch (result.context_status) {
        .no_project => {
            stderr.writeAll("Not in a xyron project\n") catch {};
            return .{ .exit_code = 1 };
        },
        .invalid => {
            write(stdout, "\x1b[1mproject\x1b[0m   {s}\n", .{result.project_root});
            stdout.writeAll("\x1b[31mstatus\x1b[0m    invalid\n") catch {};
            if (result.warnings.len > 0) {
                for (result.warnings) |w| {
                    write(stdout, "  \x1b[31m✗\x1b[0m {s}\n", .{w});
                }
            }
            return .{ .exit_code = 1 };
        },
        .valid => {},
    }

    // Project info
    if (result.project_name) |name| {
        write(stdout, "\x1b[1mproject\x1b[0m   {s}\n", .{name});
    }
    write(stdout, "\x1b[2mroot\x1b[0m      {s}\n", .{result.project_root});
    stdout.writeAll("\x1b[32mstatus\x1b[0m    valid\n") catch {};
    write(stdout, "\x1b[2mfprint\x1b[0m    {x}\n", .{result.fingerprint});

    // Sources
    if (result.sources.len > 0) {
        stdout.writeAll("\n\x1b[1msources\x1b[0m\n") catch {};
        for (result.sources) |src| {
            const icon: []const u8 = switch (src.status) {
                .loaded => "\x1b[32m●\x1b[0m",
                .file_not_found => "\x1b[33m○\x1b[0m",
                .read_error, .parse_error => "\x1b[31m✗\x1b[0m",
            };
            const kind: []const u8 = switch (src.kind) {
                .system => "system",
                .env_file => "file",
                .override => "override",
            };
            write(stdout, "  {s} {s}  \x1b[2m{s} ({d} keys)\x1b[0m\n", .{
                icon, src.name, kind, src.key_count,
            });
        }
    }

    // Values summary
    stdout.writeAll("\n") catch {};
    write(stdout, "\x1b[2mvalues\x1b[0m    {d} total, {d} from project\n", .{
        result.total_values, result.project_values,
    });

    // Missing requirements
    if (result.missing_required.len > 0) {
        stdout.writeAll("\n\x1b[31mmissing required\x1b[0m\n") catch {};
        for (result.missing_required) |key| {
            write(stdout, "  \x1b[31m✗\x1b[0m {s}\n", .{key});
        }
    }

    // Warnings
    if (result.warnings.len > 0) {
        stdout.writeAll("\n\x1b[33mwarnings\x1b[0m\n") catch {};
        for (result.warnings) |w| {
            write(stdout, "  \x1b[33m!\x1b[0m {s}\n", .{w});
        }
    }

    return .{};
}

// =============================================================================
// Single key view
// =============================================================================

fn runKeyExplain(key: []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const result = explain.explainKey(arena.allocator(), key);

    if (result.project_root.len == 0) {
        stderr.writeAll("Not in a xyron project\n") catch {};
        return .{ .exit_code = 1 };
    }

    // Key name
    write(stdout, "\x1b[1mkey\x1b[0m       {s}\n", .{result.key});

    // Present / missing
    if (result.present) {
        stdout.writeAll("\x1b[32mpresent\x1b[0m   yes\n") catch {};

        // Value (potentially redacted)
        if (result.redacted) {
            write(stdout, "\x1b[2mvalue\x1b[0m     {s}  \x1b[33m(redacted)\x1b[0m\n", .{result.display_value});
        } else {
            write(stdout, "\x1b[2mvalue\x1b[0m     {s}\n", .{result.display_value});
        }

        // Winner source
        const source_label = sourceKindLabel(result.winner_source.?);
        write(stdout, "\x1b[1mwinner\x1b[0m    {s}", .{result.winner_source_name});
        write(stdout, "  \x1b[2m({s})\x1b[0m\n", .{source_label});

        // Override status
        if (result.was_overridden) {
            stdout.writeAll("\x1b[33moverride\x1b[0m  yes\n") catch {};
        }

        // Candidates
        if (result.candidates.len > 1) {
            stdout.writeAll("\n\x1b[1mcandidates\x1b[0m  \x1b[2m(lowest → highest priority)\x1b[0m\n") catch {};
            for (result.candidates, 0..) |candidate, i| {
                const is_winner = i == result.candidates.len - 1;
                const marker: []const u8 = if (is_winner) "\x1b[32m→\x1b[0m" else " ";
                const kind = sourceKindLabel(candidate.source_kind);
                write(stdout, "  {s} {s}  \x1b[2m({s})\x1b[0m\n", .{
                    marker, candidate.source_name, kind,
                });
            }
        }
    } else {
        stdout.writeAll("\x1b[31mpresent\x1b[0m   no\n") catch {};
    }

    // Required status
    if (result.required) {
        if (result.present) {
            stdout.writeAll("\x1b[2mrequired\x1b[0m  yes\n") catch {};
        } else {
            stdout.writeAll("\x1b[31mrequired\x1b[0m  yes \x1b[31m(MISSING)\x1b[0m\n") catch {};
            write(stdout, "\x1b[2m→ add {s} to .env or run: xyron secrets add {s} <value>\x1b[0m\n", .{ key, key });
        }
    }

    // Scope
    stdout.writeAll("\n") catch {};
    if (result.project_name) |name| {
        write(stdout, "\x1b[2mscope\x1b[0m     {s} ({s})\n", .{ name, result.project_root });
    } else {
        write(stdout, "\x1b[2mscope\x1b[0m     {s}\n", .{result.project_root});
    }

    return .{};
}

fn sourceKindLabel(kind: ctx.SourceKind) []const u8 {
    return switch (kind) {
        .system => "system env",
        .env_file => "env file",
        .override => "override",
    };
}
