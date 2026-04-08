---
name: tui
description: Build or refactor TUI apps using the declarative component system in src/tui/. Use when creating fullscreen interactive tools, modals, fuzzy finders, or refactoring existing TUI code.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
argument-hint: [new <name> | refactor <file>]
---

# TUI App Skill

You are helping the user build or refactor a fullscreen interactive TUI tool using the declarative component library at `src/tui/`.

Parse the user's arguments:

| User says | Action |
|-----------|--------|
| `/tui new <name>` | Create a new TUI app |
| `/tui refactor <file>` | Refactor an existing TUI app to use components |
| `/tui` (no args) | Ask what they want to build or refactor |

Before starting, read `src/tui.zig` to see all available exports, and `src/tui/core.zig` for layout primitives.

---

## Component Library Reference

### Core types (`src/tui/core.zig`)

| Type | Purpose |
|------|---------|
| `Rect` | Screen region `{x, y, w, h}` (1-based). Create with `Rect.fromSize(cols, rows)` |
| `Size` | Layout unit: `.{ .fixed = N }`, `.{ .flex = N }`, `.{ .percent = N }` |
| `Element` | Type-erased renderable. Wrap any component with `component.element()` |
| `Action` | Key handler result: `.none`, `.changed`, `.submit`, `.cancel`, `.ignored` |
| `VStack` | Vertical layout container. Takes `sizes` + `children` (Elements) |
| `HStack` | Horizontal layout container. Same interface as VStack |

**Layout:**
```zig
const screen = tui.Rect.fromSize(cols, rows);
var rects: [3]tui.Rect = undefined;
_ = screen.splitRows(&.{
    tui.Size{ .fixed = 1 },    // title bar
    tui.Size{ .flex = 1 },     // content
    tui.Size{ .fixed = 1 },    // status bar
}, &rects);
```

**Rect helpers:** `.inner(padding)`, `.padding(top, right, bottom, left)`, `.centered(w, h)`, `.centeredPercent(wp, hp)`, `.row(idx)`, `.splitRows(sizes, out)`, `.splitCols(sizes, out)`

### Components

| Component | File | Purpose |
|-----------|------|---------|
| `tui.Input` | `Input.zig` | Text input with Emacs keybindings, kill ring, horizontal scroll |
| `tui.ScrollList` | `ScrollList.zig` | Vertical list with selection, scrollbar, paging |
| `tui.FuzzyList` | `FuzzyList.zig` | Input + ScrollList with fuzzy filtering and match highlighting |
| `tui.Table` | `Table.zig` | Column table with headers, alignment, scrollbar |
| `tui.Menu` | `Menu.zig` | Menu with separators, disabled items, hint text |
| `tui.Text` | `Text.zig` | Styled text with alignment and ellipsis truncation |
| `tui.Box` | `Box.zig` | Bordered container with optional title |
| `tui.Separator` | `Box.zig` | Horizontal line |
| `tui.StatusBar` | `Box.zig` | Bottom bar with key hint pills |
| `tui.Popup` | `Popup.zig` | Centered modal with border, fixed or percent sizing |

### Rendering helpers

| Function | Purpose |
|----------|---------|
| `tui.pad(buf, n)` | Write `n` spaces |
| `tui.clipText(buf, text, max_w)` | Copy text, truncate at `max_w` columns (ASCII fast path) |
| `tui.clipTextUnicode(buf, text, max_w)` | Width-aware clipping for CJK/emoji. Returns `{.bytes, .width}` |
| `tui.displayWidth(text)` | Display width of UTF-8 string in terminal columns |
| `tui.renderScrollbar(buf, y, col, visible, total, offset)` | Shared scrollbar renderer |
| `tui.padLine(buf, visible, width)` | Pad remaining width of a line |

### All components follow this protocol

```zig
// Declare with struct literal (all fields have defaults)
var input = tui.Input{ .focused = true, .prompt = "> " };

// Render into a buffer at a Rect
const n = input.render(buf[pos..], rect);
pos += n;

// Handle keys (interactive components)
const action = input.handleKey(key);
switch (action) {
    .changed => { /* re-render */ },
    .submit  => { /* accept */ },
    .cancel  => { /* exit */ },
    .ignored => { /* pass to parent */ },
    .none    => {},
}

// Type-erase for container use
const elem = input.element();
```

---

## Building a New TUI App

Every fullscreen TUI app follows this skeleton. Create the file in `src/builtins/<name>.zig` (for builtins) or `src/<name>.zig` (for core features).

### Skeleton

