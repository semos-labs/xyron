// builtins/secrets_open.zig — Secrets TUI browser.
//
// Full-screen alternate-screen browser for encrypted secrets.
// Supports search, add/edit modals, show/hide values, delete.
// Uses TUI component library for layout, input, and status bar.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const secrets_mod = @import("../secrets.zig");
const style = @import("../style.zig");
const tui = @import("../tui.zig");
const keys = @import("../keys.zig");
const Result = @import("mod.zig").BuiltinResult;

const Key = keys.Key;

pub fn run(args: []const []const u8, _: std.fs.File, stderr: std.fs.File) Result {
    var store = secrets_mod.SecretsStore.init();
    if (!store.isInitialized()) { stderr.writeAll("Run `xyron secrets init` first.\n") catch {}; return .{ .exit_code = 1 }; }
    store.load() catch { stderr.writeAll("Failed to decrypt secrets.\n") catch {}; return .{ .exit_code = 1 }; };

    var local_only = false;
    for (args) |a| { if (std.mem.eql(u8, a, "--local")) local_only = true; }

    const tty_fd = posix.openZ("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return .{ .exit_code = 1 };
    defer posix.close(tty_fd);
    const tty = std.fs.File{ .handle = tty_fd };

    // Raw mode
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

    // Alternate screen
    {
        var enter_buf: [64]u8 = undefined;
        var ep: usize = 0;
        ep += style.altScreenOn(enter_buf[ep..]);
        ep += style.showCursor(enter_buf[ep..]);
        tty.writeAll(enter_buf[0..ep]) catch {};
    }
    defer {
        var exit_buf: [64]u8 = undefined;
        var xp: usize = 0;
        xp += style.showCursor(exit_buf[xp..]);
        xp += style.altScreenOff(exit_buf[xp..]);
        tty.writeAll(exit_buf[0..xp]) catch {};
    }

    // State
    var state = State{
        .store = &store,
        .local_only = local_only,
    };
    state.cwd = posix.getcwd(&state.cwd_buf) catch ".";
    state.ts = getTermSize(tty_fd);
    state.search_input.prompt = "/ ";
    state.search_input.prompt_color = .yellow;

    state.render(tty);

    // Event loop
    while (true) {
        const key = keys.readKeyFromFd(tty_fd) orelse break;

        if (key == .resize) {
            state.ts = getTermSize(tty_fd);
            state.render(tty);
            continue;
        }

        if (state.searching) {
            state.handleSearchKey(key);
        } else {
            const done = state.handleNormalKey(key, tty, tty_fd);
            if (done) break;
        }

        state.render(tty);
    }

    if (store.modified) store.save() catch {};
    return .{};
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const State = struct {
    store: *secrets_mod.SecretsStore,
    local_only: bool,
    cursor: usize = 0,
    scroll: usize = 0,
    show_values: bool = false,
    searching: bool = false,
    search_input: tui.Input = .{},
    ts: TermSize = .{ .rows = 24, .cols = 80 },
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd: []const u8 = ".",

    fn filteredCount(self: *const State) usize {
        const filter = self.search_input.value();
        var n: usize = 0;
        for (0..self.store.count) |i| {
            const sec = &self.store.secrets[i];
            if (self.local_only and (sec.kind != .local or !std.mem.eql(u8, sec.dirSlice(), self.cwd))) continue;
            if (!matchesFilter(sec, filter)) continue;
            n += 1;
        }
        return n;
    }

    fn resolveIndex(self: *const State, visual_idx: usize) ?usize {
        const filter = self.search_input.value();
        var n: usize = 0;
        for (0..self.store.count) |i| {
            const sec = &self.store.secrets[i];
            if (self.local_only and (sec.kind != .local or !std.mem.eql(u8, sec.dirSlice(), self.cwd))) continue;
            if (!matchesFilter(sec, filter)) continue;
            if (n == visual_idx) return i;
            n += 1;
        }
        return null;
    }

    fn visibleRows(self: *const State) usize {
        // title + optional search + separator = 2-3 header rows, status = 1
        const header: usize = if (self.searching or self.search_input.value().len > 0) 3 else 2;
        return if (self.ts.rows > header + 1) self.ts.rows - header - 1 else 1;
    }

    fn clampScroll(self: *State) void {
        const vis = self.visibleRows();
        if (self.cursor < self.scroll) self.scroll = self.cursor;
        if (self.cursor >= self.scroll + vis) self.scroll = self.cursor - vis + 1;
    }

    // -------------------------------------------------------------------
    // Key handling
    // -------------------------------------------------------------------

    fn handleSearchKey(self: *State, key: Key) void {
        switch (key) {
            .escape => {
                self.searching = false;
                self.search_input.clear();
                self.cursor = 0;
                self.scroll = 0;
            },
            .enter => {
                self.searching = false;
            },
            .ctrl_c => {
                self.searching = false;
                self.search_input.clear();
            },
            else => {
                const action = self.search_input.handleKey(key);
                if (action == .changed) {
                    self.cursor = 0;
                    self.scroll = 0;
                }
            },
        }
    }

    fn handleNormalKey(self: *State, key: Key, tty: std.fs.File, tty_fd: posix.fd_t) bool {
        const total = self.filteredCount();
        switch (key) {
            .up, .ctrl_p => {
                if (self.cursor > 0) self.cursor -= 1;
                self.clampScroll();
            },
            .down, .ctrl_n => {
                if (total > 0 and self.cursor + 1 < total) self.cursor += 1;
                self.clampScroll();
            },
            .escape, .ctrl_c => return true,
            .char => |ch| switch (ch) {
                'q' => return true,
                '/' => { self.searching = true; self.search_input.focused = true; },
                'v' => self.show_values = !self.show_values,
                'a' => {
                    const kind: secrets_mod.SecretKind = if (self.local_only) .local else .env;
                    const dir = if (self.local_only) self.cwd else "";
                    if (addSecretModal(tty, tty_fd, self.store, kind, dir, self.ts)) {
                        self.store.save() catch {};
                    }
                },
                'e' => {
                    if (self.resolveIndex(self.cursor)) |real_idx| {
                        if (editSecretModal(tty, tty_fd, self.store, real_idx, self.ts)) {
                            self.store.save() catch {};
                        }
                    }
                },
                'x' => {
                    if (self.resolveIndex(self.cursor)) |real_idx| {
                        self.store.remove(real_idx);
                        const new_total = self.filteredCount();
                        if (self.cursor > 0 and self.cursor >= new_total) self.cursor -= 1;
                        self.store.save() catch {};
                    }
                },
                else => {},
            },
            else => {},
        }
        return false;
    }

    // -------------------------------------------------------------------
    // Rendering
    // -------------------------------------------------------------------

    fn render(self: *const State, tty: std.fs.File) void {
        var buf: [32768]u8 = undefined;
        var pos: usize = 0;
        const cols: u16 = @intCast(@min(self.ts.cols, 1000));
        const rows: u16 = @intCast(@min(self.ts.rows, 500));
        const filter = self.search_input.value();
        const total = self.filteredCount();
        const show_search = self.searching or filter.len > 0;

        pos += style.hideCursor(buf[pos..]);
        pos += style.home(buf[pos..]);

        // Layout
        const screen = tui.Rect.fromSize(cols, rows);
        const header_rows: u32 = if (show_search) 3 else 2; // title + [search] + separator
        var layout: [4]tui.Rect = undefined;
        if (show_search) {
            _ = screen.splitRows(&.{
                tui.Size{ .fixed = 1 }, // title
                tui.Size{ .fixed = 1 }, // search
                tui.Size{ .flex = 1 },  // list
                tui.Size{ .fixed = 1 }, // status
            }, &layout);
        } else {
            _ = screen.splitRows(&.{
                tui.Size{ .fixed = 1 },  // title
                tui.Size{ .flex = 1 },   // list (separator takes first row)
                tui.Size{ .fixed = 1 },  // status
            }, layout[0..3]);
            // Shift: title=0, list=1 (with separator), status=2
            layout[3] = layout[2]; // status
            layout[2] = layout[1]; // list
        }
        _ = header_rows;

        // Title bar
        pos += self.renderTitle(buf[pos..], layout[0], total);

        // Search bar
        if (show_search) {
            pos += self.search_input.render(buf[pos..], layout[1]);
        }

        // Separator + list area
        const list_area = if (show_search) layout[2] else layout[2];
        pos += self.renderSeparatorAndList(buf[pos..], list_area, total);

        // Status bar
        const status_rect = if (show_search) layout[3] else layout[3];
        pos += self.renderStatusBar(buf[pos..], status_rect);

        // Cursor for search
        if (self.searching) {
            const search_rect = layout[1];
            pos += style.showCursor(buf[pos..]);
            // The Input component positions the cursor at the end of render,
            // but we rendered other things after. Re-position it.
            const prompt_w: u16 = @intCast(@min(self.search_input.prompt.len, cols));
            const cursor_col = search_rect.x + prompt_w + @as(u16, @intCast(self.search_input.cursor));
            pos += style.moveTo(buf[pos..], search_rect.y, cursor_col);
        }

        tty.writeAll(buf[0..pos]) catch {};
    }

    fn renderTitle(self: *const State, buf: []u8, rect: tui.Rect, total: usize) usize {
        var pos: usize = 0;
        pos += style.moveTo(buf[pos..], rect.y, rect.x);
        pos += style.dim(buf[pos..]);

        const title = if (self.local_only) "  Secrets (local)" else "  Secrets";
        pos += tui.clipText(buf[pos..], title, rect.w);
        const vis: u16 = @intCast(@min(title.len, rect.w));

        // Right-aligned count
        var cnt_buf: [32]u8 = undefined;
        const cnt_str = std.fmt.bufPrint(&cnt_buf, "{d} entries  ", .{total}) catch "";
        const cnt_w: u16 = @intCast(cnt_str.len);
        if (vis + cnt_w < rect.w) {
            pos += tui.pad(buf[pos..], rect.w - vis - cnt_w);
            pos += tui.clipText(buf[pos..], cnt_str, cnt_w);
        } else {
            pos += tui.pad(buf[pos..], rect.w -| vis);
        }

        pos += style.reset(buf[pos..]);
        return pos;
    }

    fn renderSeparatorAndList(self: *const State, buf: []u8, rect: tui.Rect, total: usize) usize {
        if (rect.h == 0 or rect.w == 0) return 0;
        var pos: usize = 0;

        // Separator (first row of area)
        pos += style.moveTo(buf[pos..], rect.y, rect.x);
        pos += style.dim(buf[pos..]);
        pos += style.hline(buf[pos..], rect.w);
        pos += style.reset(buf[pos..]);

        if (rect.h <= 1) return pos;

        // List area below separator
        const list_rect = tui.Rect{
            .x = rect.x,
            .y = rect.y + 1,
            .w = rect.w,
            .h = rect.h - 1,
        };

        const max_vis = list_rect.h;
        const vis_end = @min(self.scroll + max_vis, total);
        const has_scrollbar = total > max_vis and max_vis > 2;
        const content_w: u16 = if (has_scrollbar) list_rect.w -| 1 else list_rect.w;

        if (total == 0) {
            pos += self.renderEmpty(buf[pos..], list_rect);
        } else {
            pos += self.renderEntries(buf[pos..], list_rect, content_w, vis_end);
        }

        // Pad remaining rows
        const rendered = if (total > 0) vis_end - self.scroll else 0;
        var row: u16 = @intCast(rendered);
        // Account for detail lines
        if (total > 0 and self.cursor >= self.scroll and self.cursor < vis_end) row += 1;
        while (row < max_vis) : (row += 1) {
            pos += style.moveTo(buf[pos..], list_rect.y + row, list_rect.x);
            pos += tui.pad(buf[pos..], content_w);
        }

        // Scrollbar
        if (has_scrollbar) {
            pos += tui.renderScrollbar(buf[pos..], list_rect.y, list_rect.x + list_rect.w - 1, max_vis, total, self.scroll);
        }

        return pos;
    }

    fn renderEntries(self: *const State, buf: []u8, list_rect: tui.Rect, content_w: u16, vis_end: usize) usize {
        var pos: usize = 0;
        const filter = self.search_input.value();
        var vi: usize = 0;
        var row: u16 = 0;

        for (0..self.store.count) |i| {
            const sec = &self.store.secrets[i];
            if (self.local_only and (sec.kind != .local or !std.mem.eql(u8, sec.dirSlice(), self.cwd))) continue;
            if (!matchesFilter(sec, filter)) continue;
            if (vi < self.scroll) { vi += 1; continue; }
            if (vi >= vis_end) break;

            const is_sel = vi == self.cursor;
            pos += style.moveTo(buf[pos..], list_rect.y + row, list_rect.x);

            // Arrow
            if (is_sel) {
                pos += style.colored(buf[pos..], .cyan, " > ");
            } else {
                pos += style.cp(buf[pos..], "   ");
            }

            // Kind badge
            switch (sec.kind) {
                .env => pos += style.colored(buf[pos..], .green, style.box.bullet),
                .local => pos += style.colored(buf[pos..], .blue, style.box.bullet),
                .password => pos += style.colored(buf[pos..], .yellow, style.box.bullet),
            }
            pos += style.cp(buf[pos..], " ");

            // Name
            const name = sec.nameSlice();
            const max_name: u16 = 24;
            const name_w: u16 = @intCast(@min(name.len, max_name));
            if (is_sel) pos += style.bold(buf[pos..]);
            pos += tui.clipText(buf[pos..], name, name_w);
            pos += style.reset(buf[pos..]);

            var vis: u16 = 5 + name_w; // "   " + bullet + " " + name

            // Value
            const val = sec.valueSlice();
            if (val.len > 0) {
                pos += style.cp(buf[pos..], "  ");
                vis += 2;
                if (self.show_values) {
                    pos += style.dim(buf[pos..]);
                    const max_val: u16 = if (content_w > vis + 20) content_w - vis - 16 else 16;
                    const val_w: u16 = @intCast(@min(val.len, max_val));
                    pos += tui.clipText(buf[pos..], val, val_w);
                    if (val.len > max_val) pos += style.cp(buf[pos..], style.box.ellipsis);
                    vis += val_w;
                    pos += style.reset(buf[pos..]);
                } else {
                    pos += style.dimText(buf[pos..], "\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2");
                    vis += 8;
                }
            }

            // Description (right-aligned)
            const desc = sec.descSlice();
            if (desc.len > 0 and vis + desc.len + 2 < content_w) {
                const gap = content_w - vis - @as(u16, @intCast(desc.len));
                pos += tui.pad(buf[pos..], gap);
                pos += style.dimText(buf[pos..], desc);
                vis = content_w;
            }
            pos += tui.pad(buf[pos..], content_w -| vis);

            row += 1;

            // Detail line for selected
            if (is_sel and row < list_rect.h) {
                pos += style.moveTo(buf[pos..], list_rect.y + row, list_rect.x);
                pos += style.cp(buf[pos..], "     ");
                pos += style.dim(buf[pos..]);
                switch (sec.kind) {
                    .env => pos += style.cp(buf[pos..], "env"),
                    .local => {
                        pos += style.cp(buf[pos..], "local ");
                        pos += style.fg(buf[pos..], .cyan);
                        const dir = sec.dirSlice();
                        const dir_max: u16 = if (content_w > 20) content_w - 20 else content_w;
                        pos += tui.clipText(buf[pos..], dir, dir_max);
                    },
                    .password => pos += style.cp(buf[pos..], "password"),
                }
                pos += style.reset(buf[pos..]);
                pos += tui.pad(buf[pos..], content_w -| 15);
                row += 1;
            }

            vi += 1;
        }
        return pos;
    }

    fn renderEmpty(self: *const State, buf: []u8, rect: tui.Rect) usize {
        _ = self;
        var pos: usize = 0;
        // Clear rows and center message
        const msg = "No secrets stored";
        const hint = "Press  a  to add your first secret";
        const mid = rect.h / 2;

        var row: u16 = 0;
        while (row < rect.h) : (row += 1) {
            pos += style.moveTo(buf[pos..], rect.y + row, rect.x);
            if (row == mid) {
                const pad_l = (rect.w -| @as(u16, @intCast(msg.len))) / 2;
                pos += tui.pad(buf[pos..], pad_l);
                pos += style.dimText(buf[pos..], msg);
                pos += tui.pad(buf[pos..], rect.w -| pad_l -| @as(u16, @intCast(msg.len)));
            } else if (row == mid + 2) {
                const pad_l = (rect.w -| @as(u16, @intCast(hint.len))) / 2;
                pos += tui.pad(buf[pos..], pad_l);
                pos += style.dim(buf[pos..]);
                pos += style.cp(buf[pos..], "Press ");
                pos += style.reset(buf[pos..]);
                pos += style.boldColored(buf[pos..], .cyan, "a");
                pos += style.dim(buf[pos..]);
                pos += style.cp(buf[pos..], " to add your first secret");
                pos += style.reset(buf[pos..]);
                pos += tui.pad(buf[pos..], rect.w -| pad_l -| @as(u16, @intCast(hint.len)));
            } else {
                pos += tui.pad(buf[pos..], rect.w);
            }
        }
        return pos;
    }

    fn renderStatusBar(self: *const State, buf: []u8, rect: tui.Rect) usize {
        const items_show = [_]tui.StatusBar.Item{
            .{ .key = "q", .label = "quit" },
            .{ .key = "/", .label = "search" },
            .{ .key = "a", .label = "add" },
            .{ .key = "e", .label = "edit" },
            .{ .key = "v", .label = "hide" },
            .{ .key = "x", .label = "delete" },
        };
        const items_hide = [_]tui.StatusBar.Item{
            .{ .key = "q", .label = "quit" },
            .{ .key = "/", .label = "search" },
            .{ .key = "a", .label = "add" },
            .{ .key = "e", .label = "edit" },
            .{ .key = "v", .label = "show" },
            .{ .key = "x", .label = "delete" },
        };
        const bar = tui.StatusBar{
            .items = if (self.show_values) &items_show else &items_hide,
        };
        return bar.render(buf, rect);
    }
};

// ---------------------------------------------------------------------------
// Add / Edit modals
// ---------------------------------------------------------------------------

const FieldIdx = enum(u2) { name = 0, value = 1, desc = 2 };

fn addSecretModal(tty: std.fs.File, tty_fd: posix.fd_t, store: *secrets_mod.SecretsStore, kind: secrets_mod.SecretKind, dir: []const u8, ts: TermSize) bool {
    var fields: [3]tui.Input = .{ .{}, .{}, .{} };
    const labels = [3][]const u8{ "Name", "Value", "Description" };
    const placeholders = [3][]const u8{ "SECRET_NAME", "secret value", "optional description" };
    for (&fields, placeholders) |*f, ph| { f.placeholder = ph; }
    var active: FieldIdx = .name;
    fields[@intFromEnum(active)].focused = true;

    while (true) {
        renderModal(tty, "Add Secret", &labels, &fields, active, ts);
        const key = keys.readKeyFromFd(tty_fd) orelse return false;
        switch (key) {
            .up => {
                fields[@intFromEnum(active)].focused = false;
                active = if (@intFromEnum(active) > 0) @enumFromInt(@intFromEnum(active) - 1) else active;
                fields[@intFromEnum(active)].focused = true;
            },
            .down, .tab => {
                fields[@intFromEnum(active)].focused = false;
                active = if (@intFromEnum(active) < 2) @enumFromInt(@intFromEnum(active) + 1) else .name;
                fields[@intFromEnum(active)].focused = true;
            },
            .enter => {
                if (fields[0].value().len == 0) continue;
                return store.add(fields[0].value(), fields[1].value(), fields[2].value(), dir, kind);
            },
            .escape, .ctrl_c => return false,
            else => {
                _ = fields[@intFromEnum(active)].handleKey(key);
            },
        }
    }
}

fn editSecretModal(tty: std.fs.File, tty_fd: posix.fd_t, store: *secrets_mod.SecretsStore, idx: usize, ts: TermSize) bool {
    if (idx >= store.count) return false;
    const sec = &store.secrets[idx];

    var fields: [3]tui.Input = .{ .{}, .{}, .{} };
    const labels = [3][]const u8{ "Name", "Value", "Description" };
    fields[0].setValue(sec.nameSlice());
    fields[1].setValue(sec.valueSlice());
    fields[2].setValue(sec.descSlice());

    var active: FieldIdx = .value;
    fields[@intFromEnum(active)].focused = true;

    while (true) {
        renderModal(tty, "Edit Secret", &labels, &fields, active, ts);
        const key = keys.readKeyFromFd(tty_fd) orelse return false;
        switch (key) {
            .up => {
                fields[@intFromEnum(active)].focused = false;
                active = if (@intFromEnum(active) > 0) @enumFromInt(@intFromEnum(active) - 1) else active;
                fields[@intFromEnum(active)].focused = true;
            },
            .down, .tab => {
                fields[@intFromEnum(active)].focused = false;
                active = if (@intFromEnum(active) < 2) @enumFromInt(@intFromEnum(active) + 1) else .name;
                fields[@intFromEnum(active)].focused = true;
            },
            .enter => {
                if (fields[0].value().len == 0) continue;
                secrets_mod.SecretsStore.setFieldPub(&sec.name, &sec.name_len, fields[0].value());
                secrets_mod.SecretsStore.setFieldPub(&sec.value, &sec.value_len, fields[1].value());
                secrets_mod.SecretsStore.setFieldPub(&sec.description, &sec.desc_len, fields[2].value());
                store.modified = true;
                return true;
            },
            .escape, .ctrl_c => return false,
            else => {
                _ = fields[@intFromEnum(active)].handleKey(key);
            },
        }
    }
}

fn renderModal(tty: std.fs.File, title: []const u8, labels: *const [3][]const u8, fields: *const [3]tui.Input, active: FieldIdx, ts: TermSize) void {
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;
    const cols: u16 = @intCast(@min(ts.cols, 1000));
    const rows: u16 = @intCast(@min(ts.rows, 500));
    const screen = tui.Rect.fromSize(cols, rows);

    // Popup frame
    const popup = tui.Popup{
        .title = title,
        .width = .{ .fixed = @min(56, cols -| 4) },
        .height = .{ .fixed = 9 },
        .border_color = .bright_black,
        .title_color = .white,
    };
    pos += popup.render(buf[pos..], screen);

    // Content inside popup
    const content = popup.contentRect(screen);
    if (content.w < 4 or content.h < 5) {
        tty.writeAll(buf[0..pos]) catch {};
        return;
    }

    // Find longest label
    var max_label: u16 = 0;
    for (labels) |l| max_label = @max(max_label, @as(u16, @intCast(l.len)));

    // Field rows (with 1 row gap at top)
    var cursor_row: u16 = 0;
    var cursor_col: u16 = 0;

    for (0..3) |fi| {
        const field_y = content.y + 1 + @as(u16, @intCast(fi));
        const is_active = @intFromEnum(active) == fi;
        const label = labels[fi];

        pos += style.moveTo(buf[pos..], field_y, content.x);

        // Label (right-aligned within max_label width)
        const lpad = max_label - @as(u16, @intCast(label.len));
        pos += tui.pad(buf[pos..], lpad);
        if (is_active) {
            pos += style.fg(buf[pos..], .cyan);
        } else {
            pos += style.fg(buf[pos..], .white);
        }
        pos += tui.clipText(buf[pos..], label, @intCast(label.len));
        pos += style.reset(buf[pos..]);
        pos += style.cp(buf[pos..], "  ");

        // Input field
        const field_x = content.x + max_label + 2;
        const field_w = content.w -| max_label -| 2;
        const field_rect = tui.Rect{
            .x = field_x,
            .y = field_y,
            .w = field_w,
            .h = 1,
        };
        pos += fields[fi].render(buf[pos..], field_rect);

        if (is_active) {
            cursor_row = field_y;
            cursor_col = field_x + @as(u16, @intCast(fields[fi].cursor));
        }
    }

    // Help row
    const help_y = content.y + content.h - 1;
    const help_bar = tui.StatusBar{
        .items = &.{
            .{ .key = "Tab", .label = "next" },
            .{ .key = "Enter", .label = "save" },
            .{ .key = "Esc", .label = "cancel" },
        },
    };
    pos += help_bar.render(buf[pos..], tui.Rect{
        .x = content.x,
        .y = help_y,
        .w = content.w,
        .h = 1,
    });

    // Position cursor at active field
    if (cursor_row > 0) {
        pos += style.showCursor(buf[pos..]);
        pos += style.moveTo(buf[pos..], cursor_row, cursor_col);
    }

    tty.writeAll(buf[0..pos]) catch {};
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn matchesFilter(sec: *const secrets_mod.Secret, filter_str: []const u8) bool {
    if (filter_str.len == 0) return true;
    return findCaseInsensitive(sec.nameSlice(), filter_str) != null or
        findCaseInsensitive(sec.descSlice(), filter_str) != null;
}

fn findCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    const limit = haystack.len - needle.len + 1;
    for (0..limit) |i| {
        var matched = true;
        for (0..needle.len) |j| {
            const a = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z') haystack[i + j] + 32 else haystack[i + j];
            const b = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (a != b) { matched = false; break; }
        }
        if (matched) return i;
    }
    return null;
}

const TermSize = struct { rows: usize, cols: usize };

fn getTermSize(fd: posix.fd_t) TermSize {
    const ts = style.getTermSize(fd);
    return .{ .rows = ts.rows, .cols = ts.cols };
}
