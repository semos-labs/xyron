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
            if (self.local_only and sec.kind != .local) continue;
            // Hide local secrets from other directories
            if (sec.kind == .local) {
                const sdir = sec.dirSlice();
                const matches = std.mem.eql(u8, self.cwd, sdir) or
                    (self.cwd.len > sdir.len and std.mem.startsWith(u8, self.cwd, sdir) and self.cwd[sdir.len] == '/');
                if (!matches) continue;
            }
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
                    const default_kind: secrets_mod.SecretKind = if (self.local_only) .local else .env;
                    if (addSecretModal(tty, tty_fd, self.store, default_kind, self.cwd, self.ts, screen)) {
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

    // Fixed column widths for table-like alignment
    const col_arrow: u16 = 3; // " > " or "   "
    const col_type: u16 = 6; // "env   " / "local " / "pass  "
    const col_name: u16 = 20; // secret name
    const col_value: u16 = 16; // value or dots
    // description gets remaining space

    fn drawEntries(self: *const State, scr: *Screen, list_rect: tui.Rect, content_w: u16, vis_end: usize) void {
        var row: u16 = 0;
        const filtered = self.filter.results();

        for (self.scroll..vis_end) |vi| {
            const sec = &self.store.secrets[filtered[vi].index];
            const is_sel = vi == self.cursor;
            const y = list_rect.y + row;
            var col = list_rect.x;

            // Arrow (3 cols)
            if (is_sel) {
                col += scr.write(y, col, " > ", .{ .fg = .cyan });
            } else {
                scr.pad(y, col, col_arrow, .{});
                col += col_arrow;
            }

            // Type (6 cols)
            const badge_label: []const u8 = switch (sec.kind) {
                .env => "env",
                .local => "local",
                .password => "pass",
            };
            const badge_color: style.Color = switch (sec.kind) {
                .env => .green,
                .local => .blue,
                .password => .yellow,
            };
            const bw = scr.write(y, col, badge_label, .{ .fg = badge_color, .dim = true });
            scr.pad(y, col + bw, col_type -| bw, .{});
            col += col_type;

            // Name (20 cols)
            const name = sec.nameSlice();
            const name_w: u16 = @intCast(@min(name.len, col_name));
            const name_style: Screen.Style = if (is_sel) .{ .bold = true } else .{};
            const nw = scr.write(y, col, name[0..name_w], name_style);
            if (name.len > col_name) _ = scr.write(y, col + nw, style.box.ellipsis, name_style);
            scr.pad(y, col + @min(nw + 1, col_name), col_name -| @min(nw + 1, col_name), .{});
            col += col_name;

            // Value (16 cols)
            const val = sec.valueSlice();
            if (val.len > 0) {
                if (self.show_values) {
                    const needs_ellipsis = val.len > col_value;
                    const vw: u16 = @intCast(@min(val.len, if (needs_ellipsis) col_value - 1 else col_value));
                    const written = scr.write(y, col, val[0..vw], .{ .dim = true });
                    var used = written;
                    if (needs_ellipsis) { used += scr.write(y, col + used, style.box.ellipsis, .{ .dim = true }); }
                    scr.pad(y, col + used, col_value -| used, .{});
                } else {
                    _ = scr.write(y, col, "\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2\xe2\x80\xa2", .{ .dim = true });
                    scr.pad(y, col + 8, col_value -| 8, .{});
                }
            } else {
                scr.pad(y, col, col_value, .{});
            }
            col += col_value;

            // Description (remaining space, left-aligned)
            const desc = sec.descSlice();
            const remaining = content_w -| (col - list_rect.x);
            if (desc.len > 0 and remaining > 0) {
                const dw: u16 = @intCast(@min(desc.len, remaining));
                const written = scr.write(y, col, desc[0..dw], .{ .dim = true });
                scr.pad(y, col + written, remaining -| written, .{});
            } else {
                scr.pad(y, col, remaining, .{});
            }

            row += 1;

            // Detail line for selected (shows directory for local secrets)
            if (is_sel and sec.kind == .local and sec.dir_len > 0 and row < list_rect.h) {
                const indent = col_arrow + col_type;
                scr.pad(list_rect.y + row, list_rect.x, indent, .{});
                const dir = sec.dirSlice();
                const dir_max: u16 = if (content_w > indent + 2) content_w - indent - 2 else content_w;
                var dcol = list_rect.x + indent;
                dcol += scr.write(list_rect.y + row, dcol, dir[0..@min(dir.len, dir_max)], .{ .dim = true, .fg = .cyan });
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

const FieldIdx = enum(u3) { name = 0, value = 1, desc = 2, kind = 3 };
const field_count = 4;

fn addSecretModal(tty: std.fs.File, tty_fd: posix.fd_t, store: *secrets_mod.SecretsStore, default_kind: secrets_mod.SecretKind, cwd: []const u8, ts: TermSize, scr: *Screen) bool {
    var fields: [3]tui.Input = .{ .{}, .{}, .{} };
    const labels = [field_count][]const u8{ "Name", "Value", "Description", "Type" };
    const placeholders = [3][]const u8{ "SECRET_NAME", "secret value", "optional description" };
    for (&fields, placeholders) |*f, ph| { f.placeholder = ph; }
    var active: FieldIdx = .name;
    fields[@intFromEnum(active)].focused = true;
    var kind = default_kind;

    while (true) {
        drawModalWithKind(scr, tty, "Add Secret", &labels, &fields, active, kind, ts);
        const key = keys.readKeyFromFd(tty_fd) orelse return false;
        switch (key) {
            .up, .shift_tab => {
                if (@intFromEnum(active) < 3) fields[@intFromEnum(active)].focused = false;
                active = if (@intFromEnum(active) > 0) @enumFromInt(@intFromEnum(active) - 1) else .kind;
                if (@intFromEnum(active) < 3) fields[@intFromEnum(active)].focused = true;
            },
            .down, .tab => {
                if (@intFromEnum(active) < 3) fields[@intFromEnum(active)].focused = false;
                active = if (@intFromEnum(active) < 3) @enumFromInt(@intFromEnum(active) + 1) else .name;
                if (@intFromEnum(active) < 3) fields[@intFromEnum(active)].focused = true;
            },
            .enter => {
                if (fields[0].value().len == 0) continue;
                const dir = if (kind == .local) cwd else "";
                return store.add(fields[0].value(), fields[1].value(), fields[2].value(), dir, kind);
            },
            .escape, .ctrl_c => return false,
            .left, .right => {
                if (active == .kind) kind = cycleKind(kind, key == .right);
            },
            else => {
                if (active == .kind) {
                    if (key == .char and key.char == ' ') kind = cycleKind(kind, true);
                } else {
                    _ = fields[@intFromEnum(active)].handleKey(key);
                }
            },
        }
    }
}

fn cycleKind(current: secrets_mod.SecretKind, forward: bool) secrets_mod.SecretKind {
    const order = [_]secrets_mod.SecretKind{ .env, .local, .password };
    for (order, 0..) |k, i| {
        if (k == current) {
            if (forward) return order[(i + 1) % 3];
            return order[(i + 2) % 3]; // backward wrap
        }
    }
    return .env;
}

fn editSecretModal(tty: std.fs.File, tty_fd: posix.fd_t, store: *secrets_mod.SecretsStore, idx: usize, ts: TermSize, scr: *Screen) bool {
    if (idx >= store.count) return false;
    const sec = &store.secrets[idx];

    var fields: [3]tui.Input = .{ .{}, .{}, .{} };
    const labels = [field_count][]const u8{ "Name", "Value", "Description", "Type" };
    fields[0].setValue(sec.nameSlice());
    fields[1].setValue(sec.valueSlice());
    fields[2].setValue(sec.descSlice());
    var kind = sec.kind;

    var active: FieldIdx = .value;
    fields[@intFromEnum(active)].focused = true;

    while (true) {
        drawModalWithKind(scr, tty, "Edit Secret", &labels, &fields, active, kind, ts);
        const key = keys.readKeyFromFd(tty_fd) orelse return false;
        switch (key) {
            .up, .shift_tab => {
                if (@intFromEnum(active) < 3) fields[@intFromEnum(active)].focused = false;
                active = if (@intFromEnum(active) > 0) @enumFromInt(@intFromEnum(active) - 1) else .kind;
                if (@intFromEnum(active) < 3) fields[@intFromEnum(active)].focused = true;
            },
            .down, .tab => {
                if (@intFromEnum(active) < 3) fields[@intFromEnum(active)].focused = false;
                active = if (@intFromEnum(active) < 3) @enumFromInt(@intFromEnum(active) + 1) else .name;
                if (@intFromEnum(active) < 3) fields[@intFromEnum(active)].focused = true;
            },
            .enter => {
                if (fields[0].value().len == 0) continue;
                secrets_mod.SecretsStore.setFieldPub(&sec.name, &sec.name_len, fields[0].value());
                secrets_mod.SecretsStore.setFieldPub(&sec.value, &sec.value_len, fields[1].value());
                secrets_mod.SecretsStore.setFieldPub(&sec.description, &sec.desc_len, fields[2].value());
                sec.kind = kind;
                store.modified = true;
                return true;
            },
            .escape, .ctrl_c => return false,
            .left, .right => {
                if (active == .kind) kind = cycleKind(kind, key == .right);
            },
            else => {
                if (active == .kind) {
                    if (key == .char and key.char == ' ') kind = cycleKind(kind, true);
                } else {
                    _ = fields[@intFromEnum(active)].handleKey(key);
                }
            },
        }
    }
}

fn drawModalWithKind(scr: *Screen, tty: std.fs.File, title: []const u8, labels: *const [field_count][]const u8, fields: *const [3]tui.Input, active: FieldIdx, kind: secrets_mod.SecretKind, ts: TermSize) void {
    const cols: u16 = @intCast(@min(ts.cols, Screen.max_cols));
    const rows: u16 = @intCast(@min(ts.rows, Screen.max_rows));
    const scr_rect = tui.Rect.fromSize(cols, rows);

    const popup = tui.Popup{
        .title = title,
        .width = .{ .fixed = @min(56, cols -| 4) },
        .height = .{ .fixed = 10 },
        .border_color = .bright_black,
        .title_color = .white,
    };
    popup.draw(scr, scr_rect);

    const content = popup.contentRect(scr_rect);
    if (content.w < 4 or content.h < 6) {
        scr.flush(tty);
        return;
    }

    // Find longest label
    var max_label: u16 = 0;
    for (labels) |l| max_label = @max(max_label, @as(u16, @intCast(l.len)));

    // Text input fields (rows 0-2)
    for (0..3) |fi| {
        const field_y = content.y + 1 + @as(u16, @intCast(fi));
        const is_active = @intFromEnum(active) == fi;
        const label = labels[fi];

        const lpad = max_label - @as(u16, @intCast(label.len));
        scr.pad(field_y, content.x, lpad, .{});
        const label_style: Screen.Style = if (is_active) .{ .fg = .cyan } else .{ .fg = .white };
        _ = scr.write(field_y, content.x + lpad, label, label_style);
        scr.pad(field_y, content.x + max_label, 2, .{});

        const field_x = content.x + max_label + 2;
        const field_w = content.w -| max_label -| 2;
        fields[fi].draw(scr, tui.Rect{ .x = field_x, .y = field_y, .w = field_w, .h = 1 });
    }

    // Type selector (row 3)
    {
        const field_y = content.y + 4;
        const is_active = active == .kind;
        const label = labels[3];

        const lpad = max_label - @as(u16, @intCast(label.len));
        scr.pad(field_y, content.x, lpad, .{});
        const label_style: Screen.Style = if (is_active) .{ .fg = .cyan } else .{ .fg = .white };
        _ = scr.write(field_y, content.x + lpad, label, label_style);
        scr.pad(field_y, content.x + max_label, 2, .{});

        const field_x = content.x + max_label + 2;
        const field_w = content.w -| max_label -| 2;

        // Draw type pills: [env] [local] [password]
        var col = field_x;
        const kinds = [_]secrets_mod.SecretKind{ .env, .local, .password };
        const kind_labels = [_][]const u8{ " env ", " local ", " password " };
        const kind_colors = [_]style.Color{ .green, .blue, .yellow };

        for (kinds, kind_labels, kind_colors) |k, kl, kc| {
            const selected = k == kind;
            const pill_style: Screen.Style = if (selected)
                .{ .fg = kc, .inverse = true }
            else if (is_active)
                .{ .dim = true }
            else
                .{ .dim = true };
            col += scr.write(field_y, col, kl, pill_style);
            scr.pad(field_y, col, 1, .{});
            col += 1;
        }
        scr.pad(field_y, col, field_x + field_w -| (col - field_x), .{});
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