```zig
const std = @import("std");
const posix = std.posix;
const c = std.c;
const style = @import("../style.zig"); // or "style.zig" for src/
const tui = @import("../tui.zig");
const keys_mod = @import("../keys.zig");

pub fn run(/* params */) !void {
    // 1. Open /dev/tty (works when stdout is piped)
    const tty_fd = posix.openZ("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return;
    defer posix.close(tty_fd);
    const tty_file = std.fs.File{ .handle = tty_fd };

    // 2. Raw mode
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

    // 3. Alternate screen + show cursor
    tty_file.writeAll("\x1b[?1049h\x1b[?25h") catch {};
    defer tty_file.writeAll("\x1b[?25h\x1b[?1049l") catch {};

    // 4. Get terminal size
    var ts = getTermSize(tty_fd);

    // 5. Declare components
    var input = tui.Input{ .focused = true, .prompt = "> ", .prompt_color = .yellow };
    var list = tui.ScrollList{ .items = items };
    // ... other components

    // 6. Initial render
    renderFrame(tty_file, &input, &list, ts);

    // 7. Event loop
    while (true) {
        var key_buf: [1]u8 = undefined;
        const rc = c.read(tty_fd, &key_buf, 1);
        if (rc == -1) {
            // SIGWINCH — resize
            ts = getTermSize(tty_fd);
            renderFrame(tty_file, &input, &list, ts);
            continue;
        }
        if (rc <= 0) break;

        const key = keys_mod.parseKey(key_buf[0], tty_fd);

        // Route key to focused component
        const action = input.handleKey(key);
        switch (action) {
            .submit => { /* handle submit */ break; },
            .cancel => break,
            .changed => { /* update dependent state */ },
            .none => {},
            .ignored => {
                // Pass to other components
                _ = list.handleKey(key);
            },
        }

        renderFrame(tty_file, &input, &list, ts);
    }
}

fn renderFrame(tty: std.fs.File, input: *const tui.Input, list: *const tui.ScrollList, ts: TermSize) void {
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;

    const cols: u16 = @intCast(ts.cols);
    const rows: u16 = @intCast(ts.rows);
    const screen = tui.Rect.fromSize(cols, rows);

    // Layout
    var rects: [3]tui.Rect = undefined;
    _ = screen.splitRows(&.{
        tui.Size{ .fixed = 1 },  // input
        tui.Size{ .flex = 1 },   // list
        tui.Size{ .fixed = 1 },  // status bar
    }, &rects);

    pos += style.home(buf[pos..]);

    // Render components
    pos += input.render(buf[pos..], rects[0]);
    pos += list.render(buf[pos..], rects[1]);

    // Status bar
    const bar = tui.StatusBar{
        .items = &.{
            .{ .key = "Enter", .label = "select" },
            .{ .key = "Esc", .label = "cancel" },
        },
    };
    pos += bar.render(buf[pos..], rects[2]);

    tty.writeAll(buf[0..pos]) catch {};
}

const TermSize = struct { rows: usize, cols: usize };

fn getTermSize(fd: posix.fd_t) TermSize {
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0) return .{ .rows = ws.row, .cols = ws.col };
    return .{ .rows = 24, .cols = 80 };
}
```

### Key principles

1. **Render into a buffer, write once.** Never call `tty.writeAll` per-line. Build the entire frame in a `[65536]u8` buffer, then flush.
2. **Use `/dev/tty` for I/O.** This lets the tool work when stdout is piped.
3. **Handle SIGWINCH.** When `c.read` returns -1 (EINTR), re-query terminal size and re-render.
4. **Use `style.zig` for all ANSI codes.** Never write raw `\x1b[...m`. Use `style.bold()`, `style.fg()`, `style.inverse()`, etc.
5. **Base 16 colors only.** Use `style.Color` enum (`.red`, `.green`, `.cyan`, etc.). No 256-color or truecolor.
6. **Use `tui.clipTextUnicode` for user-provided text** that may contain CJK or emoji. Use `tui.clipText` for known-ASCII internal labels.
7. **Every component is `*const Self` for render.** State mutation happens in `handleKey` or helper methods, not during render.
8. **Keep files under 600 lines.** Split complex apps into a main file + state/render modules if needed.

---

## Refactoring Existing TUI Apps

Three existing apps predate the component library and use manual rendering:

| App | File | Lines | What to refactor |
|-----|------|-------|-----------------|
| **Ctrl+R search** | `src/history_search.zig` | ~457 | Manual filter input, scored list, scrollbar, status bar |
| **History explorer** | `src/builtins/history_explore.zig` | ~438 | Manual filter, scored list with pills, detail view, scrollbar |
| **Fuzzy finder (fz)** | `src/builtins/fz.zig` | ~809 | Manual filter, scored list, multi-select, preview pane, file colors |

### Refactoring strategy

Refactor incrementally — replace one rendering section at a time, test, then move to the next. Don't rewrite the whole file at once.

#### Step 1: Identify replaceable sections

Read the target file and identify these manual patterns:

| Manual pattern | Replace with |
|----------------|-------------|
| Filter input (char accumulation, cursor, backspace) | `tui.Input` with `handleKey` |
| Scored/filtered list rendering with selection highlight | `tui.ScrollList` or `tui.FuzzyList` |
| Manual scrollbar calculation + rendering | Built-in scrollbar in ScrollList/FuzzyList, or `tui.renderScrollbar` |
| Title bar (inverse + right-aligned metadata) | `tui.Text{ .is_inverse = true }` or keep manual (often app-specific) |
| Status bar with key hints | `tui.StatusBar` |
| Separator line | `tui.Separator` |
| Popup/modal frame | `tui.Popup` + `tui.Box` |
| Manual scroll tracking (`scroll`, `max_vis`, clamping) | Component's built-in `ensureVisible` + `scroll_offset` |

