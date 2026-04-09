// builtins/bookmarks_cmd.zig — Bookmarks TUI browser and CLI commands.
//
// `xyron bookmarks` — TUI browser (list, add, edit, delete)
// `xyron bookmarks add <name> <command> [--description "..."]`
// `xyron bookmarks remove <name>`
// `xyron bookmarks list`

const std = @import("std");
const posix = std.posix;
const c = std.c;
const bookmarks = @import("../bookmarks.zig");
const style = @import("../style.zig");
const tui = @import("../tui.zig");
const keys = @import("../keys.zig");
const Result = @import("mod.zig").BuiltinResult;

const Screen = tui.Screen;
const Key = keys.Key;

pub fn run(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len == 0) return runTui(stdout, stderr);
    const subcmd = args[0];
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
    if (std.mem.eql(u8, subcmd, "add")) return runAdd(sub_args, stdout, stderr);
    if (std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "rm")) return runRemove(sub_args, stderr);
    if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "ls")) return runList(stdout);
    if (std.mem.eql(u8, subcmd, "edit")) return runEdit(sub_args, stderr);
    stderr.writeAll("Usage: xyron bookmarks [add|remove|list|edit]\n") catch {};
    return .{ .exit_code = 1 };
}

// ---------------------------------------------------------------------------
// CLI subcommands
// ---------------------------------------------------------------------------

fn runAdd(args: []const []const u8, stdout: std.fs.File, stderr: std.fs.File) Result {
    if (args.len < 2) {
        stderr.writeAll("Usage: xyron bookmarks add <name> <command> [--description \"...\"]\n") catch {};
        return .{ .exit_code = 1 };
    }
    const name = args[0];
    const command = args[1];
    if (!bookmarks.isValidName(name)) {
        stderr.writeAll("Invalid bookmark name (use letters, numbers, underscore, dash)\n") catch {};
        return .{ .exit_code = 1 };
    }
    if (bookmarks.nameConflicts(name)) {
        stderr.writeAll("Name conflicts with an existing command\n") catch {};
        return .{ .exit_code = 1 };
    }
    var desc: []const u8 = "";
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--description") and i + 1 < args.len) {
            i += 1;
            desc = args[i];
        }
    }
    if (!bookmarks.add(name, command, desc)) {
        stderr.writeAll("Failed to save bookmark\n") catch {};
        return .{ .exit_code = 1 };
    }
    stdout.writeAll("Bookmarked: ") catch {};
    stdout.writeAll(name) catch {};
    stdout.writeAll("\n") catch {};
    return .{};
}

fn runRemove(args: []const []const u8, stderr: std.fs.File) Result {
    if (args.len == 0) {
        stderr.writeAll("Usage: xyron bookmarks remove <name>\n") catch {};
        return .{ .exit_code = 1 };
    }
    if (!bookmarks.remove(args[0])) {
        stderr.writeAll("Bookmark not found\n") catch {};
        return .{ .exit_code = 1 };
    }
    return .{};
}

fn runList(stdout: std.fs.File) Result {
    var buf: [bookmarks.MAX_BOOKMARKS]bookmarks.Bookmark = undefined;
    const count = bookmarks.loadAll(&buf);
    if (count == 0) { stdout.writeAll("No bookmarks.\n") catch {}; return .{}; }
    for (buf[0..count]) |*b| {
        var line: [512]u8 = undefined;
        var pos: usize = 0;
        pos += style.cp(line[pos..], "  ");
        pos += style.boldText(line[pos..], b.nameSlice());
        pos += style.cp(line[pos..], "  ");
        pos += style.dimText(line[pos..], b.commandSlice());
        if (b.desc_len > 0) {
            pos += style.cp(line[pos..], "  ");
            pos += style.dimText(line[pos..], b.descSlice());
        }
        pos += style.cp(line[pos..], "\n");
        stdout.writeAll(line[0..pos]) catch {};
    }
    return .{};
}

fn runEdit(args: []const []const u8, stderr: std.fs.File) Result {
    if (args.len == 0) {
        stderr.writeAll("Usage: xyron bookmarks edit <name>\n") catch {};
        return .{ .exit_code = 1 };
    }
    const bm = bookmarks.findByName(args[0]) orelse {
        stderr.writeAll("Bookmark not found\n") catch {};
        return .{ .exit_code = 1 };
    };
    return editWithEditor(&bm, stderr);
}

