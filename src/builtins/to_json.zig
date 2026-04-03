// to_json.zig — Output raw JSON from structured data.
//
// Reads JSON (possibly typed envelope) from stdin, outputs raw JSON.
// Strips type metadata, always outputs plain JSON regardless of terminal.
// Useful for piping structured builtin output to external tools.
//
// Usage: ls | to_json
//        ps | where %cpu > 5 | to_json
//        history | select command,exit_code | to_json

const std = @import("std");
const jp = @import("../json_parser.zig");
const pj = @import("../pipe_json.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) u8 {
    _ = stdout;
    _ = args;
    stderr.writeAll("Usage: ... | to_json\n") catch {};
    return 1;
}

pub fn runFromPipe(args: []const []const u8) void {
    _ = args;
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // Read all stdin
    var input_buf: [262144]u8 = undefined;
    const input = pj.readStdin(&input_buf);
    if (input.len == 0) {
        stderr.writeAll("to_json: no input\n") catch {};
        std.process.exit(1);
    }

    // Parse (supports typed envelopes — strips _types metadata)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const typed = pj.parseTypedInput(arena.allocator(), input) catch {
        stderr.writeAll("to_json: invalid JSON\n") catch {};
        std.process.exit(1);
    };

    // Always output plain JSON array
    pj.writeJsonArray(stdout, typed.items);
    stdout.writeAll("\n") catch {};
    std.process.exit(0);
}
