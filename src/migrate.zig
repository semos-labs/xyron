// migrate.zig — Bash/sh migration analyzer and converter.
//
// Scans shell constructs, classifies compatibility, and generates
// Xyron/Lua equivalents for safe patterns. Produces structured
// findings for everything it encounters.

const std = @import("std");

// ---------------------------------------------------------------------------
// Finding model
// ---------------------------------------------------------------------------

pub const Severity = enum { info, warning, err };
pub const Status = enum { supported, partial, unsupported };

pub const Finding = struct {
    line: usize,
    severity: Severity,
    status: Status,
    kind: []const u8,
    message: []const u8,
    original: []const u8,
    suggestion: []const u8,
};

pub const MAX_FINDINGS: usize = 256;

pub const Report = struct {
    findings: [MAX_FINDINGS]Finding = undefined,
    count: usize = 0,
    supported_count: usize = 0,
    partial_count: usize = 0,
    unsupported_count: usize = 0,

    pub fn add(self: *Report, f: Finding) void {
        if (self.count >= MAX_FINDINGS) return;
        self.findings[self.count] = f;
        self.count += 1;
        switch (f.status) {
            .supported => self.supported_count += 1,
            .partial => self.partial_count += 1,
            .unsupported => self.unsupported_count += 1,
        }
    }

    pub fn overallStatus(self: *const Report) Status {
        if (self.unsupported_count > 0) return .unsupported;
        if (self.partial_count > 0) return .partial;
        return .supported;
    }
};

// ---------------------------------------------------------------------------
// Analyzer — scan lines and classify constructs
// ---------------------------------------------------------------------------

pub fn analyze(input: []const u8) Report {
    var report = Report{};
    var line_num: usize = 1;

    var iter = std.mem.splitScalar(u8, input, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            line_num += 1;
            continue;
        }
        analyzeLine(&report, trimmed, line_num);
        line_num += 1;
    }
    return report;
}

