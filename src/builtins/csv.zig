// csv.zig — CSV parser and structured output.
//
// Reads CSV from stdin (pipe target), renders as table or outputs JSON.
// Supports custom separator and header row selection.
//
// Usage:
//   cat data.csv | csv                         # auto-detect, first row = header
//   cat data.csv | csv --sep ";" --header 0    # semicolon separator, header at row 0
//   cat data.csv | csv --no-header             # no header row, columns are col1,col2,...
//   cat data.tsv | csv --sep "\t"              # TSV support
//   cat data.csv | csv | where age > 25        # chain with queries (JSON output)

const std = @import("std");
const posix = std.posix;
const rich = @import("../rich_output.zig");
const pj = @import("../pipe_json.zig");
const Result = @import("mod.zig").BuiltinResult;

const MAX_COLS: usize = 64;
const MAX_ROWS: usize = 4096;

const Options = struct {
    separator: u8 = ',',
    header_row: ?usize = 0, // null = no header
};

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) u8 {
    _ = stdout;
    _ = args;
    stderr.writeAll("Usage: ... | csv [--sep \",\"] [--header N] [--no-header]\n") catch {};
    return 1;
}

pub fn runFromPipe(args: []const []const u8) void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    const opts = parseOptions(args);

    // Read all stdin
    var input_buf: [1048576]u8 = undefined; // 1MB
    const input = pj.readStdin(&input_buf);
    if (input.len == 0) { stderr.writeAll("csv: no input\n") catch {}; std.process.exit(1); }

    // Parse CSV into rows of cells
    var rows: [MAX_ROWS][MAX_COLS]CsvCell = undefined;
    var row_count: usize = 0;
    var col_count: usize = 0;

    var line_iter = std.mem.splitScalar(u8, input, '\n');
    while (line_iter.next()) |line| {
        if (row_count >= MAX_ROWS) break;
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;

        var col: usize = 0;
        var field_iter = FieldIterator{ .data = trimmed, .sep = opts.separator };
        while (field_iter.next()) |field| {
            if (col >= MAX_COLS) break;
            rows[row_count][col] = field;
            col += 1;
        }
        if (col > col_count) col_count = col;
        // Pad remaining cols
        while (col < col_count) : (col += 1) {
            rows[row_count][col] = .{ .start = 0, .end = 0, .source = trimmed };
        }
        row_count += 1;
    }

    if (row_count == 0 or col_count == 0) { stderr.writeAll("csv: empty input\n") catch {}; std.process.exit(1); }

    // Determine header names
    var headers: [MAX_COLS][]const u8 = undefined;
    var data_start: usize = 0;

    if (opts.header_row) |hr| {
        if (hr < row_count) {
            for (0..col_count) |c| {
                headers[c] = rows[hr][c].slice();
            }
            data_start = hr + 1;
        } else {
            genHeaders(&headers, col_count);
        }
    } else {
        genHeaders(&headers, col_count);
    }

    const data_count = row_count - data_start;

    // Output
    if (pj.isTerminal(posix.STDOUT_FILENO)) {
        // Table output
        var tbl = rich.Table{};
        for (0..col_count) |c| {
            tbl.addColumn(.{ .header = headers[c], .header_color = "\x1b[1;37m" });
        }
        for (data_start..row_count) |ri| {
            const r = tbl.addRow();
            for (0..col_count) |c| {
                const val = rows[ri][c].slice();
                // Color numbers cyan, rest default
                if (isNumeric(val)) {
                    tbl.setCellColor(r, c, val, "\x1b[36m");
                } else {
                    tbl.setCell(r, c, val);
                }
            }
        }
        tbl.render(stdout);
    } else {
        // JSON output for piping to where/select/sort
        var buf: [1048576]u8 = undefined;
        var pos: usize = 0;

        appendChar(&buf, &pos, '[');
        for (data_start..row_count, 0..) |ri, di| {
            if (di > 0) appendChar(&buf, &pos, ',');
            appendChar(&buf, &pos, '{');
            for (0..col_count) |c| {
                if (c > 0) appendChar(&buf, &pos, ',');
                // Key
                appendChar(&buf, &pos, '"');
                appendSlice(&buf, &pos, headers[c]);
                appendSlice(&buf, &pos, "\":");
                // Value — try to output as number if numeric
                const val = rows[ri][c].slice();
                if (isNumeric(val) and val.len > 0) {
                    appendSlice(&buf, &pos, val);
                } else {
                    appendChar(&buf, &pos, '"');
                    appendEscaped(&buf, &pos, val);
                    appendChar(&buf, &pos, '"');
                }
            }
            appendChar(&buf, &pos, '}');
            // Flush periodically
            if (pos > buf.len - 4096) {
                stdout.writeAll(buf[0..pos]) catch {};
                pos = 0;
            }
        }
        appendChar(&buf, &pos, ']');
        stdout.writeAll(buf[0..pos]) catch {};
    }

    _ = data_count;
    std.process.exit(0);
}

