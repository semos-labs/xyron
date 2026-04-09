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
const Screen = tui.Screen;

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

    // Double-buffered screen
    var screen = Screen.init(
        @intCast(@min(state.ts.cols, Screen.max_cols)),
        @intCast(@min(state.ts.rows, Screen.max_rows)),
    );

    state.rescore();
    state.draw(&screen);
    screen.flush(tty);

    // Event loop
    while (true) {
        const key = keys.readKeyFromFd(tty_fd) orelse break;

        if (key == .resize) {
            state.ts = getTermSize(tty_fd);
            screen.resize(
                @intCast(@min(state.ts.cols, Screen.max_cols)),
                @intCast(@min(state.ts.rows, Screen.max_rows)),
            );
            state.draw(&screen);
            screen.flush(tty);
            continue;
        }

        if (state.searching) {
            state.handleSearchKey(key);
        } else {
            const done = state.handleNormalKey(key, tty, tty_fd, &screen);
            if (done) break;
        }

        screen.beginFrame();
        state.draw(&screen);
        screen.flush(tty);
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
    filter: tui.FuzzyFilter(secrets_mod.MAX_SECRETS) = tui.FuzzyFilter(secrets_mod.MAX_SECRETS).init(),
    ts: TermSize = .{ .rows = 24, .cols = 80 },
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd: []const u8 = ".",

    fn rescore(self: *State) void {
        const query = self.search_input.value();
        self.filter.reset();
        for (0..self.store.count) |i| {
            const sec = &self.store.secrets[i];
            if (self.local_only and (sec.kind != .local or !std.mem.eql(u8, sec.dirSlice(), self.cwd))) continue;
            self.filter.push(query, sec.nameSlice(), @intCast(i));
        }
        self.cursor = 0;
        self.scroll = 0;
    }

    fn resolveIndex(self: *const State, visual_idx: usize) ?usize {
        return self.filter.originalIndex(visual_idx);
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
                self.rescore();
            },
            .enter => {
                self.searching = false;
            },
            .ctrl_c => {
                self.searching = false;
                self.search_input.clear();
                self.rescore();
            },
            else => {
                const action = self.search_input.handleKey(key);
                if (action == .changed) self.rescore();
            },
        }
    }

    fn handleNormalKey(self: *State, key: Key, tty: std.fs.File, tty_fd: posix.fd_t, screen: *Screen) bool {
        const total = self.filter.count;
        switch (key) {
            .up, .ctrl_p => {
                if (self.cursor > 0) self.cursor -= 1;
                self.clampScroll();
            },
            .down, .ctrl_n => {
                if (total > 0 and self.cursor + 1 < total) self.cursor += 1;
                self.clampScroll();
            },
            .escape => return true,
            .ctrl_c => {
                if (self.search_input.value().len > 0) {
                    self.search_input.clear();
                    self.rescore();
                } else return true;
            },
            .char => |ch| switch (ch) {
                'q' => return true,
                '/' => { self.searching = true; self.search_input.focused = true; },
                'v' => self.show_values = !self.show_values,
                'a' => {
                    const kind: secrets_mod.SecretKind = if (self.local_only) .local else .env;
                    const dir = if (self.local_only) self.cwd else "";
                    if (addSecretModal(tty, tty_fd, self.store, kind, dir, self.ts, screen)) {
                        self.store.save() catch {};
                        self.rescore();
                    }
                },
                'e' => {
                    if (self.resolveIndex(self.cursor)) |real_idx| {
                        if (editSecretModal(tty, tty_fd, self.store, real_idx, self.ts, screen)) {
                            self.store.save() catch {};
                            self.rescore();
                        }
                    }
                },
                'x' => {
                    if (self.resolveIndex(self.cursor)) |real_idx| {
                        self.store.remove(real_idx);
                        self.store.save() catch {};
                        self.rescore();
                        if (self.cursor > 0 and self.cursor >= self.filter.count) self.cursor -= 1;
                    }
                },
                else => {},
            },
            else => {},
        }
        return false;
    }

    // -------------------------------------------------------------------
    // Drawing (Screen-based, double-buffered)
    // -------------------------------------------------------------------

    fn draw(self: *const State, scr: *Screen) void {
        const cols = scr.width;
        const rows = scr.height;
        const filter = self.search_input.value();
        const total = self.filter.count;
        const show_search = self.searching or filter.len > 0;

        // Layout
        const scr_rect = tui.Rect.fromSize(cols, rows);
        var layout: [4]tui.Rect = undefined;
        if (show_search) {
            _ = scr_rect.splitRows(&.{
                tui.Size{ .fixed = 1 }, // title
                tui.Size{ .fixed = 1 }, // search
                tui.Size{ .flex = 1 },  // list
                tui.Size{ .fixed = 1 }, // status
            }, &layout);
        } else {
            _ = scr_rect.splitRows(&.{
                tui.Size{ .fixed = 1 },  // title
                tui.Size{ .flex = 1 },   // list
                tui.Size{ .fixed = 1 },  // status
            }, layout[0..3]);
            layout[3] = layout[2]; // status
            layout[2] = layout[1]; // list
        }

        // Title bar
        self.drawTitle(scr, layout[0], total);

        // Search bar
        if (show_search) {
            self.search_input.draw(scr, layout[1]);
        }

        // Separator + list
        self.drawSeparatorAndList(scr, layout[2], total);

        // Status bar
        self.drawStatusBar(scr, if (show_search) layout[3] else layout[3]);
    }

    fn drawTitle(self: *const State, scr: *Screen, rect: tui.Rect, total: usize) void {
        const title = if (self.local_only) "  Secrets (local)" else "  Secrets";
        const dim_style: Screen.Style = .{ .dim = true };
        var col = rect.x;
        col += scr.write(rect.y, col, title, dim_style);

        // Right-aligned count
        var cnt_buf: [32]u8 = undefined;
        const cnt_str = std.fmt.bufPrint(&cnt_buf, "{d} entries  ", .{total}) catch "";
        const cnt_w: u16 = @intCast(cnt_str.len);
        if (col + cnt_w < rect.x + rect.w) {
            scr.pad(rect.y, col, rect.x + rect.w - col - cnt_w, dim_style);
            _ = scr.write(rect.y, rect.x + rect.w - cnt_w, cnt_str, dim_style);
        } else {
            scr.pad(rect.y, col, rect.x + rect.w -| col, dim_style);
        }
    }

    fn drawSeparatorAndList(self: *const State, scr: *Screen, rect: tui.Rect, total: usize) void {
        if (rect.h == 0 or rect.w == 0) return;

        // Separator
        scr.hline(rect.y, rect.x, rect.w, .{ .dim = true });

        if (rect.h <= 1) return;

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
            self.drawEmpty(scr, list_rect);
        } else {
            self.drawEntries(scr, list_rect, content_w, vis_end);
        }

        // Scrollbar
        if (has_scrollbar) {
            self.drawScrollbar(scr, list_rect, max_vis, total);
        }
    }

    fn drawEntries(self: *const State, scr: *Screen, list_rect: tui.Rect, content_w: u16, vis_end: usize) void {
        var row: u16 = 0;
        const filtered = self.filter.results();

        for (self.scroll..vis_end) |vi| {
            const sec = &self.store.secrets[filtered[vi].index];
            const is_sel = vi == self.cursor;
            var col = list_rect.x;

            // Arrow
            if (is_sel) {
                col += scr.write(list_rect.y + row, col, " > ", .{ .fg = .cyan });
            } else {
                scr.pad(list_rect.y + row, col, 3, .{});
                col += 3;
            }

            // Kind badge
            const badge_color: style.Color = switch (sec.kind) {
                .env => .green,
                .local => .blue,
                .password => .yellow,
            };
            col += scr.write(list_rect.y + row, col, style.box.bullet, .{ .fg = badge_color });
            scr.pad(list_rect.y + row, col, 1, .{});
            col += 1;

            // Name
            const name = sec.nameSlice();
            const max_name: u16 = 24;
            const name_w: u16 = @intCast(@min(name.len, max_name));
            const name_style: Screen.Style = if (is_sel) .{ .bold = true } else .{};
            col += scr.write(list_rect.y + row, col, name[0..name_w], name_style);

            // Value
            const val = sec.valueSlice();
            if (val.len > 0) {
                scr.pad(list_rect.y + row, col, 2, .{});
                col += 2;
                if (self.show_values) {
                    const max_val: u16 = if (content_w > col - list_rect.x + 20) content_w - (col - list_rect.x) - 16 else 16;
                    const val_w: u16 = @intCast(@min(val.len, max_val));
                    col += scr.write(list_rect.y + row, col, val[0..val_w], .{ .dim = true });
                    if (val.len > max_val) col += scr.write(list_rect.y + row, col, style.box.ellipsis, .{ .dim = true });
                } else {
                    col += scr.write(list_rect.y + row, col, "\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2", .{ .dim = true });
                }
            }

            // Description (right-aligned)
            const desc = sec.descSlice();
            const desc_w: u16 = @intCast(desc.len);
            if (desc.len > 0 and col + desc_w + 2 < list_rect.x + content_w) {
                scr.pad(list_rect.y + row, col, list_rect.x + content_w - col - desc_w, .{});
                _ = scr.write(list_rect.y + row, list_rect.x + content_w - desc_w, desc, .{ .dim = true });
            } else {
                scr.pad(list_rect.y + row, col, list_rect.x + content_w -| col, .{});
            }

            row += 1;

            // Detail line for selected
            if (is_sel and row < list_rect.h) {
                scr.pad(list_rect.y + row, list_rect.x, 5, .{});
                var dcol = list_rect.x + 5;
                switch (sec.kind) {
                    .env => dcol += scr.write(list_rect.y + row, dcol, "env", .{ .dim = true }),
                    .local => {
                        dcol += scr.write(list_rect.y + row, dcol, "local ", .{ .dim = true });
                        const dir = sec.dirSlice();
                        const dir_max: u16 = if (content_w > 20) content_w - 20 else content_w;
                        dcol += scr.write(list_rect.y + row, dcol, dir[0..@min(dir.len, dir_max)], .{ .dim = true, .fg = .cyan });
                    },
                    .password => dcol += scr.write(list_rect.y + row, dcol, "password", .{ .dim = true }),
                }
                scr.pad(list_rect.y + row, dcol, list_rect.x + content_w -| dcol, .{});
                row += 1;
            }
        }

        // Clear remaining rows
        while (row < list_rect.h) : (row += 1) {
            scr.pad(list_rect.y + row, list_rect.x, content_w, .{});
        }
    }

    fn drawEmpty(self: *const State, scr: *Screen, rect: tui.Rect) void {
        _ = self;
        const msg = "No secrets stored";
        const mid = rect.h / 2;
        scr.fill(rect, .{});

        // Centered message
        const msg_w: u16 = @intCast(msg.len);
        const pad_l = (rect.w -| msg_w) / 2;
        _ = scr.write(rect.y + mid, rect.x + pad_l, msg, .{ .dim = true });

        // Hint
        if (mid + 2 < rect.h) {
            const hint_row = rect.y + mid + 2;
            const hint_text = "Press  a  to add your first secret";
            const hint_w: u16 = @intCast(hint_text.len);
            const hpad = (rect.w -| hint_w) / 2;
            var col = rect.x + hpad;
            col += scr.write(hint_row, col, "Press ", .{ .dim = true });
            col += scr.write(hint_row, col, "a", .{ .fg = .cyan, .bold = true });
            _ = scr.write(hint_row, col, " to add your first secret", .{ .dim = true });
        }
    }

    fn drawScrollbar(self: *const State, scr: *Screen, rect: tui.Rect, visible: u16, total: usize) void {
        if (total <= visible) return;
        const col = rect.x + rect.w - 1;
        const thumb_h = @max(1, (@as(u32, visible) * visible) / @as(u32, @intCast(total)));
        const max_offset = total - visible;
        const track_space = visible - @as(u16, @intCast(thumb_h));
        const thumb_top: u16 = if (max_offset > 0)
            @intCast((@as(u32, @intCast(self.scroll)) * track_space) / @as(u32, @intCast(max_offset)))
        else
            0;

        var row: u16 = 0;
        while (row < visible) : (row += 1) {
            const ch = if (row >= thumb_top and row < thumb_top + @as(u16, @intCast(thumb_h)))
                style.box.scrollbar_thumb
            else
                style.box.scrollbar_track;
            _ = scr.write(rect.y + row, col, ch, .{ .dim = true });
        }
    }

    fn drawStatusBar(self: *const State, scr: *Screen, rect: tui.Rect) void {
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
            .transparent = true,
        };
        bar.draw(scr, rect);
    }
};

