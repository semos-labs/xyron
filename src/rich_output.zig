// rich_output.zig — Structured table rendering with ANSI colors.
//
// Provides a simple table builder for nushell-like formatted output
// from built-in commands. Supports column alignment, colors, and
// automatic width calculation.

const std = @import("std");

pub const MAX_COLS: usize = 12;
pub const MAX_ROWS: usize = 512;
pub const MAX_CELL: usize = 128;

pub const Align = enum { left, right };

pub const Column = struct {
    header: []const u8,
    align_: Align = .left,
    color: []const u8 = "", // ANSI color for data cells
    header_color: []const u8 = "\x1b[1;37m", // bold white for headers
};

pub const Cell = struct {
    text: [MAX_CELL]u8 = undefined,
    len: usize = 0,
    color: []const u8 = "", // per-cell override (empty = use column color)

    pub fn slice(self: *const Cell) []const u8 {
        return self.text[0..self.len];
    }
};

pub const Table = struct {
    columns: [MAX_COLS]Column = undefined,
    col_count: usize = 0,
    rows: [MAX_ROWS][MAX_COLS]Cell = undefined,
    row_count: usize = 0,

    pub fn addColumn(self: *Table, col: Column) void {
        if (self.col_count >= MAX_COLS) return;
        self.columns[self.col_count] = col;
        self.col_count += 1;
    }

    pub fn addRow(self: *Table) usize {
        if (self.row_count >= MAX_ROWS) return self.row_count;
        const idx = self.row_count;
        for (0..self.col_count) |c| self.rows[idx][c] = .{};
        self.row_count += 1;
        return idx;
    }

    pub fn setCell(self: *Table, row: usize, col: usize, text: []const u8) void {
        if (row >= self.row_count or col >= self.col_count) return;
        // Copy text, replacing newlines with spaces
        const n = @min(text.len, MAX_CELL);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.rows[row][col].text[i] = if (text[i] == '\n' or text[i] == '\r') ' ' else text[i];
        }
        self.rows[row][col].len = n;
    }

    pub fn setCellColor(self: *Table, row: usize, col: usize, text: []const u8, color: []const u8) void {
        self.setCell(row, col, text); // setCell handles newline stripping
        if (row < self.row_count and col < self.col_count) {
            self.rows[row][col].color = color;
        }
    }

    /// Render the table to stdout.
    pub fn render(self: *const Table, stdout: std.fs.File) void {
        if (self.col_count == 0) return;

        // Calculate column widths, capped to fit terminal
        const term_w = getTermWidth();
        var widths: [MAX_COLS]usize = undefined;
        var total_w: usize = 0;
        for (0..self.col_count) |c| {
            widths[c] = self.columns[c].header.len;
            for (0..self.row_count) |r| {
                // Use visible length (stop at first newline)
                const cell_len = visibleLen(self.rows[r][c].slice());
                widths[c] = @max(widths[c], cell_len);
            }
            // Cap individual columns at 60% of terminal width
            widths[c] = @min(widths[c], term_w * 6 / 10);
        }
        // If total exceeds terminal, shrink the widest column
        total_w = 0;
        for (0..self.col_count) |c| total_w += widths[c] + 2;
        if (total_w > term_w and self.col_count > 0) {
            // Find widest column and shrink it
            var widest: usize = 0;
            for (1..self.col_count) |c| {
                if (widths[c] > widths[widest]) widest = c;
            }
            const excess = total_w - term_w;
            if (widths[widest] > excess + 4) {
                widths[widest] -= excess;
            }
        }

        var buf: [16384]u8 = undefined;
        var pos: usize = 0;

        // Header row
        pos += cp(buf[pos..], "\x1b[2m"); // dim separator line
        for (0..self.col_count) |c| {
            if (c > 0) pos += cp(buf[pos..], "  ");
            pos += cp(buf[pos..], self.columns[c].header_color);
            pos += renderPadded(buf[pos..], self.columns[c].header, widths[c], self.columns[c].align_);
            pos += cp(buf[pos..], "\x1b[0m");
        }
        pos += cp(buf[pos..], "\n");

        // Separator
        pos += cp(buf[pos..], "\x1b[2m");
        for (0..self.col_count) |c| {
            if (c > 0) pos += cp(buf[pos..], "──");
            for (0..widths[c]) |_| {
                if (pos < buf.len) { buf[pos] = 0xe2; pos += 1; } // ─ (UTF-8: e2 94 80)
                if (pos < buf.len) { buf[pos] = 0x94; pos += 1; }
                if (pos < buf.len) { buf[pos] = 0x80; pos += 1; }
            }
        }
        pos += cp(buf[pos..], "\x1b[0m\n");

        // Flush header
        stdout.writeAll(buf[0..pos]) catch {};
        pos = 0;

        // Data rows
        for (0..self.row_count) |r| {
            for (0..self.col_count) |c| {
                if (c > 0) pos += cp(buf[pos..], "  ");
                const cell = &self.rows[r][c];
                const color = if (cell.color.len > 0) cell.color else self.columns[c].color;
                if (color.len > 0) pos += cp(buf[pos..], color);
                pos += renderCell(buf[pos..], cell.slice(), widths[c], self.columns[c].align_);
                if (color.len > 0) pos += cp(buf[pos..], "\x1b[0m");
            }
            pos += cp(buf[pos..], "\n");

            // Flush periodically
            if (pos > buf.len - 1024) {
                stdout.writeAll(buf[0..pos]) catch {};
                pos = 0;
            }
        }

        if (pos > 0) stdout.writeAll(buf[0..pos]) catch {};
    }
};

