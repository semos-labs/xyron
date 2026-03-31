// query.zig — SQL-like query command for JSON data.
//
// Reads JSON from stdin (pipe target), applies select/where/sort/limit,
// renders results as a structured table. Type-aware: numbers compare
// as numbers, strings as strings, nulls sort last.
//
// Syntax:
//   ... | query [select field1,field2,...] [where .field op value] [sort .field [asc|desc]] [limit N]
//
// Examples:
//   curl api | json .users.[] | query select name,age where age > 25 sort age desc
//   cat data.json | query where .status == "active" limit 10
//   ... | query sort .price desc limit 5

const std = @import("std");
const jp = @import("../json_parser.zig");
const rich = @import("../rich_output.zig");
const posix = std.posix;

const MAX_FIELDS: usize = 12;
const MAX_ROWS: usize = 512;

/// Comparison operators for where clause.
const Op = enum { eq, neq, gt, lt, gte, lte, contains };

/// Parsed query plan.
const QueryPlan = struct {
    // JSON path (optional, e.g. ".data.users" or ".[]")
    path: []const u8 = "",

    // Select
    select_fields: [MAX_FIELDS][]const u8 = undefined,
    select_count: usize = 0, // 0 = select all

    // Where
    where_field: []const u8 = "",
    where_op: Op = .eq,
    where_value: []const u8 = "",
    has_where: bool = false,

    // Sort
    sort_field: []const u8 = "",
    sort_desc: bool = false,
    has_sort: bool = false,

    // Limit
    limit: usize = MAX_ROWS,
};

/// Direct invocation (not piped) — show usage.
pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) u8 {
    _ = args;
    stderr.writeAll("Usage: ... | query [select f1,f2] [where .field op value] [sort .field [desc]] [limit N]\n") catch {};
    _ = stdout;
    return 1;
}

/// Pipe entry point — called from executor childExec.
pub fn runFromPipe(args: []const []const u8) void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();
    const stdin = std.fs.File.stdin();

    // Read all stdin
    var input_buf: [262144]u8 = undefined;
    var total: usize = 0;
    while (total < input_buf.len) {
        const n = stdin.read(input_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) { stderr.writeAll("xyron: query: no input\n") catch {}; std.process.exit(1); }

    // Parse JSON
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = jp.parse(arena.allocator(), input_buf[0..total]) catch {
        stderr.writeAll("xyron: query: invalid JSON\n") catch {};
        std.process.exit(1);
    };

    // Parse query arguments
    const plan = parseQuery(args);

    // Apply optional JSON path (e.g. ".data.users" or ".[]")
    var target = parsed;
    if (plan.path.len > 0) {
        // Strip .[] suffix for iteration
        var nav_path = plan.path;
        if (std.mem.endsWith(u8, nav_path, ".[]")) {
            nav_path = nav_path[0 .. nav_path.len - 3];
        } else if (std.mem.eql(u8, nav_path, ".[]") or std.mem.eql(u8, nav_path, "[]")) {
            nav_path = "";
        }

        // Navigate path
        if (nav_path.len > 0) {
            const clean = if (nav_path[0] == '.') nav_path[1..] else nav_path;
            if (clean.len > 0) {
                if (navigatePath(&target, clean)) |v| {
                    target = v;
                } else {
                    stderr.writeAll("xyron: query: path not found\n") catch {};
                    std.process.exit(1);
                }
            }
        }
    }

    // Input must be an array of objects
    const items = switch (target) {
        .array => |arr| arr,
        .object => {
            // Single object — wrap in array for uniform handling
            const single = arena.allocator().alloc(jp.Value, 1) catch { std.process.exit(1); };
            single[0] = target;
            execute(&plan, single, stdout);
            std.process.exit(0);
        },
        else => {
            stderr.writeAll("xyron: query: expected array or object\n") catch {};
            std.process.exit(1);
        },
    };

    execute(&plan, items, stdout);
    std.process.exit(0);
}