fn editWithEditor(bm: *const bookmarks.Bookmark, stderr: std.fs.File) Result {
    const editor = std.posix.getenv("EDITOR") orelse std.posix.getenv("VISUAL") orelse "vi";

    // Write current command to a temp file
    var tmp_path: [std.fs.max_path_bytes]u8 = undefined;
    const tp = std.fmt.bufPrint(&tmp_path, "/tmp/xyron-bookmark-{d}.sh", .{std.c.getpid()}) catch return .{ .exit_code = 1 };

    const file = std.fs.cwd().createFile(tp, .{}) catch return .{ .exit_code = 1 };
    file.writeAll(bm.commandSlice()) catch {};
    file.close();
    defer std.fs.cwd().deleteFile(tp) catch {};

    // Run editor
    var child = std.process.Child.init(
        &.{ editor, tp },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch {
        stderr.writeAll("Failed to start editor\n") catch {};
        return .{ .exit_code = 1 };
    };
    const term = child.wait() catch return .{ .exit_code = 1 };
    const code = switch (term) { .Exited => |cc| cc, else => 1 };
    if (code != 0) return .{ .exit_code = 1 };

    // Read back
    const edited = std.fs.cwd().openFile(tp, .{}) catch return .{ .exit_code = 1 };
    defer edited.close();
    var read_buf: [1024]u8 = undefined;
    const n = edited.readAll(&read_buf) catch return .{ .exit_code = 1 };
    const new_cmd = std.mem.trimRight(u8, read_buf[0..n], "\n\r ");
    if (new_cmd.len == 0) return .{ .exit_code = 1 };

    if (!bookmarks.update(bm.id, new_cmd, bm.descSlice())) {
        stderr.writeAll("Failed to update bookmark\n") catch {};
        return .{ .exit_code = 1 };
    }
    return .{};
}

// ---------------------------------------------------------------------------
// TUI browser
// ---------------------------------------------------------------------------

fn runTui(_: std.fs.File, stderr: std.fs.File) Result {
    var all_bookmarks: [bookmarks.MAX_BOOKMARKS]bookmarks.Bookmark = undefined;
    var count = bookmarks.loadAll(&all_bookmarks);

    const tty_fd = posix.openZ("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return .{ .exit_code = 1 };
    defer posix.close(tty_fd);
    const tty = std.fs.File{ .handle = tty_fd };

    var orig: c.termios = undefined;
    _ = c.tcgetattr(tty_fd, &orig);
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    _ = c.tcsetattr(tty_fd, .NOW, &raw);
    defer _ = c.tcsetattr(tty_fd, .NOW, &orig);

    {
        var ebuf: [64]u8 = undefined;
        var ep: usize = 0;
        ep += style.altScreenOn(ebuf[ep..]);
        ep += style.showCursor(ebuf[ep..]);
        tty.writeAll(ebuf[0..ep]) catch {};
    }
    defer {
        var xbuf: [64]u8 = undefined;
        var xp: usize = 0;
        xp += style.showCursor(xbuf[xp..]);
        xp += style.altScreenOff(xbuf[xp..]);
        tty.writeAll(xbuf[0..xp]) catch {};
    }

    // Build text slices for fuzzy filter
    var name_texts: [bookmarks.MAX_BOOKMARKS][]const u8 = undefined;
    for (0..count) |i| name_texts[i] = all_bookmarks[i].nameSlice();

    var state = State{
        .bookmarks = &all_bookmarks,
        .name_texts = &name_texts,
        .count = count,
    };
    state.input.prompt = "> ";
    state.input.prompt_color = .yellow;
    state.input.focused = true;
    state.input.placeholder = "search...";
    state.rescore();

    var ts = getTermSize(tty_fd);
    var screen = Screen.init(
        @intCast(@min(ts.cols, Screen.max_cols)),
        @intCast(@min(ts.rows, Screen.max_rows)),
    );

    state.draw(&screen);
    screen.flush(tty);

    while (true) {
        const key = keys.readKeyFromFd(tty_fd) orelse break;

        if (key == .resize) {
            ts = getTermSize(tty_fd);
            screen.resize(@intCast(@min(ts.cols, Screen.max_cols)), @intCast(@min(ts.rows, Screen.max_rows)));
            state.draw(&screen);
            screen.flush(tty);
            continue;
        }

        switch (key) {
            .escape => break,
            .ctrl_c => {
                if (state.input.value().len > 0) {
                    state.input.clear();
                    state.rescore();
                } else break;
            },
            .up, .ctrl_p => {
                if (state.cursor > 0) state.cursor -= 1;
                state.clampScroll(&screen);
            },
            .down, .ctrl_n => {
                if (state.filter.count > 0 and state.cursor + 1 < state.filter.count)
                    state.cursor += 1;
                state.clampScroll(&screen);
            },
            .char => |ch| switch (ch) {
                'q' => break,
                'x' => {
                    if (state.filter.originalIndex(state.cursor)) |idx| {
                        _ = bookmarks.removeById(all_bookmarks[idx].id);
                        count = bookmarks.loadAll(&all_bookmarks);
                        state.count = count;
                        for (0..count) |i| name_texts[i] = all_bookmarks[i].nameSlice();
                        state.rescore();
                        if (state.cursor > 0 and state.cursor >= state.filter.count) state.cursor -= 1;
                    }
                },
                'e' => {
                    if (state.filter.originalIndex(state.cursor)) |idx| {
                        // Exit alt screen, run editor, re-enter
                        {
                            var xbuf: [64]u8 = undefined;
                            var xp: usize = 0;
                            xp += style.altScreenOff(xbuf[xp..]);
                            tty.writeAll(xbuf[0..xp]) catch {};
                        }
                        _ = c.tcsetattr(tty_fd, .NOW, &orig);
                        _ = editWithEditor(&all_bookmarks[idx], stderr);
                        _ = c.tcsetattr(tty_fd, .NOW, &raw);
                        {
                            var ebuf: [64]u8 = undefined;
                            var ep: usize = 0;
                            ep += style.altScreenOn(ebuf[ep..]);
                            tty.writeAll(ebuf[0..ep]) catch {};
                        }
                        // Reload
                        count = bookmarks.loadAll(&all_bookmarks);
                        state.count = count;
                        for (0..count) |i| name_texts[i] = all_bookmarks[i].nameSlice();
                        screen.resize(@intCast(@min(ts.cols, Screen.max_cols)), @intCast(@min(ts.rows, Screen.max_rows)));
                        state.rescore();
                    }
                },
                else => {
                    const action = state.input.handleKey(.{ .char = ch });
                    if (action == .changed) state.rescore();
                },
            },
            else => {
                const action = state.input.handleKey(key);
                if (action == .changed) state.rescore();
            },
        }

        screen.beginFrame();
        state.draw(&screen);
        screen.flush(tty);
    }

    return .{};
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const State = struct {
    bookmarks: *[bookmarks.MAX_BOOKMARKS]bookmarks.Bookmark,
    name_texts: *[bookmarks.MAX_BOOKMARKS][]const u8,
    count: usize,
    input: tui.Input = .{},
    filter: tui.FuzzyFilter(bookmarks.MAX_BOOKMARKS) = tui.FuzzyFilter(bookmarks.MAX_BOOKMARKS).init(),
    cursor: usize = 0,
    scroll: usize = 0,

    fn rescore(self: *State) void {
        const query = self.input.value();
        self.filter.reset();
        for (0..self.count) |i| {
            self.filter.push(query, self.name_texts[i], @intCast(i));
        }
        self.cursor = 0;
        self.scroll = 0;
    }

    fn clampScroll(self: *State, scr: *const Screen) void {
        const vis = if (scr.height > 4) scr.height - 4 else 1;
        if (self.cursor < self.scroll) self.scroll = self.cursor;
        if (self.cursor >= self.scroll + vis) self.scroll = self.cursor - vis + 1;
    }

    // Column widths
    const col_arrow: u16 = 3;
    const col_name: u16 = 16;
    const col_command: u16 = 40;

    fn draw(self: *const State, scr: *Screen) void {
        const scr_rect = tui.Rect.fromSize(scr.width, scr.height);
        var layout: [4]tui.Rect = undefined;
        _ = scr_rect.splitRows(&.{
            tui.Size{ .fixed = 1 },
            tui.Size{ .fixed = 1 },
            tui.Size{ .flex = 1 },
            tui.Size{ .fixed = 1 },
        }, &layout);

        self.drawTitle(scr, layout[0]);
        self.input.draw(scr, layout[1]);
        self.drawList(scr, layout[2]);
        self.drawStatusBar(scr, layout[3]);
    }

    fn drawTitle(self: *const State, scr: *Screen, rect: tui.Rect) void {
        const dim_s: Screen.Style = .{ .dim = true };
        var col = rect.x;
        col += scr.write(rect.y, col, "  Bookmarks", dim_s);
        var cnt_buf: [32]u8 = undefined;
        const cnt_str = std.fmt.bufPrint(&cnt_buf, "{d} saved  ", .{self.filter.count}) catch "";
        const cnt_w: u16 = @intCast(cnt_str.len);
        if (col + cnt_w < rect.x + rect.w) {
            scr.pad(rect.y, col, rect.x + rect.w - col - cnt_w, dim_s);
            _ = scr.write(rect.y, rect.x + rect.w - cnt_w, cnt_str, dim_s);
        } else {
            scr.pad(rect.y, col, rect.x + rect.w -| col, dim_s);
        }
    }

    fn drawList(self: *const State, scr: *Screen, rect: tui.Rect) void {
        if (rect.h == 0 or rect.w == 0) return;
        scr.hline(rect.y, rect.x, rect.w, .{ .dim = true });
        if (rect.h <= 1) return;

        const list_rect = tui.Rect{ .x = rect.x, .y = rect.y + 1, .w = rect.w, .h = rect.h - 1 };
        const max_vis = list_rect.h;
        const vis_end = @min(self.scroll + max_vis, self.filter.count);
        const has_scrollbar = self.filter.count > max_vis and max_vis > 2;
        const content_w: u16 = if (has_scrollbar) list_rect.w -| 1 else list_rect.w;

        if (self.filter.count == 0) {
            scr.fill(list_rect, .{});
            const msg = if (self.input.value().len > 0) "No matches" else "No bookmarks";
            const msg_w: u16 = @intCast(msg.len);
            const mid = list_rect.h / 2;
            _ = scr.write(list_rect.y + mid, list_rect.x + (list_rect.w -| msg_w) / 2, msg, .{ .dim = true });
        } else {
            const filtered = self.filter.results();
            var row: u16 = 0;
            for (self.scroll..vis_end) |vi| {
                const bm = &self.bookmarks[filtered[vi].index];
                const is_sel = vi == self.cursor;
                const y = list_rect.y + row;
                var col = list_rect.x;

                // Arrow
                if (is_sel) {
                    col += scr.write(y, col, " > ", .{ .fg = .cyan });
                } else {
                    scr.pad(y, col, col_arrow, .{});
                    col += col_arrow;
                }

                // Name
                const name = bm.nameSlice();
                const nw: u16 = @intCast(@min(name.len, col_name));
                const name_style: Screen.Style = if (is_sel) .{ .bold = true, .fg = .cyan } else .{ .fg = .cyan };
                _ = scr.write(y, col, name[0..nw], name_style);
                scr.pad(y, col + nw, col_name -| nw, .{});
                col += col_name;

                // Command
                const cmd = bm.commandSlice();
                const snippet = bm.isSnippet();
                const cmd_style: Screen.Style = if (is_sel) .{ .bold = true } else .{};
                const cw: u16 = @intCast(@min(cmd.len, col_command));
                _ = scr.write(y, col, cmd[0..cw], cmd_style);
                var used = cw;
                if (cmd.len > col_command) { used += scr.write(y, col + used, style.box.ellipsis, cmd_style); }
                if (snippet) { used += scr.write(y, col + used, " ", .{}); used += scr.write(y, col + used, "snippet", .{ .fg = .yellow, .dim = true }); }
                scr.pad(y, col + used, col_command + 10 -| used, .{});
                col += col_command + 10;

                // Description
                const desc = bm.descSlice();
                const remaining = content_w -| (col - list_rect.x);
                if (desc.len > 0 and remaining > 0) {
                    const dw: u16 = @intCast(@min(desc.len, remaining));
                    _ = scr.write(y, col, desc[0..dw], .{ .dim = true });
                    scr.pad(y, col + dw, remaining -| dw, .{});
                } else {
                    scr.pad(y, col, remaining, .{});
                }

                row += 1;
            }
            while (row < max_vis) : (row += 1) {
                scr.pad(list_rect.y + row, list_rect.x, content_w, .{});
            }
        }

        if (has_scrollbar) {
            const col = list_rect.x + list_rect.w - 1;
            const thumb_h = @max(1, (@as(u32, max_vis) * max_vis) / @as(u32, @intCast(self.filter.count)));
            const max_off = self.filter.count - max_vis;
            const track_space = max_vis - @as(u16, @intCast(thumb_h));
            const thumb_top: u16 = if (max_off > 0)
                @intCast((@as(u32, @intCast(self.scroll)) * track_space) / @as(u32, @intCast(max_off)))
            else
                0;
            var sr: u16 = 0;
            while (sr < max_vis) : (sr += 1) {
                const ch = if (sr >= thumb_top and sr < thumb_top + @as(u16, @intCast(thumb_h)))
                    style.box.scrollbar_thumb
                else
                    style.box.scrollbar_track;
                _ = scr.write(list_rect.y + sr, col, ch, .{ .dim = true });
            }
        }
    }

    fn drawStatusBar(_: *const State, scr: *Screen, rect: tui.Rect) void {
        const bar = tui.StatusBar{
            .items = &.{
                .{ .key = "Esc", .label = "close" },
                .{ .key = "e", .label = "edit" },
                .{ .key = "x", .label = "delete" },
            },
            .transparent = true,
        };
        bar.draw(scr, rect);
    }
};

const TermSize = struct { rows: usize, cols: usize };
fn getTermSize(fd: posix.fd_t) TermSize {
    const ts = style.getTermSize(fd);
    return .{ .rows = ts.rows, .cols = ts.cols };
}