// ---------------------------------------------------------------------------
// Add / Edit modals
// ---------------------------------------------------------------------------

const FieldIdx = enum(u2) { name = 0, value = 1, desc = 2 };

fn addSecretModal(tty: std.fs.File, tty_fd: posix.fd_t, store: *secrets_mod.SecretsStore, kind: secrets_mod.SecretKind, dir: []const u8, ts: TermSize, scr: *Screen) bool {
    var fields: [3]tui.Input = .{ .{}, .{}, .{} };
    const labels = [3][]const u8{ "Name", "Value", "Description" };
    const placeholders = [3][]const u8{ "SECRET_NAME", "secret value", "optional description" };
    for (&fields, placeholders) |*f, ph| { f.placeholder = ph; }
    var active: FieldIdx = .name;
    fields[@intFromEnum(active)].focused = true;

    while (true) {
        drawModal(scr, tty,"Add Secret", &labels, &fields, active, ts);
        const key = keys.readKeyFromFd(tty_fd) orelse return false;
        switch (key) {
            .up, .shift_tab => {
                fields[@intFromEnum(active)].focused = false;
                active = if (@intFromEnum(active) > 0) @enumFromInt(@intFromEnum(active) - 1) else .desc;
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

fn editSecretModal(tty: std.fs.File, tty_fd: posix.fd_t, store: *secrets_mod.SecretsStore, idx: usize, ts: TermSize, scr: *Screen) bool {
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
        drawModal(scr, tty,"Edit Secret", &labels, &fields, active, ts);
        const key = keys.readKeyFromFd(tty_fd) orelse return false;
        switch (key) {
            .up, .shift_tab => {
                fields[@intFromEnum(active)].focused = false;
                active = if (@intFromEnum(active) > 0) @enumFromInt(@intFromEnum(active) - 1) else .desc;
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

fn drawModal(scr: *Screen, tty: std.fs.File, title: []const u8, labels: *const [3][]const u8, fields: *const [3]tui.Input, active: FieldIdx, ts: TermSize) void {
    const cols: u16 = @intCast(@min(ts.cols, Screen.max_cols));
    const rows: u16 = @intCast(@min(ts.rows, Screen.max_rows));
    const scr_rect = tui.Rect.fromSize(cols, rows);

    // Draw the popup frame
    const popup = tui.Popup{
        .title = title,
        .width = .{ .fixed = @min(56, cols -| 4) },
        .height = .{ .fixed = 9 },
        .border_color = .bright_black,
        .title_color = .white,
    };
    popup.draw(scr, scr_rect);

    // Content inside popup
    const content = popup.contentRect(scr_rect);
    if (content.w < 4 or content.h < 5) {
        scr.flush(tty);
        return;
    }

    // Find longest label
    var max_label: u16 = 0;
    for (labels) |l| max_label = @max(max_label, @as(u16, @intCast(l.len)));

    // Field rows (with 1 row gap at top)
    for (0..3) |fi| {
        const field_y = content.y + 1 + @as(u16, @intCast(fi));
        const is_active = @intFromEnum(active) == fi;
        const label = labels[fi];

        // Label (right-aligned)
        const lpad = max_label - @as(u16, @intCast(label.len));
        scr.pad(field_y, content.x, lpad, .{});
        const label_style: Screen.Style = if (is_active) .{ .fg = .cyan } else .{ .fg = .white };
        _ = scr.write(field_y, content.x + lpad, label, label_style);
        scr.pad(field_y, content.x + max_label, 2, .{});

        // Input field
        const field_x = content.x + max_label + 2;
        const field_w = content.w -| max_label -| 2;
        fields[fi].draw(scr, tui.Rect{
            .x = field_x,
            .y = field_y,
            .w = field_w,
            .h = 1,
        });
    }

    // Help row
    const help_bar = tui.StatusBar{
        .items = &.{
            .{ .key = "Tab", .label = "next" },
            .{ .key = "Enter", .label = "save" },
            .{ .key = "Esc", .label = "cancel" },
        },
        .transparent = true,
    };
    help_bar.draw(scr, tui.Rect{
        .x = content.x,
        .y = content.y + content.h - 1,
        .w = content.w,
        .h = 1,
    });

    scr.flush(tty);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const TermSize = struct { rows: usize, cols: usize };

fn getTermSize(fd: posix.fd_t) TermSize {
    const ts = style.getTermSize(fd);
    return .{ .rows = ts.rows, .cols = ts.cols };
}