fn execute(plan: *const QueryPlan, items: []const jp.Value, stdout: std.fs.File) void {
    // Phase 1: filter (where)
    var filtered_indices: [MAX_ROWS]usize = undefined;
    var filtered_count: usize = 0;

    for (items, 0..) |*item, idx| {
        if (filtered_count >= MAX_ROWS) break;
        if (plan.has_where) {
            if (!matchesWhere(item, plan)) continue;
        }
        filtered_indices[filtered_count] = idx;
        filtered_count += 1;
    }

    // Phase 2: sort
    if (plan.has_sort and filtered_count > 1) {
        sortIndices(items, filtered_indices[0..filtered_count], plan.sort_field, plan.sort_desc);
    }

    // Phase 3: limit
    const result_count = @min(filtered_count, plan.limit);

    // Phase 4: determine columns
    var col_names: [MAX_FIELDS][]const u8 = undefined;
    var col_count: usize = 0;

    if (plan.select_count > 0) {
        // Explicit select
        col_count = plan.select_count;
        for (0..col_count) |i| col_names[i] = plan.select_fields[i];
    } else {
        // Auto-detect from first matching item
        if (result_count > 0) {
            const first = items[filtered_indices[0]];
            switch (first) {
                .object => |fields| {
                    for (fields) |f| {
                        if (col_count >= MAX_FIELDS) break;
                        col_names[col_count] = f.key;
                        col_count += 1;
                    }
                },
                else => {
                    col_names[0] = "value";
                    col_count = 1;
                },
            }
        }
    }

    if (col_count == 0 or result_count == 0) return;

    // Phase 5: render table
    var table = rich.Table{};
    for (0..col_count) |i| {
        table.addColumn(.{ .header = col_names[i], .header_color = "\x1b[1;37m" });
    }

    for (0..result_count) |ri| {
        const item = items[filtered_indices[ri]];
        const row = table.addRow();

        for (0..col_count) |ci| {
            const val = getFieldValue(&item, col_names[ci]);
            if (val) |v| {
                var fmt_buf: [128]u8 = undefined;
                const text = v.format(&fmt_buf);
                table.setCellColor(row, ci, text, v.typeColor());
            } else {
                table.setCellColor(row, ci, "null", "\x1b[2m");
            }
        }
    }

    table.render(stdout);
}

// ---------------------------------------------------------------------------
// Where clause evaluation
// ---------------------------------------------------------------------------

fn matchesWhere(item: *const jp.Value, plan: *const QueryPlan) bool {
    const val = getFieldValue(item, plan.where_field) orelse return false;
    return compareValue(&val, plan.where_op, plan.where_value);
}

fn compareValue(val: *const jp.Value, op: Op, rhs_str: []const u8) bool {
    switch (val.*) {
        .number => |n| {
            // Try numeric comparison
            const rhs = std.fmt.parseFloat(f64, rhs_str) catch return false;
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
            // Unquote rhs if needed
            const cmp = if (rhs_str.len >= 2 and rhs_str[0] == '"' and rhs_str[rhs_str.len - 1] == '"')
                rhs_str[1 .. rhs_str.len - 1]
            else
                rhs_str;

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
        .null_val => {
            return switch (op) {
                .eq => std.mem.eql(u8, rhs_str, "null"),
                .neq => !std.mem.eql(u8, rhs_str, "null"),
                else => false,
            };
        },
        else => return false,
    }
}

// ---------------------------------------------------------------------------
// Sorting
// ---------------------------------------------------------------------------

fn sortIndices(items: []const jp.Value, indices: []usize, field: []const u8, desc: bool) void {
    // Insertion sort (stable, good for small-medium arrays)
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const key = indices[i];
        var j: usize = i;
        while (j > 0) {
            const cmp = compareFields(&items[indices[j - 1]], &items[key], field);
            const should_swap = if (desc) cmp < 0 else cmp > 0;
            if (!should_swap) break;
            indices[j] = indices[j - 1];
            j -= 1;
        }
        indices[j] = key;
    }
}

/// Compare two items by a field. Returns -1, 0, or 1.
/// Nulls sort last. Numbers compare numerically. Strings lexicographically.
fn compareFields(a: *const jp.Value, b: *const jp.Value, field: []const u8) i32 {
    const va = getFieldValue(a, field);
    const vb = getFieldValue(b, field);

    // Null handling: nulls sort last
    if (va == null and vb == null) return 0;
    if (va == null) return 1;
    if (vb == null) return -1;

    return compareValues(&va.?, &vb.?);
}