fn analyzeLine(report: *Report, line: []const u8, num: usize) void {
    // Shebang
    if (std.mem.startsWith(u8, line, "#!")) return;

    // export NAME=value
    if (std.mem.startsWith(u8, line, "export ")) {
        report.add(.{ .line = num, .severity = .info, .status = .supported, .kind = "export", .message = "Direct equivalent: xyron.setenv()", .original = line, .suggestion = convertExport(line) });
        return;
    }

    // unset NAME
    if (std.mem.startsWith(u8, line, "unset ")) {
        report.add(.{ .line = num, .severity = .info, .status = .supported, .kind = "unset", .message = "Direct equivalent: xyron.unsetenv()", .original = line, .suggestion = convertUnset(line) });
        return;
    }

    // alias name='...'
    if (std.mem.startsWith(u8, line, "alias ")) {
        report.add(.{ .line = num, .severity = .info, .status = .supported, .kind = "alias", .message = "Direct equivalent: xyron.alias()", .original = line, .suggestion = convertAlias(line) });
        return;
    }

    // Variable assignment: NAME=value (no spaces around =)
    if (isSimpleAssignment(line)) {
        report.add(.{ .line = num, .severity = .info, .status = .supported, .kind = "assignment", .message = "Use xyron.setenv() or export", .original = line, .suggestion = convertAssignment(line) });
        return;
    }

    // eval
    if (std.mem.startsWith(u8, line, "eval ")) {
        report.add(.{ .line = num, .severity = .err, .status = .unsupported, .kind = "eval", .message = "eval is not supported — use xyron.exec() or Lua", .original = line, .suggestion = "" });
        return;
    }

    // trap
    if (std.mem.startsWith(u8, line, "trap ")) {
        report.add(.{ .line = num, .severity = .err, .status = .unsupported, .kind = "trap", .message = "trap is not supported — use Lua hooks (xyron.on())", .original = line, .suggestion = "" });
        return;
    }

    // set -e/-u/-o
    if (std.mem.startsWith(u8, line, "set ")) {
        report.add(.{ .line = num, .severity = .warning, .status = .unsupported, .kind = "set", .message = "Shell execution modes not supported", .original = line, .suggestion = "" });
        return;
    }

    // source / .
    if (std.mem.startsWith(u8, line, "source ") or std.mem.startsWith(u8, line, ". ")) {
        report.add(.{ .line = num, .severity = .warning, .status = .partial, .kind = "source", .message = "Use xyron.exec() or require() in Lua config", .original = line, .suggestion = "" });
        return;
    }

    // function name() { or name() {
    if (std.mem.startsWith(u8, line, "function ") or std.mem.indexOf(u8, line, "() {") != null) {
        report.add(.{ .line = num, .severity = .warning, .status = .partial, .kind = "function", .message = "Convert to xyron.command() in Lua config", .original = line, .suggestion = "" });
        return;
    }

    // if/then/fi → Lua if/then/end
    if (std.mem.startsWith(u8, line, "if ")) {
        report.add(.{ .line = num, .severity = .info, .status = .partial, .kind = "if", .message = "Convert to Lua: if ... then", .original = line, .suggestion = convertIf(line) });
        return;
    }
    if (std.mem.eql(u8, line, "then")) {
        report.add(.{ .line = num, .severity = .info, .status = .partial, .kind = "then", .message = "Part of if block", .original = line, .suggestion = "then" });
        return;
    }
    if (std.mem.eql(u8, line, "fi")) {
        report.add(.{ .line = num, .severity = .info, .status = .partial, .kind = "fi", .message = "End of if block", .original = line, .suggestion = "end" });
        return;
    }
    if (std.mem.startsWith(u8, line, "else")) {
        report.add(.{ .line = num, .severity = .info, .status = .partial, .kind = "else", .message = "Else branch", .original = line, .suggestion = "else" });
        return;
    }
    if (std.mem.startsWith(u8, line, "elif ")) {
        report.add(.{ .line = num, .severity = .info, .status = .partial, .kind = "elif", .message = "Convert to Lua: elseif", .original = line, .suggestion = convertElif(line) });
        return;
    }

    // for/do/done → Lua for/do/end
    if (std.mem.startsWith(u8, line, "for ")) {
        report.add(.{ .line = num, .severity = .info, .status = .partial, .kind = "for", .message = "Convert to Lua: for ... do", .original = line, .suggestion = convertFor(line) });
        return;
    }
    if (std.mem.startsWith(u8, line, "while ")) {
        report.add(.{ .line = num, .severity = .info, .status = .partial, .kind = "while", .message = "Convert to Lua: while ... do", .original = line, .suggestion = convertWhile(line) });
        return;
    }
    if (std.mem.eql(u8, line, "do")) {
        report.add(.{ .line = num, .severity = .info, .status = .partial, .kind = "do", .message = "Loop body start", .original = line, .suggestion = "do" });
        return;
    }
    if (std.mem.eql(u8, line, "done")) {
        report.add(.{ .line = num, .severity = .info, .status = .partial, .kind = "done", .message = "End of loop", .original = line, .suggestion = "end" });
        return;
    }

    // case/esac — harder to auto-convert
    if (std.mem.startsWith(u8, line, "case ") or std.mem.eql(u8, line, "esac")) {
        report.add(.{ .line = num, .severity = .warning, .status = .partial, .kind = "case", .message = "Convert to Lua if/elseif chain", .original = line, .suggestion = "" });
        return;
    }

    // $(...) command substitution
    if (std.mem.indexOf(u8, line, "$(") != null) {
        report.add(.{ .line = num, .severity = .warning, .status = .partial, .kind = "cmd-substitution", .message = "Command substitution not yet supported — use xyron.exec()", .original = line, .suggestion = "" });
        return;
    }

    // ${...} parameter expansion
    if (std.mem.indexOf(u8, line, "${") != null) {
        report.add(.{ .line = num, .severity = .warning, .status = .partial, .kind = "param-expansion", .message = "Advanced parameter expansion not supported — use simple $NAME", .original = line, .suggestion = "" });
        return;
    }

    // [[ ... ]] or [ ... ] test — convert to Lua equivalent
    if (std.mem.startsWith(u8, line, "[[") or std.mem.startsWith(u8, line, "[ ")) {
        report.add(.{ .line = num, .severity = .info, .status = .partial, .kind = "test", .message = "Convert test to Lua expression", .original = line, .suggestion = convertTest(line) });
        return;
    }

    // && and || sequencing
    if (std.mem.indexOf(u8, line, " && ") != null or std.mem.indexOf(u8, line, " || ") != null) {
        report.add(.{ .line = num, .severity = .warning, .status = .partial, .kind = "sequencing", .message = "&& and || not yet supported — split into separate commands", .original = line, .suggestion = "" });
        return;
    }

    // Simple command — likely supported
    report.add(.{ .line = num, .severity = .info, .status = .supported, .kind = "command", .message = "Shell command", .original = line, .suggestion = line });
}

// ---------------------------------------------------------------------------
// Converters — generate Xyron/Lua equivalents
// ---------------------------------------------------------------------------

var convert_buf: [512]u8 = undefined;

fn convertExport(line: []const u8) []const u8 {
    // "export FOO=bar" → "xyron.setenv('FOO', 'bar')"
    const rest = line["export ".len..];
    const eq = std.mem.indexOf(u8, rest, "=") orelse return line;
    const key = rest[0..eq];
    const val = stripQuotes(rest[eq + 1 ..]);
    return std.fmt.bufPrint(&convert_buf, "xyron.setenv('{s}', '{s}')", .{ key, val }) catch line;
}

