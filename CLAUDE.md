# Xyron Shell

A standalone shell built in Zig. Replaces zsh/fish/bash. Not POSIX — uses Lua for scripting.

## Companion project

Xyron is tightly coupled with **Attyx** (terminal emulator) at `~/Projects/attyx`. Xyron works standalone but integrates deeply with Attyx when running inside it. When making design decisions, consider both standalone and Attyx-integrated modes.

## Language & tooling

- **Zig 0.15** — entire codebase, links sqlite3 and lua via system libraries
- **Lua 5.4** — scripting/configuration language (no bash/sh scripting, xyron is not POSIX)
- Shell can delegate to `sh` when needed, but Lua is the first-class scripting interface

## Architecture rules

- **Every file must stay around 600 lines.** Split when approaching the limit.
- Keep modules focused — one responsibility per file.
- Builtins live in `src/builtins/` — one file per command, dispatched from `mod.zig`.
- **Every big feature must be well documented** in `docs/`. Not in this file.

## XDG directories

- **Config**: `$XDG_CONFIG_HOME/xyron/` (default `~/.config/xyron/`)
  - `config.lua` — Lua config entry point, loaded on startup
  - `require()` resolves relative to the config dir
- **Data**: `$XDG_DATA_HOME/xyron/` (default `~/.local/share/xyron/`)
  - `history.db` — SQLite command history + help cache

## Operation modes

1. **Classic shell** — `xyron` — normal interactive shell in any terminal
2. **Enhanced shell** — `xyron` inside Attyx — shell + native UI bridge
3. **Interactive + IPC** — `xyron --ipc` — interactive shell with Unix socket for external queries (auto-enabled when `ATTYX=1`)
4. **Headless runtime** — `xyron --headless` — backend for Attyx frontend, binary protocol on stdin/stdout

## Interactive testing

Attyx (`attyx` — global command, NOT a dev build path) provides headless mode for automated interactive testing:

```sh
attyx --headless --cmd ./zig-out/bin/xyron &
sleep 0.5
attyx send-keys "echo hello{Enter}"
attyx send-keys --wait-stable ""
attyx get-text
# Special keys: {Tab} {Shift-Tab} {Up} {Down} {Ctrl-c} {Ctrl-d} {Ctrl-z} {Enter} {Escape}
attyx send-keys "exit{Enter}"
```

## Build & test

- **Always run `zig build` after changes** to verify compilation.
- **Always run tests after changes** (`zig build test`).
- Every new feature, change, or fix **must have tests**.
- If a test fails, fix it before moving on.
- Build links: `-lsqlite3 -llua -lc` with include/lib paths for homebrew.

## Lua API types

- When adding, changing, or removing any `xyron.*` Lua API function, **always update `src/lua_types.zig.embedded`** to match. This file is the LuaLS type definition source — it's embedded in the binary and written to `XDG_DATA_HOME/xyron/types/xyron.lua` on shell startup.
- Keep annotations accurate: parameter types, return types, doc comments.
- Config toggles live under `xyron.config.*` (e.g. `xyron.config.completion`). Old top-level names are kept for backward compat with `@deprecated`.

## Terminal styling

- **Always use `src/style.zig`** for ANSI escape sequences. Never write raw `\x1b[...m` strings in builtins or output code.
- Use `style.print(file, fmt, args)` for formatted output, `style.printDim` / `style.printPass` / `style.printFail` / `style.printWarn` / `style.printHeader` for common patterns.
- For buffer-based rendering (prompt, TUI), use `style.fg()`, `style.bold()`, `style.reset()`, `style.colored()`, etc.
- Colors: use `style.Color` enum (`.red`, `.green`, `.cyan`, etc.) — base 16 terminal palette only.
- Symbols: use `style.box.bullet` (●), `style.box.cross` (✗), etc.

## Code style

- Idiomatic Zig — follow stdlib conventions
- **Modular and lean** — small focused functions, clear separation of concerns
- **Well commented** — explain intent and non-obvious logic
- Prefer explicit over clever
- **Stack size awareness** — large arrays (>10KB) should be heap-allocated or kept small. The Shell struct lives on the stack.

## TUI design language

All built-in TUI tools (history explorer, fz, Ctrl+R, future tools) must share a consistent look.

**Use the base 16 terminal colors** (0-15) which are defined by the user's theme. Attyx themes define all 16 palette colors — using these ensures the UI respects the user's chosen aesthetic. Use `38;5;0-15` / `48;5;0-15` or the standard `30-37`/`90-97` codes. Color 8 (`bright_black`) works well as a subtle modal/overlay background. Avoid 256-color indices 16-255 and RGB/truecolor — those bypass the theme.

- **Title bar**: `7m` (inverse), icon + title left, metadata right-aligned `2m` (dim)
- **Filter/search bar**: `33m` (yellow) `>` prompt, `1m` bold input, `2m` dim placeholder
- **Active filter pills**: `7m` inverse with color (e.g. `31;7m` red inverse for failed, `34;7m` blue for cwd)
- **Separator**: `2m` dim `─` line
- **Selected row**: `7m` inverse, `1m` bold text
- **Normal row**: default styling
- **Status indicators**: `32m` green `●` success, `31m` red `✗` failure
- **Right-aligned metadata**: `33m` yellow for duration, `2m` dim for timestamps
- **Scrollbar**: right edge, `2m` dim `▐` thumb, `2m` dim `░` track
- **Status bar**: `7m` inverse, key pills `1m` bold key + normal label
- **Empty state**: centered `2m` dim message
- **Cursor**: visible in search input, positioned at end of filter text
- **Resize**: handle SIGWINCH (EINTR from `c.read`), re-query size, re-render
- **Alternate screen**: `\x1b[?1049h` on entry, `\x1b[?1049l` on exit (before writing result)

## What NOT to do

- No POSIX compatibility layer — this is intentional
- No bash/sh syntax support in the shell language itself (delegate to `/bin/sh` for bash syntax)
- Don't add features beyond what's asked
- Don't create README or docs unless requested
- Don't store `*pointer` to fields of a struct that gets returned by value from `init()` — the struct moves and the pointer dangles. Use copies or set pointers after the struct is at its final location.
- Documentation goes in `docs/`, NOT in this file

## Documentation

All reference documentation lives in `docs/`. **Keep docs in sync with the code** — when adding, changing, or removing a major feature or architecture decision, update the relevant doc. Add new docs for new features, remove stale ones. Docs should reflect the current state of the codebase, not aspirational design.

- `docs/source-layout.md` — source file map
- `docs/headless-protocol.md` — binary wire protocol
- `docs/ipc-mode.md` — IPC socket, handshake, completion overlay protocol
- `docs/lua-api.md` — Lua scripting API
- `docs/block-model.md` — command block lifecycle
- `docs/structured-output.md` — table rendering, pipe commands
- `docs/attyx-integration.md` — OSC events, native UI bridge
- `docs/history-queries.md` — SQLite history queries
- `docs/sqlite-schema.md` — database schema
- `docs/project-system.md` — project system (xyron.toml, context, commands, services, doctor, explain, bootstrap)
- `docs/migration-assistant.md` — bash/zsh conversion