// ---------------------------------------------------------------------------
// CSV field parsing (handles quoted fields)
// ---------------------------------------------------------------------------

const CsvCell = struct {
    start: usize,
    end: usize,
    source: []const u8,

    fn slice(self: CsvCell) []const u8 {
        if (self.start >= self.source.len) return "";
        return self.source[self.start..@min(self.end, self.source.len)];
    }
};

const FieldIterator = struct {
    data: []const u8,
    sep: u8,
    pos: usize = 0,

    fn next(self: *FieldIterator) ?CsvCell {
        if (self.pos > self.data.len) return null;
        if (self.pos == self.data.len) {
            self.pos += 1;
            return .{ .start = self.data.len, .end = self.data.len, .source = self.data };
        }

        if (self.data[self.pos] == '"') {
            // Quoted field
            const start = self.pos + 1;
            var end = start;
            while (end < self.data.len) {
                if (self.data[end] == '"') {
                    if (end + 1 < self.data.len and self.data[end + 1] == '"') {
                        end += 2; // escaped quote
                        continue;
                    }
                    break;
                }
                end += 1;
            }
            self.pos = if (end + 1 < self.data.len and self.data[end] == '"') end + 2 else end + 1; // skip closing quote + sep
            return .{ .start = start, .end = end, .source = self.data };
        }

        // Unquoted field
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != self.sep) : (self.pos += 1) {}
        const end = self.pos;
        if (self.pos < self.data.len) self.pos += 1; // skip separator
        // Trim whitespace
        const trimmed_start = std.mem.trimLeft(u8, self.data[start..end], " ").ptr - self.data.ptr;
        const trimmed_end = start + std.mem.trimRight(u8, self.data[start..end], " ").len;
        return .{ .start = trimmed_start, .end = trimmed_end, .source = self.data };
    }
};

// ---------------------------------------------------------------------------
// Options parsing
// ---------------------------------------------------------------------------

fn parseOptions(args: []const []const u8) Options {
    var opts = Options{};
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "--sep") or std.mem.eql(u8, arg, "-s")) and i + 1 < args.len) {
            i += 1;
            const sep = args[i];
            if (std.mem.eql(u8, sep, "\\t") or std.mem.eql(u8, sep, "tab")) {
                opts.separator = '\t';
            } else if (sep.len > 0) {
                opts.separator = sep[0];
            }
        } else if ((std.mem.eql(u8, arg, "--header") or std.mem.eql(u8, arg, "-h")) and i + 1 < args.len) {
            i += 1;
            opts.header_row = std.fmt.parseInt(usize, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--no-header")) {
            opts.header_row = null;
        }
        i += 1;
    }
    return opts;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn genHeaders(headers: *[MAX_COLS][]const u8, count: usize) void {
    const names = [_][]const u8{
        "col1",  "col2",  "col3",  "col4",  "col5",  "col6",  "col7",  "col8",
        "col9",  "col10", "col11", "col12", "col13", "col14", "col15", "col16",
        "col17", "col18", "col19", "col20", "col21", "col22", "col23", "col24",
        "col25", "col26", "col27", "col28", "col29", "col30", "col31", "col32",
        "col33", "col34", "col35", "col36", "col37", "col38", "col39", "col40",
        "col41", "col42", "col43", "col44", "col45", "col46", "col47", "col48",
        "col49", "col50", "col51", "col52", "col53", "col54", "col55", "col56",
        "col57", "col58", "col59", "col60", "col61", "col62", "col63", "col64",
    };
    for (0..count) |c| headers[c] = names[c];
}

fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    var has_dot = false;
    for (s, 0..) |ch, i| {
        if (ch == '-' and i == 0) continue;
        if (ch == '.' and !has_dot) { has_dot = true; continue; }
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn appendChar(buf: []u8, pos: *usize, ch: u8) void {
    if (pos.* < buf.len) { buf[pos.*] = ch; pos.* += 1; }
}

fn appendSlice(buf: []u8, pos: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - pos.*);
    @memcpy(buf[pos.*..][0..n], s[0..n]);
    pos.* += n;
}

fn appendEscaped(buf: []u8, pos: *usize, s: []const u8) void {
    for (s) |ch| {
        if (ch == '"' or ch == '\\') {
            appendChar(buf, pos, '\\');
            appendChar(buf, pos, ch);
        } else if (ch == '\n') {
            appendSlice(buf, pos, "\\n");
        } else if (ch == '\r') {
            appendSlice(buf, pos, "\\r");
        } else if (ch == '\t') {
            appendSlice(buf, pos, "\\t");
        } else {
            appendChar(buf, pos, ch);
        }
    }
}