#### Step 2: Replace the filter input

The biggest win. All three apps manually accumulate a filter string with char-by-char handling. Replace with `tui.Input`:

**Before (manual):**
```zig
var filter: [128]u8 = undefined;
var filter_len: usize = 0;
// In event loop:
if (ch >= 32 and ch < 127) { filter[filter_len] = ch; filter_len += 1; }
if (ch == 127 and filter_len > 0) filter_len -= 1;
// Ctrl+U, Ctrl+W handled manually...
```

**After (component):**
```zig
var input = tui.Input{ .focused = true, .prompt = "> ", .prompt_color = .yellow };
// In event loop:
const action = input.handleKey(key);
if (action == .changed) refilter(input.value());
```

This immediately gives you: Emacs keybindings (^A/^E/^W/^U/^K/^Y), word movement (Alt+B/F), cursor positioning, horizontal scroll, UTF-8 support, and the kill ring — all for free.

#### Step 3: Replace the list rendering

**For apps with fuzzy filtering** (all three), consider `tui.FuzzyList` which bundles Input + filtered list:

```zig
var filtered_buf: [MAX_ENTRIES]tui.FuzzyList.FilteredItem = undefined;
var fz = tui.FuzzyList.init(item_strings, &filtered_buf);
fz.prompt = "> ";
fz.prompt_color = .yellow;

// In event loop — single handleKey handles both input and list navigation:
const action = fz.handleKey(key);
// In render — single render call draws input + filtered list:
pos += fz.render(buf[pos..], content_rect);
```

**For apps needing custom row rendering** (exit codes, duration, colored items), keep `tui.ScrollList` for navigation/scrollbar and render rows manually using the list's `selected` and `scroll_offset` state.

#### Step 4: Replace the status bar

**Before:**
```zig
pos += style.inverse(buf[pos..]);
pos += cp(buf[pos..], " Enter");
pos += style.bold(buf[pos..]);
pos += cp(buf[pos..], " select  ");
pos += style.unbold(buf[pos..]);
// ... more manual key hints
pos += style.reset(buf[pos..]);
```

**After:**
```zig
const bar = tui.StatusBar{
    .items = &.{
        .{ .key = "Enter", .label = "select" },
        .{ .key = "Esc", .label = "cancel" },
        .{ .key = "^F", .label = "failed" },
    },
};
pos += bar.render(buf[pos..], status_rect);
```

#### Step 5: Use Rect layout instead of manual row counting

**Before:**
```zig
const header = 3; // title + filter + separator
const footer = 2; // empty + status bar
const max_vis = if (rows > header + footer) rows - header - footer else 1;
// Manual moveTo for each section...
```

**After:**
```zig
const screen = tui.Rect.fromSize(cols, rows);
var rects: [4]tui.Rect = undefined;
_ = screen.splitRows(&.{
    tui.Size{ .fixed = 1 },  // title
    tui.Size{ .fixed = 1 },  // filter
    tui.Size{ .flex = 1 },   // list
    tui.Size{ .fixed = 1 },  // status
}, &rects);
// Components render into their rects — no manual row math.
```

### What NOT to refactor

Some things are better left manual:

- **Custom row rendering with rich formatting** (exit code icons, duration, relative time, match highlighting with positions) — components render plain text items. If you need per-cell styling, render manually but use `Rect` for positioning and `tui.renderScrollbar` for the scrollbar.
- **App-specific key handling** (filter pills in history explorer, multi-select in fz, preview pane toggling) — these are business logic, not UI components.
- **The event loop itself** — the raw mode setup, `/dev/tty` opening, and SIGWINCH handling are boilerplate but app-specific. Keep them.

### Refactoring checklist

Before finishing a refactor, verify:

- [ ] Builds cleanly (`zig build`)
- [ ] Tests pass (`zig build test`)
- [ ] Interactive test works (`attyx --headless --cmd ./zig-out/bin/xyron`)
- [ ] No raw `\x1b[...m` escape codes remain (use `style.*`)
- [ ] File stays under 600 lines
- [ ] Scrollbar still works (uses component or `tui.renderScrollbar`)
- [ ] SIGWINCH resize still works
- [ ] All original keybindings preserved
- [ ] Visual output matches the design language from CLAUDE.md

---

## Design Language Quick Reference

From CLAUDE.md — all TUI tools must follow this:

- **Title bar**: `inverse` (7m), icon + title left, metadata right-aligned `dim`
- **Filter bar**: yellow `>` prompt, bold input, dim placeholder
- **Filter pills**: inverse with color (red for failed, blue for cwd)
- **Separator**: dim `horizontal` line
- **Selected row**: inverse + bold
- **Status indicators**: green `bullet` success, red `cross` failure
- **Right metadata**: yellow for duration, dim for timestamps
- **Scrollbar**: dim `scrollbar_thumb` / `scrollbar_track` on right edge
- **Status bar**: inverse, bold key + normal label
- **Empty state**: centered, dim message
- **Alternate screen**: `\x1b[?1049h` on entry, `\x1b[?1049l` on exit
