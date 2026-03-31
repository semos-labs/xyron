// select.zig — Pick columns from structured data.
//
// Reads JSON array from stdin, outputs only selected fields.
// Terminal → table, pipe → JSON for chaining.
//
// Usage: ... | select field1,field2,...
//        ... | select name,age,email

const std = @import("std");
const jp = @import("../json_parser.zig");
const pj = @import("../pipe_json.zig");
const posix = std.posix;
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) u8 {
    _ = stdout;
    _ = args;
    stderr.writeAll("Usage: ... | select field1,field2,...\n") catch {};
    return 1;
}

pub fn runFromPipe(args: []const []const u8) void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    if (args.len == 0) {
        stderr.writeAll("Usage: ... | select field1,field2,...\n") catch {};
        std.process.exit(1);
    }

    // Parse field list (comma-separated, may span multiple args)
    var field_names: [12][]const u8 = undefined;
    var field_count: usize = 0;

    for (args) |arg| {
        var remaining = arg;
        while (remaining.len > 0) {
            const comma = std.mem.indexOfScalar(u8, remaining, ',') orelse {
                if (field_count < 12 and remaining.len > 0) {
                    field_names[field_count] = stripDot(remaining);
                    field_count += 1;
                }
                break;
            };
            if (field_count < 12 and comma > 0) {
                field_names[field_count] = stripDot(remaining[0..comma]);
                field_count += 1;
            }
            remaining = remaining[comma + 1 ..];
        }
    }

    if (field_count == 0) { stderr.writeAll("select: no fields specified\n") catch {}; std.process.exit(1); }

    // Read and parse JSON (supports typed envelopes)
    var input_buf: [262144]u8 = undefined;
    const input = pj.readStdin(&input_buf);
    if (input.len == 0) { stderr.writeAll("select: no input\n") catch {}; std.process.exit(1); }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const typed = pj.parseTypedInput(arena.allocator(), input) catch {
        stderr.writeAll("select: invalid JSON\n") catch {};
        std.process.exit(1);
    };
    const items = typed.items;

    if (items.len == 0) {
        // Try as single object
        const parsed = jp.parse(arena.allocator(), input) catch std.process.exit(1);
        switch (parsed) {
            .object => {
                const single = arena.allocator().alloc(jp.Value, 1) catch std.process.exit(1);
                single[0] = parsed;
                outputSelected(arena.allocator(), single, field_names[0..field_count], typed.schema, stdout);
                std.process.exit(0);
            },
            else => {},
        }
        std.process.exit(1);
    }

    outputSelected(arena.allocator(), items, field_names[0..field_count], typed.schema, stdout);
    std.process.exit(0);
}

fn outputSelected(allocator: std.mem.Allocator, items: []const jp.Value, fields: []const []const u8, schema: ?pj.TypeSchema, stdout: std.fs.File) void {
    // Build selected array
    var results: [512]jp.Value = undefined;
    var count: usize = 0;
    for (items) |*item| {
        if (count >= 512) break;
        if (pj.selectFields(allocator, item, fields)) |v| {
            results[count] = v;
            count += 1;
        }
    }

    if (pj.isTerminal(posix.STDOUT_FILENO)) {
        if (schema) |*s| {
            pj.renderTableWithSchema(stdout, results[0..count], s);
        } else {
            pj.renderTable(stdout, results[0..count]);
        }
    } else {
        if (schema) |*s| {
            pj.writeTypedJson(stdout, results[0..count], s);
        } else {
            pj.writeJsonArray(stdout, results[0..count]);
        }
    }
}

fn stripDot(s: []const u8) []const u8 {
    return if (s.len > 0 and s[0] == '.') s[1..] else s;
}