fn compareValues(a: *const jp.Value, b: *const jp.Value) i32 {
    // Same type comparison
    switch (a.*) {
        .number => |na| {
            switch (b.*) {
                .number => |nb| {
                    if (na < nb) return -1;
                    if (na > nb) return 1;
                    return 0;
                },
                else => return -1, // numbers before non-numbers
            }
        },
        .string => |sa| {
            switch (b.*) {
                .string => |sb| {
                    const ord = std.mem.order(u8, sa, sb);
                    return switch (ord) {
                        .lt => @as(i32, -1),
                        .gt => @as(i32, 1),
                        .eq => @as(i32, 0),
                    };
                },
                .number => return 1, // strings after numbers
                else => return -1,
            }
        },
        .boolean => |ba| {
            switch (b.*) {
                .boolean => |bb| {
                    if (ba == bb) return 0;
                    if (ba) return -1; // true before false
                    return 1;
                },
                else => return 1,
            }
        },
        else => return 0,
    }
}

// ---------------------------------------------------------------------------
// Field access
// ---------------------------------------------------------------------------

/// Get a field value from an object. Supports dotted paths: "user.name"
fn getFieldValue(item: *const jp.Value, field: []const u8) ?jp.Value {
    if (field.len == 0) return item.*;

    // Strip leading dot
    const path = if (field[0] == '.') field[1..] else field;
    if (path.len == 0) return item.*;

    var current = item.*;
    var remaining = path;

    while (remaining.len > 0) {
        // Find next dot
        const dot = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
        const segment = remaining[0..dot];
        remaining = if (dot < remaining.len) remaining[dot + 1 ..] else "";

        switch (current) {
            .object => |fields| {
                var found = false;
                for (fields) |f| {
                    if (std.mem.eql(u8, f.key, segment)) {
                        current = f.value;
                        found = true;
                        break;
                    }
                }
                if (!found) return null;
            },
            else => return null,
        }
    }

    return current;
}

// ---------------------------------------------------------------------------
// Query parser
// ---------------------------------------------------------------------------

fn parseQuery(args: []const []const u8) QueryPlan {
    var plan = QueryPlan{};
    var i: usize = 0;

    // First argument starting with '.' is a JSON path
    if (args.len > 0 and args[0].len > 0 and args[0][0] == '.') {
        plan.path = args[0];
        i = 1;
    }

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "select") and i + 1 < args.len) {
            i += 1;
            // Parse comma-separated field list
            var fields_str = args[i];
            while (true) {
                const comma = std.mem.indexOfScalar(u8, fields_str, ',') orelse {
                    if (plan.select_count < MAX_FIELDS and fields_str.len > 0) {
                        plan.select_fields[plan.select_count] = stripDot(fields_str);
                        plan.select_count += 1;
                    }
                    break;
                };
                if (plan.select_count < MAX_FIELDS and comma > 0) {
                    plan.select_fields[plan.select_count] = stripDot(fields_str[0..comma]);
                    plan.select_count += 1;
                }
                fields_str = fields_str[comma + 1 ..];
            }
        } else if (std.mem.eql(u8, arg, "where") and i + 3 < args.len) {
            plan.has_where = true;
            plan.where_field = stripDot(args[i + 1]);
            plan.where_op = parseOp(args[i + 2]);
            plan.where_value = args[i + 3];
            i += 3;
        } else if (std.mem.eql(u8, arg, "sort") and i + 1 < args.len) {
            plan.has_sort = true;
            plan.sort_field = stripDot(args[i + 1]);
            i += 1;
            // Check for asc/desc
            if (i + 1 < args.len) {
                if (std.mem.eql(u8, args[i + 1], "desc")) { plan.sort_desc = true; i += 1; }
                else if (std.mem.eql(u8, args[i + 1], "asc")) { i += 1; }
            }
        } else if (std.mem.eql(u8, arg, "limit") and i + 1 < args.len) {
            plan.limit = std.fmt.parseInt(usize, args[i + 1], 10) catch MAX_ROWS;
            i += 1;
        }

        i += 1;
    }

    return plan;
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

/// Navigate a dotted path into a JSON value.
fn navigatePath(val: *const jp.Value, path: []const u8) ?jp.Value {
    var current = val.*;
    var remaining = path;

    while (remaining.len > 0) {
        const dot = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
        const segment = remaining[0..dot];
        remaining = if (dot < remaining.len) remaining[dot + 1 ..] else "";

        switch (current) {
            .object => |fields| {
                var found = false;
                for (fields) |f| {
                    if (std.mem.eql(u8, f.key, segment)) {
                        current = f.value;
                        found = true;
                        break;
                    }
                }
                if (!found) return null;
            },
            else => return null,
        }
    }

    return current;
}
