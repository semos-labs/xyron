const std = @import("std");
const rich = @import("../rich_output.zig");
const Result = @import("mod.zig").BuiltinResult;

pub fn run(args: []const []const u8, stdout: std.fs.File) Result {
    var show_all = false;
    var show_long = false;
    var target: []const u8 = ".";

    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |ch| switch (ch) {
                'a' => show_all = true,
                'l' => show_long = true,
                else => return .{ .exit_code = 255 },
            };
        } else target = arg;
    }

    var dir = if (target[0] == '/')
        std.fs.openDirAbsolute(target, .{ .iterate = true }) catch return err(stdout)
    else
        std.fs.cwd().openDir(target, .{ .iterate = true }) catch return err(stdout);
    defer dir.close();

    var tbl = rich.Table{};
    if (show_long) tbl.addColumn(.{ .header = "permissions", .color = "\x1b[2m" });
    tbl.addColumn(.{ .header = "name", .color = "" });
    if (show_long) tbl.addColumn(.{ .header = "size", .align_ = .right, .color = "" });

    var names: [512][256]u8 = undefined;
    var kinds: [512]std.fs.Dir.Entry.Kind = undefined;
    var sizes: [512]u64 = undefined;
    var modes: [512]u32 = undefined;
    var name_lens: [512]usize = undefined;
    var count: usize = 0;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (count >= 512) break;
        if (!show_all and entry.name.len > 0 and entry.name[0] == '.') continue;
        const nl = @min(entry.name.len, 255);
        @memcpy(names[count][0..nl], entry.name[0..nl]);
        name_lens[count] = nl;
        kinds[count] = entry.kind;
        sizes[count] = 0;
        modes[count] = 0;
        if (dir.openFile(entry.name, .{})) |f| {
            defer f.close();
            if (f.stat()) |s| { sizes[count] = s.size; modes[count] = s.mode; } else |_| {}
        } else |_| {
            if (dir.openDir(entry.name, .{})) |*d2| {
                var dm = d2.*;
                defer dm.close();
                if (dm.stat()) |s| { modes[count] = s.mode; } else |_| {}
            } else |_| {}
        }
        count += 1;
    }

    // Sort
    var i: usize = 1;
    while (i < count) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, names[j][0..name_lens[j]], names[j - 1][0..name_lens[j - 1]]) == .lt) {
            std.mem.swap([256]u8, &names[j], &names[j - 1]);
            std.mem.swap(std.fs.Dir.Entry.Kind, &kinds[j], &kinds[j - 1]);
            std.mem.swap(u64, &sizes[j], &sizes[j - 1]);
            std.mem.swap(u32, &modes[j], &modes[j - 1]);
            std.mem.swap(usize, &name_lens[j], &name_lens[j - 1]);
            j -= 1;
        }
    }

    for (0..count) |ei| {
        const r = tbl.addRow();
        var col: usize = 0;
        if (show_long) {
            var perm: [10]u8 = undefined;
            perm[0] = if (kinds[ei] == .directory) @as(u8, 'd') else if (kinds[ei] == .sym_link) @as(u8, 'l') else @as(u8, '-');
            inline for (.{ 0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001 }, 0..) |mask, pi| {
                perm[pi + 1] = if (modes[ei] & mask != 0) ("rwxrwxrwx"[pi]) else '-';
            }
            const pc: []const u8 = if (kinds[ei] == .directory) "\x1b[34m" else "\x1b[2m";
            tbl.setCellColor(r, col, &perm, pc);
            col += 1;
        }
        var disp: [258]u8 = undefined;
        const name = names[ei][0..name_lens[ei]];
        @memcpy(disp[0..name.len], name);
        var dl = name.len;
        if (kinds[ei] == .directory and dl < 257) { disp[dl] = '/'; dl += 1; }
        tbl.setCellColor(r, col, disp[0..dl], rich.fileTypeColor(kinds[ei]));
        col += 1;
        if (show_long) {
            if (kinds[ei] == .file) {
                var sb: [32]u8 = undefined;
                tbl.setCellColor(r, col, rich.formatSize(&sb, sizes[ei]), rich.sizeColor(sizes[ei]));
            } else tbl.setCell(r, col, "-");
        }
    }
    tbl.render(stdout);
    return .{};
}

fn err(stdout: std.fs.File) Result {
    stdout.writeAll("xyron: ls: cannot open directory\n") catch {};
    return .{ .exit_code = 1 };
}