fn renderCell(dest: []u8, text: []const u8, width: usize, align_: Align) usize {
    // Truncate to width, strip newlines, add ellipsis if needed
    const clean = visiblePart(text);
    if (clean.len <= width) return renderPadded(dest, clean, width, align_);

    // Truncate with ellipsis
    if (width > 3) {
        var pos: usize = 0;
        pos += cp(dest[pos..], clean[0 .. width - 3]);
        pos += cp(dest[pos..], "...");
        return pos;
    }
    return renderPadded(dest, clean[0..width], width, align_);
}

fn visiblePart(text: []const u8) []const u8 {
    // Return text up to first newline
    for (text, 0..) |ch, i| {
        if (ch == '\n' or ch == '\r') return text[0..i];
    }
    return text;
}

fn visibleLen(text: []const u8) usize {
    return visiblePart(text).len;
}

fn getTermWidth() usize {
    const c_ext = struct {
        const winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    };
    var ws: c_ext.winsize = undefined;
    if (c_ext.ioctl(std.posix.STDOUT_FILENO, 0x40087468, &ws) == 0 and ws.ws_col > 0) return ws.ws_col;
    return 80;
}

fn renderPadded(dest: []u8, text: []const u8, width: usize, align_: Align) usize {
    var pos: usize = 0;
    const pad = if (width > text.len) width - text.len else 0;

    if (align_ == .right) {
        for (0..pad) |_| { if (pos < dest.len) { dest[pos] = ' '; pos += 1; } }
    }
    pos += cp(dest[pos..], text);
    if (align_ == .left) {
        for (0..pad) |_| { if (pos < dest.len) { dest[pos] = ' '; pos += 1; } }
    }
    return pos;
}

// ---------------------------------------------------------------------------
// Color helpers for file types
// ---------------------------------------------------------------------------

pub fn fileTypeColor(kind: std.fs.Dir.Entry.Kind) []const u8 {
    return switch (kind) {
        .directory => "\x1b[1;34m", // bold blue
        .sym_link => "\x1b[1;36m", // bold cyan
        .named_pipe => "\x1b[33m", // yellow
        .unix_domain_socket => "\x1b[1;35m", // bold magenta
        else => "",
    };
}

pub fn sizeColor(size: u64) []const u8 {
    if (size >= 1024 * 1024) return "\x1b[1;31m"; // bold red for large
    if (size >= 1024) return "\x1b[33m"; // yellow for medium
    return "\x1b[32m"; // green for small
}

/// Format a file size as human-readable.
pub fn formatSize(buf: []u8, size: u64) []const u8 {
    if (size >= 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1}G", .{@as(f64, @floatFromInt(size)) / (1024 * 1024 * 1024)}) catch "-";
    }
    if (size >= 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1}M", .{@as(f64, @floatFromInt(size)) / (1024 * 1024)}) catch "-";
    }
    if (size >= 1024) {
        return std.fmt.bufPrint(buf, "{d:.1}K", .{@as(f64, @floatFromInt(size)) / 1024}) catch "-";
    }
    return std.fmt.bufPrint(buf, "{d}B", .{size}) catch "-";
}

fn cp(dest: []u8, src: []const u8) usize {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "formatSize" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("100B", formatSize(&buf, 100));
    try std.testing.expectEqualStrings("1.0K", formatSize(&buf, 1024));
}

test "table renders without crash" {
    var table = Table{};
    table.addColumn(.{ .header = "Name" });
    table.addColumn(.{ .header = "Size", .align_ = .right });
    const r = table.addRow();
    table.setCell(r, 0, "file.txt");
    table.setCell(r, 1, "1.2K");
    // Can't easily test stdout output, just verify no crash
    const devnull = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch return;
    defer devnull.close();
    table.render(devnull);
}
