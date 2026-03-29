<h1 align="center">Xyron</h1>

<p align="center">
  <strong>A modern shell built in Zig, designed for Attyx</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zig-0.15-f7a41d?logo=zig&logoColor=white" alt="Zig 0.15">
  <img src="https://img.shields.io/badge/Lua-5.4-2C2D72?logo=lua&logoColor=white" alt="Lua 5.4">
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License">
</p>

## About

Xyron is a shell that replaces bash/zsh/fish. Not POSIX — by design. Lua for scripting, SQLite for history, structured output for everything.

Works standalone in any terminal. Works best inside [Attyx](https://github.com/semos-labs/attyx), where it becomes a runtime backend with native UI integration, structured command blocks, and a binary protocol for headless operation.

**What makes it different:**

- **Lua, not bash** — config, hooks, custom commands, automation. No more `.bashrc` spaghetti.
- **Structured output** — `ls`, `ps`, `env`, `history`, `jobs` return colored tables, not raw text. Pipe JSON through `json` for typed rendering.
- **SQLite history** — every command recorded with exit code, duration, cwd. Query with `history search`, `history failed`, `history cwd`. Replay with `history rerun`.
- **Real completion** — fuzzy picker with descriptions, help introspection cache (parses `--help` output), path/env/flag providers.
- **Ghost text** — history suggestions appear inline as you type. Right arrow to accept.
- **Vim mode** — optional modal editing. `xyron.vim_mode(true)` in config. Cursor shape and prompt symbol change with mode.
- **Prompt engine** — modular segments (cwd, git branch, jobs, duration, symbol, spacer for right-alignment, custom Lua functions). Multiline support.
- **Job control** — background (`&`), Ctrl+Z suspend, `fg`/`bg` resume, process groups.
- **Attyx integration** — structured lifecycle events, native popups/pickers, headless runtime mode with binary protocol for block-based UI.
- **Migration assistant** — `migrate analyze` and `migrate convert` to move from bash/sh to Xyron/Lua.

## Build

Requires **Zig 0.15.2+**, **SQLite3**, and **Lua 5.4**.

```bash
# macOS (Homebrew)
brew install zig lua sqlite

# Build
zig build

# Run
./zig-out/bin/xyron

# Run tests
zig build test
```

## Configuration

`~/.config/xyron/config.lua`:

```lua
-- Environment
xyron.setenv("EDITOR", "vim")

-- Aliases
xyron.alias("ll", "ls -la")
xyron.alias("gs", "git status")
xyron.alias("gp", "git push")

-- Prompt: path + git branch on line 1, symbol on line 2
xyron.prompt({
    "cwd", " ", "git_branch",
    "spacer",
    function() return os.date("%H:%M") end,
    "\n",
    "symbol", " ",
})

-- Custom command
xyron.command("mkcd", function(args)
    if #args == 0 then return 1 end
    os.execute("mkdir -p " .. args[1])
    xyron.exec("cd " .. args[1])
    return 0
end)

-- Hook: notify on failure
xyron.on("on_command_finish", function(data)
    if data.exit_code ~= 0 then
        io.stderr:write("✘ exit " .. data.exit_code .. "\n")
    end
end)

-- Optional: vim mode
-- xyron.vim_mode(true)
```

## Structured output

Commands return typed, colored tables instead of raw text:

```
> ls -la
permissions  name         type  size
────────────────────────────────────
drwxr-xr-x   .git/        dir      -
-rw-r--r--   CLAUDE.md    file  3.1K
-rw-r--r--   build.zig    file  2.8K
drwxr-xr-x   src/         dir      -

> history failed
  #  command     exit  duration
──────────────────────────────────
193  ps aux         1        1s
213  curl -S ...  127      49ms

> cat data.json | json .users
name   age  role
──────────────────
Alice  30   admin
Bob    25   user
```

## Headless mode

For Attyx integration — Xyron runs as a backend, Attyx renders the UI:

```bash
xyron --headless        # binary protocol on stdin/stdout
xyron --headless-json   # JSON debug mode
```

Binary protocol: `[4B payload_len LE][1B msg_type][payload...]` — see `docs/headless-protocol.md`.

## Key bindings

### Emacs (default)

| Key | Action |
|-----|--------|
| Ctrl+A / Ctrl+E | Home / End |
| Ctrl+B / Ctrl+F | Left / Right |
| Alt+B / Alt+F | Word back / forward |
| Ctrl+K | Kill to end of line |
| Ctrl+U | Kill to start of line |
| Ctrl+W | Kill word backward |
| Alt+D | Kill word forward |
| Ctrl+Y | Yank (paste kill buffer) |
| Ctrl+T | Transpose characters |
| Ctrl+R | Fuzzy history search |
| Ctrl+L | Clear screen |
| Tab | Completion picker |
| Ctrl+P / Ctrl+N | History up / down |

### Vim (opt-in via `xyron.vim_mode(true)`)

Normal mode: `h l w b 0 $ x D dw db dd i a I A`

## Documentation

- [`docs/lua-api.md`](docs/lua-api.md) — Full Lua API reference
- [`docs/headless-protocol.md`](docs/headless-protocol.md) — Binary protocol specification
- [`docs/block-model.md`](docs/block-model.md) — Command block lifecycle
- [`docs/structured-output.md`](docs/structured-output.md) — Table renderer and builtins
- [`docs/attyx-integration.md`](docs/attyx-integration.md) — Three integration levels
- [`docs/history-queries.md`](docs/history-queries.md) — Structured history and replay

## License

MIT