fn convertUnset(line: []const u8) []const u8 {
    const name = std.mem.trim(u8, line["unset ".len..], " \t");
    return std.fmt.bufPrint(&convert_buf, "xyron.unsetenv('{s}')", .{name}) catch line;
}

fn convertAlias(line: []const u8) []const u8 {
    // "alias ll='ls -la'" → "xyron.alias('ll', 'ls -la')"
    const rest = line["alias ".len..];
    const eq = std.mem.indexOf(u8, rest, "=") orelse return line;
    const name = rest[0..eq];
    const val = stripQuotes(rest[eq + 1 ..]);
    return std.fmt.bufPrint(&convert_buf, "xyron.alias('{s}', '{s}')", .{ name, val }) catch line;
}

fn convertAssignment(line: []const u8) []const u8 {
    const eq = std.mem.indexOf(u8, line, "=") orelse return line;
    const key = line[0..eq];
    const val = stripQuotes(line[eq + 1 ..]);
    return std.fmt.bufPrint(&convert_buf, "xyron.setenv('{s}', '{s}')", .{ key, val }) catch line;
}

var convert_buf2: [512]u8 = undefined;
var convert_buf3: [512]u8 = undefined;
var convert_buf4: [512]u8 = undefined;
var convert_buf5: [512]u8 = undefined;
var convert_buf6: [512]u8 = undefined;

fn convertIf(line: []const u8) []const u8 {
    // "if [ -f file ]; then" → "if os.execute('test -f file') then"
    // "if [ "$X" = "y" ]; then" → simplified
    const rest = line["if ".len..];
    // Strip trailing "; then"
    const body = if (std.mem.indexOf(u8, rest, "; then")) |idx| rest[0..idx] else rest;
    const cond = std.mem.trim(u8, body, " \t[]");
    return std.fmt.bufPrint(&convert_buf2, "if {s} then", .{convertCondition(cond)}) catch line;
}

fn convertElif(line: []const u8) []const u8 {
    const rest = line["elif ".len..];
    const body = if (std.mem.indexOf(u8, rest, "; then")) |idx| rest[0..idx] else rest;
    const cond = std.mem.trim(u8, body, " \t[]");
    return std.fmt.bufPrint(&convert_buf3, "elseif {s} then", .{convertCondition(cond)}) catch line;
}

fn convertFor(line: []const u8) []const u8 {
    // "for x in a b c; do" → "for _, x in ipairs({'a', 'b', 'c'}) do"
    const rest = line["for ".len..];
    const in_pos = std.mem.indexOf(u8, rest, " in ") orelse return line;
    const var_name = std.mem.trim(u8, rest[0..in_pos], " \t");
    var after_in = rest[in_pos + 4 ..];
    // Strip trailing "; do"
    if (std.mem.indexOf(u8, after_in, "; do")) |idx| after_in = after_in[0..idx];
    return std.fmt.bufPrint(&convert_buf4, "for _, {s} in ipairs({{{s}}}) do", .{ var_name, after_in }) catch line;
}

fn convertWhile(line: []const u8) []const u8 {
    const rest = line["while ".len..];
    const body = if (std.mem.indexOf(u8, rest, "; do")) |idx| rest[0..idx] else rest;
    const cond = std.mem.trim(u8, body, " \t[]");
    return std.fmt.bufPrint(&convert_buf5, "while {s} do", .{convertCondition(cond)}) catch line;
}

fn convertTest(line: []const u8) []const u8 {
    // Strip [[ ]] or [ ]
    var inner = line;
    if (std.mem.startsWith(u8, inner, "[[")) inner = inner[2..];
    if (std.mem.startsWith(u8, inner, "[ ")) inner = inner[2..];
    if (std.mem.endsWith(u8, inner, "]]")) inner = inner[0 .. inner.len - 2];
    if (std.mem.endsWith(u8, inner, " ]")) inner = inner[0 .. inner.len - 2];
    return convertCondition(std.mem.trim(u8, inner, " \t"));
}

