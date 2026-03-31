// where.zig — Filter structured data by condition.
//
// Reads JSON array from stdin, outputs items matching the condition.
// Type-aware: numbers compare as numbers, strings as strings.
// Terminal → table, pipe → JSON for chaining.
//
// Usage: ... | where field op value
//        ... | where age > 25
//        ... | where status == "active"
//        ... | where name contains "john"

const std = @import("std");
const jp = @import("../json_parser.zig");
const pj = @import("../pipe_json.zig");
const posix = std.posix;
const Result = @import("mod.zig").BuiltinResult;

const Op = enum { eq, neq, gt, lt, gte, lte, contains };

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) u8 {
    _ = stdout;
    _ = args;
    stderr.writeAll("Usage: ... | where field op value\n") catch {};
    return 1;
}

pub fn runFromPipe(args: []const []const u8) void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    if (args.len < 3) {
        stderr.writeAll("Usage: ... | where field op value\n") catch {};
        std.process.exit(1);
    }

    const field = stripDot(args[0]);
    const op = parseOp(args[1]);
    const rhs = args[2];

    // Read and parse JSON
    var input_buf: [262144]u8 = undefined;
    const input = pj.readStdin(&input_buf);
    if (input.len == 0) { stderr.writeAll("where: no input\n") catch {}; std.process.exit(1); }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = jp.parse(arena.allocator(), input) catch {
        stderr.writeAll("where: invalid JSON\n") catch {};
        std.process.exit(1);
    };

    const items = switch (parsed) {
        .array => |arr| arr,
        else => { stderr.writeAll("where: expected array\n") catch {}; std.process.exit(1); },
    };

    // Filter
    var results: [512]jp.Value = undefined;
    var count: usize = 0;
    for (items) |*item| {
        if (count >= 512) break;
        if (matchesCondition(item, field, op, rhs)) {
            results[count] = item.*;
            count += 1;
        }
    }

    if (pj.isTerminal(posix.STDOUT_FILENO)) {
        pj.renderTable(stdout, results[0..count]);
    } else {
        pj.writeJsonArray(stdout, results[0..count]);
    }
    std.process.exit(0);
}

fn matchesCondition(item: *const jp.Value, field: []const u8, op: Op, rhs: []const u8) bool {
    const val = pj.navigatePath(item, field) orelse return false;
    return compareValue(&val, op, rhs);
}

fn compareValue(val: *const jp.Value, op: Op, rhs_str: []const u8) bool {
    switch (val.*) {
        .number => |n| {
            const rhs = parseNumber(rhs_str) orelse return false;
            return switch (op) {
                .eq => n == rhs,
                .neq => n != rhs,
                .gt => n > rhs,
                .lt => n < rhs,
                .gte => n >= rhs,
                .lte => n <= rhs,
                .contains => false,
            };
        },
        .string => |s| {
            const cmp = unquote(rhs_str);
            return switch (op) {
                .eq => std.mem.eql(u8, s, cmp),
                .neq => !std.mem.eql(u8, s, cmp),
                .gt => std.mem.order(u8, s, cmp) == .gt,
                .lt => std.mem.order(u8, s, cmp) == .lt,
                .gte => std.mem.order(u8, s, cmp) != .lt,
                .lte => std.mem.order(u8, s, cmp) != .gt,
                .contains => std.mem.indexOf(u8, s, cmp) != null,
            };
        },
        .boolean => |b| {
            const rhs_bool = std.mem.eql(u8, rhs_str, "true");
            return switch (op) {
                .eq => b == rhs_bool,
                .neq => b != rhs_bool,
                else => false,
            };
        },
        .null_val => return switch (op) {
            .eq => std.mem.eql(u8, rhs_str, "null"),
            .neq => !std.mem.eql(u8, rhs_str, "null"),
            else => false,
        },
        else => return false,
    }
}

/// Parse a number with optional unit suffix (kb, mb, gb).
fn parseNumber(s: []const u8) ?f64 {
    // Check for size suffixes
    if (s.len >= 3) {
        const suffix = s[s.len - 2 ..];
        const num_part = s[0 .. s.len - 2];
        if (std.mem.eql(u8, suffix, "kb") or std.mem.eql(u8, suffix, "KB")) {
            const n = std.fmt.parseFloat(f64, num_part) catch return null;
            return n * 1024;
        }
        if (std.mem.eql(u8, suffix, "mb") or std.mem.eql(u8, suffix, "MB")) {
            const n = std.fmt.parseFloat(f64, num_part) catch return null;
            return n * 1024 * 1024;
        }
        if (std.mem.eql(u8, suffix, "gb") or std.mem.eql(u8, suffix, "GB")) {
            const n = std.fmt.parseFloat(f64, num_part) catch return null;
            return n * 1024 * 1024 * 1024;
        }
    }
    return std.fmt.parseFloat(f64, s) catch null;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn parseOp(s: []const u8) Op {
    if (std.mem.eql(u8, s, "==") or std.mem.eql(u8, s, "=")) return .eq;
    if (std.mem.eql(u8, s, "!=")) return .neq;
    if (std.mem.eql(u8, s, ">")) return .gt;
    if (std.mem.eql(u8, s, "<")) return .lt;
    if (std.mem.eql(u8, s, ">=")) return .gte;
    if (std.mem.eql(u8, s, "<=")) return .lte;
    if (std.mem.eql(u8, s, "contains")) return .contains;
    return .eq;
}

fn stripDot(s: []const u8) []const u8 {
    return if (s.len > 0 and s[0] == '.') s[1..] else s;
}
