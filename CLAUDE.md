# Xyron Shell

A standalone shell built in Zig. Replaces zsh/fish/bash. Not POSIX — uses Lua for scripting.

## Companion project

Xyron is tightly coupled with **Attyx** (terminal emulator) at `~/Projects/attyx`. Xyron works standalone but integrates deeply with Attyx when running inside it. When making design decisions, consider both standalone and Attyx-integrated modes.

## Language & tooling

- **Zig** — entire codebase
- **Lua** — scripting/configuration language (no bash/sh scripting, xyron is not POSIX)
- Shell can delegate to `sh` when needed, but Lua is the first-class scripting interface

## Architecture rules

- **Every file must stay around 600 lines.** Split when approaching the limit.
- Keep modules focused — one responsibility per file.

## Built-in commands

Xyron ships sane standard builtins: `cd`, `ls`, `mkdir`, `rm`, `cp`, `mv`, `echo`, `cat`, `pwd`, `env`, `export`, `unset`, `exit`, `history`, `which`, `alias`, `source`, `true`, `false`, and others as needed.

External commands are available via `sh` passthrough.

### `xyron` command

- `xyron` (aliased as `xy`) is the shell's own CLI for configuration, plugin management, and shell utilities.
- Placeholder for now — will be defined later.

## XDG directories

Xyron follows XDG Base Directory spec:

- **Config**: `$XDG_CONFIG_HOME/xyron/` (default `~/.config/xyron/`)
  - `config.lua` — Lua config entry point, loaded on startup
- **Data**: `$XDG_DATA_HOME/xyron/` (default `~/.local/share/xyron/`)
  - `history.db` — SQLite command history

## Login shell

Xyron must be usable as a login shell (`chsh -s`). This means:
- Binary goes in `/etc/shells`
- Handles `-l` / `--login` flag
- Reads appropriate startup files on login

## Interactive testing

Attyx (`attyx` — global command) provides headless mode for automated interactive testing:

```sh
# Start headless instance running xyron
attyx --headless --cmd ./zig-out/bin/xyron &
sleep 0.5

# Send keystrokes and read screen
attyx send-keys "echo hello{Enter}"
attyx send-keys --wait-stable ""
attyx get-text

# Special keys: {Tab} {Shift-Tab} {Up} {Down} {Ctrl-c} {Ctrl-d} {Ctrl-z} {Enter} {Escape}
# Hex escapes: \x03 (Ctrl+C), \n (Enter)

# Clean up
attyx send-keys "exit{Enter}"
```

Use this for testing interactive features (completion, highlighting, Ctrl+Z, history nav) that can't be tested via piped input.

## Build & test

- **Always run `zig build` after changes** to verify compilation.
- **Always run tests after changes** (`zig build test`).
- Every new feature, change, or fix **must have tests**. Add or adjust tests as needed — no untested code lands.
- If a test fails, fix it before moving on.

## Code style

- Idiomatic Zig — follow stdlib conventions
- **Modular and lean** — small focused functions, clear separation of concerns
- **Well commented** — explain intent and non-obvious logic, not what the code literally does
- Prefer explicit over clever.

## What NOT to do

- No POSIX compatibility layer — this is intentional
- No bash/sh syntax support in the shell language itself
- Don't add features beyond what's asked
- Don't create README or docs unless requested