fn convertCondition(cond: []const u8) []const u8 {
    // -f file → file_exists('file')
    if (std.mem.startsWith(u8, cond, "-f ")) {
        const path = std.mem.trim(u8, cond[3..], " \t\"'");
        return std.fmt.bufPrint(&convert_buf6, "file_exists('{s}')", .{path}) catch cond;
    }
    if (std.mem.startsWith(u8, cond, "-d ")) {
        const path = std.mem.trim(u8, cond[3..], " \t\"'");
        return std.fmt.bufPrint(&convert_buf6, "dir_exists('{s}')", .{path}) catch cond;
    }
    if (std.mem.startsWith(u8, cond, "-z ")) {
        const var_name = std.mem.trim(u8, cond[3..], " \t\"'$");
        return std.fmt.bufPrint(&convert_buf6, "(xyron.getenv('{s}') or '') == ''", .{var_name}) catch cond;
    }
    if (std.mem.startsWith(u8, cond, "-n ")) {
        const var_name = std.mem.trim(u8, cond[3..], " \t\"'$");
        return std.fmt.bufPrint(&convert_buf6, "(xyron.getenv('{s}') or '') ~= ''", .{var_name}) catch cond;
    }
    // "x" = "y" → x == y
    if (std.mem.indexOf(u8, cond, " = ")) |_| {
        return std.fmt.bufPrint(&convert_buf6, "{s}", .{
            std.mem.replaceOwned(u8, std.heap.page_allocator, cond, " = ", " == ") catch return cond,
        }) catch cond;
    }
    return cond;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '\'' or s[0] == '"') and s[s.len - 1] == s[0]) {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn isSimpleAssignment(line: []const u8) bool {
    const eq = std.mem.indexOf(u8, line, "=") orelse return false;
    if (eq == 0) return false;
    // Before = must be valid identifier chars
    for (line[0..eq]) |ch| {
        if (!((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_')) return false;
    }
    // Must not start with a digit
    if (line[0] >= '0' and line[0] <= '9') return false;
    return true;
}

// ---------------------------------------------------------------------------
// Full conversion — generate Lua config from analyzed script
// ---------------------------------------------------------------------------

pub fn convert(input: []const u8, out: []u8) usize {
    var pos: usize = 0;
    pos += cp(out[pos..], "-- Xyron config (auto-converted from bash/sh)\n");
    pos += cp(out[pos..], "-- Review TODO items before using\n\n");

    var line_num: usize = 1;
    var iter = std.mem.splitScalar(u8, input, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            pos += cp(out[pos..], "\n");
            line_num += 1;
            continue;
        }
        if (trimmed[0] == '#') {
            pos += cp(out[pos..], trimmed);
            pos += cp(out[pos..], "\n");
            line_num += 1;
            continue;
        }

        var dummy = Report{};
        analyzeLine(&dummy, trimmed, line_num);
        if (dummy.count > 0) {
            const f = &dummy.findings[0];
            switch (f.status) {
                .supported => {
                    if (f.suggestion.len > 0 and !std.mem.eql(u8, f.suggestion, trimmed)) {
                        pos += cp(out[pos..], f.suggestion);
                    } else {
                        pos += cp(out[pos..], "-- ");
                        pos += cp(out[pos..], trimmed);
                    }
                },
                .partial => {
                    if (f.suggestion.len > 0 and !std.mem.eql(u8, f.suggestion, trimmed)) {
                        // Has a Lua equivalent — emit it with the original as comment
                        pos += cp(out[pos..], f.suggestion);
                        pos += cp(out[pos..], "  -- was: ");
                        pos += cp(out[pos..], trimmed);
                    } else {
                        pos += cp(out[pos..], "-- TODO: ");
                        pos += cp(out[pos..], f.message);
                        pos += cp(out[pos..], "\n-- ");
                        pos += cp(out[pos..], trimmed);
                    }
                },
                .unsupported => {
                    pos += cp(out[pos..], "-- UNSUPPORTED: ");
                    pos += cp(out[pos..], f.message);
                    pos += cp(out[pos..], "\n-- ");
                    pos += cp(out[pos..], trimmed);
                },
            }
            pos += cp(out[pos..], "\n");
        }
        line_num += 1;
    }
    return pos;
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "analyze export" {
    const r = analyze("export FOO=bar");
    try std.testing.expectEqual(@as(usize, 1), r.count);
    try std.testing.expectEqual(Status.supported, r.findings[0].status);
}

test "analyze eval" {
    const r = analyze("eval \"echo hello\"");
    try std.testing.expectEqual(Status.unsupported, r.findings[0].status);
}

test "analyze alias" {
    const r = analyze("alias ll='ls -la'");
    try std.testing.expectEqual(Status.supported, r.findings[0].status);
}

test "analyze function" {
    const r = analyze("function greet() {");
    try std.testing.expectEqual(Status.partial, r.findings[0].status);
}

test "analyze simple command" {
    const r = analyze("echo hello");
    try std.testing.expectEqual(Status.supported, r.findings[0].status);
}

test "overall status" {
    const r = analyze("export FOO=bar\neval bad\necho ok");
    try std.testing.expectEqual(Status.unsupported, r.overallStatus());
}
