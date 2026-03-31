// sort_cmd.zig — Sort structured data by field.
//
// Reads JSON array from stdin, sorts by field with type-aware comparison.
// Numbers sort as numbers, strings lexicographically, nulls last.
// Terminal → table, pipe → JSON for chaining.
//
// Usage: ... | sort field [asc|desc]
//        ... | sort price desc
//        ... | sort name

const std = @import("std");
const jp = @import("../json_parser.zig");
const pj = @import("../pipe_json.zig");
const posix = std.posix;
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) u8 {
    _ = stdout;
    _ = args;
    stderr.writeAll("Usage: ... | sort field [asc|desc]\n") catch {};
    return 1;
}

pub fn runFromPipe(args: []const []const u8) void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    if (args.len < 1) {
        stderr.writeAll("Usage: ... | sort field [asc|desc]\n") catch {};
        std.process.exit(1);
    }

    const field = stripDot(args[0]);
    const desc = if (args.len > 1) std.mem.eql(u8, args[1], "desc") else false;

    // Read and parse JSON
    var input_buf: [262144]u8 = undefined;
    const input = pj.readStdin(&input_buf);
    if (input.len == 0) { stderr.writeAll("sort: no input\n") catch {}; std.process.exit(1); }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const typed = pj.parseTypedInput(arena.allocator(), input) catch {
        stderr.writeAll("sort: invalid JSON\n") catch {};
        std.process.exit(1);
    };
    const items = typed.items;
    if (items.len == 0) { stderr.writeAll("sort: empty input\n") catch {}; std.process.exit(1); }

    // Build index array and sort
    var indices: [512]usize = undefined;
    const count = @min(items.len, 512);
    for (0..count) |i| indices[i] = i;

    sortIndices(items, indices[0..count], field, desc);

    // Output in sorted order
    var sorted: [512]jp.Value = undefined;
    for (0..count) |i| sorted[i] = items[indices[i]];

    if (pj.isTerminal(posix.STDOUT_FILENO)) {
        if (typed.schema) |*s| {
            pj.renderTableWithSchema(stdout, sorted[0..count], s);
        } else {
            pj.renderTable(stdout, sorted[0..count]);
        }
    } else {
        if (typed.schema) |*s| {
            pj.writeTypedJson(stdout, sorted[0..count], s);
        } else {
            pj.writeJsonArray(stdout, sorted[0..count]);
        }
    }
    std.process.exit(0);
}

fn sortIndices(items: []const jp.Value, indices: []usize, field: []const u8, desc: bool) void {
    // Insertion sort (stable)
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const key_idx = indices[i];
        var j = i;
        while (j > 0) {
            const cmp = compareByField(&items[indices[j - 1]], &items[key_idx], field);
            const should_swap = if (desc) cmp < 0 else cmp > 0;
            if (!should_swap) break;
            indices[j] = indices[j - 1];
            j -= 1;
        }
        indices[j] = key_idx;
    }
}

fn compareByField(a: *const jp.Value, b: *const jp.Value, field: []const u8) i32 {
    const va = pj.navigatePath(a, field);
    const vb = pj.navigatePath(b, field);

    if (va == null and vb == null) return 0;
    if (va == null) return 1; // nulls last
    if (vb == null) return -1;

    return compareValues(&va.?, &vb.?);
}

fn compareValues(a: *const jp.Value, b: *const jp.Value) i32 {
    switch (a.*) {
        .number => |na| {
            switch (b.*) {
                .number => |nb| {
                    if (na < nb) return -1;
                    if (na > nb) return 1;
                    return 0;
                },
                else => return -1,
            }
        },
        .string => |sa| {
            switch (b.*) {
                .string => |sb| {
                    return switch (std.mem.order(u8, sa, sb)) {
                        .lt => @as(i32, -1),
                        .gt => @as(i32, 1),
                        .eq => @as(i32, 0),
                    };
                },
                .number => return 1,
                else => return -1,
            }
        },
        .boolean => |ba| {
            switch (b.*) {
                .boolean => |bb| {
                    if (ba == bb) return 0;
                    return if (ba) @as(i32, -1) else @as(i32, 1);
                },
                else => return 1,
            }
        },
        else => return 0,
    }
}

fn stripDot(s: []const u8) []const u8 {
    return if (s.len > 0 and s[0] == '.') s[1..] else s;
}
