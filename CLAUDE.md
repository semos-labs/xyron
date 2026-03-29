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
- **Every big feature must be well documented** in this file and in `docs/`. Especially integration-facing features like the headless protocol, block model, structured output, and Lua API.

## XDG directories

- **Config**: `$XDG_CONFIG_HOME/xyron/` (default `~/.config/xyron/`)
  - `config.lua` — Lua config entry point, loaded on startup
- **Data**: `$XDG_DATA_HOME/xyron/` (default `~/.local/share/xyron/`)
  - `history.db` — SQLite command history + help cache (see `docs/history-queries.md`)

## Three operation modes

1. **Classic shell** — `xyron` — normal interactive shell in any terminal
2. **Enhanced shell** — `xyron` inside Attyx — shell + native UI bridge (`attyx popup`, etc.)
3. **Headless runtime** — `xyron --headless` — backend for Attyx frontend, binary protocol on stdin/stdout

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

## Code style

- Idiomatic Zig — follow stdlib conventions
- **Modular and lean** — small focused functions, clear separation of concerns
- **Well commented** — explain intent and non-obvious logic
- Prefer explicit over clever
- **Stack size awareness** — large arrays (>10KB) should be heap-allocated or kept small. The Shell struct lives on the stack.

## What NOT to do

- No POSIX compatibility layer — this is intentional
- No bash/sh syntax support in the shell language itself
- Don't add features beyond what's asked
- Don't create README or docs unless requested
- Don't store `*pointer` to fields of a struct that gets returned by value from `init()` — the struct moves and the pointer dangles. Use copies or set pointers after the struct is at its final location.

---

# Architecture Reference

## Source layout

```
src/
  main.zig              Entrypoint — mode dispatch (shell/headless)
  shell.zig             REPL loop, orchestrates everything
  term.zig              Raw terminal mode (tcgetattr/tcsetattr)
  keys.zig              Key event types + escape sequence parser
  editor.zig            Line buffer with cursor, vim mode
  input.zig             readLine loop: keys → editor → display → ghost text
  prompt.zig            Prompt engine with modular segments
  token.zig             Lexer (words, pipes, redirects, &, quotes)
  ast.zig               AST types (Pipeline, SimpleCommand, Redirect)
  parser.zig            Tokens → AST (inline env assignments, quoted flags)
  expand.zig            $NAME and ~ expansion
  planner.zig           AST → ExecutionPlan (step IDs, pipe wiring)
  executor.zig          fork+dup2+exec, process groups, WUNTRACED
  environ.zig           Shell environment (wraps EnvMap, toEnvp for children)
  types.zig             IdGenerator, timestampMs
  builtins.zig          Thin re-export from builtins/mod.zig
  builtins/
    mod.zig             Dispatcher + isBuiltin/isProcessOnly
    cd.zig pwd.zig exit.zig export.zig unset.zig exec.zig
    env.zig             Structured table output (sorted, colored)
    ls.zig              Structured directory listing (-l, -a)
    ps.zig              Structured process listing (captures /bin/ps)
    history.zig         Structured history table
    alias.zig           Alias table
    jobs.zig            Job table (id, state, command)
    fg.zig bg.zig
    json.zig            JSON pipe target — parse + table render
    which.zig type.zig
    popup.zig inspect.zig
    migrate.zig         Bash→Xyron migration assistant
  highlight.zig         Syntax highlighting (inline tokenizer, command cache)
  complete.zig          Interactive picker (fuzzy filter, tab/shift-tab cycle)
  complete_providers.zig  Builtins, lua, PATH, filesystem, env vars, help flags
  complete_help.zig     --help introspection + SQLite cache
  complete_display.zig  (merged into complete.zig)
  fuzzy.zig             Fuzzy matcher (ported from Attyx)
  history.zig           In-memory history buffer (circular, up/down nav)
  history_db.zig        SQLite history (commands + command_steps tables)
  history_search.zig    Ctrl+R full-screen history search
  sqlite.zig            Thin SQLite C wrapper
  jobs.zig              Job tracking (running/stopped/completed, WNOHANG reap)
  block.zig             Command block model (lifecycle, output association)
  aliases.zig           Alias registry
  attyx.zig             Attyx event emission (OSC 7339 on stderr)
  attyx_bridge.zig      Native Attyx UI bridge (picker, popup, inspect)
  protocol.zig          Binary protocol for headless mode
  headless.zig          Headless runtime loop
  lua_api.zig           Lua VM + xyron.* API surface
  lua_hooks.zig         Hook registry (on_command_start/finish, cwd, jobs)
  lua_commands.zig      Custom Lua command registry
  environ.zig           Shell environment state
  path_search.zig       PATH-based command resolution
  rich_output.zig       Table renderer (columns, alignment, colors, truncation)
  json_parser.zig       Minimal JSON parser (objects, arrays, types)
  migrate.zig           Bash/sh analyzer + converter engine
  expand.zig            Variable + tilde expansion
```

---

# Headless Protocol

Binary wire format matching Attyx IPC: `[4B payload_len LE][1B msg_type][payload...]`

## Payload encoding

- Strings: `[2B u16 LE length][bytes...]`
- Integers: `[8B i64 LE]`
- Bytes: `[1B u8]`

## Message types

### Requests (Attyx → Xyron, 0x01–0x1F)

| Code | Name | Payload |
|------|------|---------|
| 0x01 | init_session | req_id:i64 |
| 0x02 | run_command | req_id:i64, input:str |
| 0x03 | send_input | req_id:i64, data:str |
| 0x04 | interrupt | req_id:i64 |
| 0x07 | list_jobs | req_id:i64 |
| 0x08 | get_history | req_id:i64, limit:i64 |
| 0x09 | get_shell_state | req_id:i64 |
| 0x0B | get_prompt | req_id:i64 |
| 0x0C | resize | rows:i64, cols:i64 |

### Responses (Xyron → Attyx, 0x80–0x8F)

| Code | Name | Payload |
|------|------|---------|
| 0x80 | resp_success | req_id:i64, ...data |
| 0x81 | resp_error | req_id:i64, message:str |

### Events (Xyron → Attyx, 0xA0–0xBF)

| Code | Name | Payload |
|------|------|---------|
| 0xA0 | evt_command_started | group_id:i64, input:str, timestamp:i64 |
| 0xA1 | evt_command_finished | group_id:i64, input:str, exit_code:u8, duration:i64, timestamp:i64 |
| 0xA2 | evt_output_chunk | stream:str("stdout"/"stderr"), data:str, timestamp:i64 |
| 0xA3 | evt_cwd_changed | (reserved) |
| 0xA4 | evt_env_changed | (reserved) |
| 0xA5 | evt_job_started | (reserved) |
| 0xA6 | evt_job_finished | (reserved) |
| 0xA7 | evt_job_suspended | (reserved) |
| 0xAA | evt_ready | session_id:str, version:str |
| 0xAB | evt_prompt | text:str, visible_len:i64, line_count:i64 |
| 0xAC | evt_block_started | (reserved) |
| 0xAD | evt_block_finished | (reserved) |

### Response payloads

**init_session response**: req_id:i64, session_id:str, name:str("xyron"), version:str, history_count:i64

**run_command response**: req_id:i64, exit_code:u8, duration_ms:i64, output:str

**get_prompt response**: req_id:i64, text:str (ANSI-colored), visible_len:i64, line_count:i64

**get_shell_state response**: req_id:i64, cwd:str, last_exit_code:u8, job_count:i64

**list_jobs response**: req_id:i64, count:i64, then per job: id:i64, raw:str, state:u8, exit_code:u8

**get_history response**: req_id:i64, count:i64, then per entry: id:i64, raw:str, cwd:str, exit_code:i64, started_at:i64

---

# Command Block Model

Each command execution produces exactly one Block.

```
Block {
    id: u64             unique, monotonic
    group_id: u64       links to execution plan
    raw_input: [256]u8  command string
    cwd: [256]u8        working directory at execution time
    status: enum        running | success | failed | interrupted
    exit_code: u8       set on completion
    start_ms: i64       timestamp
    end_ms: i64         timestamp (0 until finished)
    is_background: bool
    job_id: u32         links to job table (0 if foreground)
}
```

Lifecycle: `create → running → finish(code) → success/failed` or `→ interrupt() → interrupted`

BlockTable holds up to 32 recent blocks in memory. Auto-compacts old completed blocks.

Attyx reconstructs blocks from events: `evt_block_started` → `evt_output_chunk`* → `evt_block_finished`

---

# Lua API (`xyron.*`)

## Environment

| Function | Description |
|----------|-------------|
| `xyron.getenv(name)` | Get env var → string or nil |
| `xyron.setenv(name, value)` | Set env var |
| `xyron.unsetenv(name)` | Remove env var |
| `xyron.cwd()` | Current working directory |

## Shell control

| Function | Description |
|----------|-------------|
| `xyron.exec(cmd)` | Run command via /bin/sh, returns `{exit_code=N}` |
| `xyron.alias(name, expansion)` | Register alias |
| `xyron.command(name, fn)` | Register custom command |
| `xyron.vim_mode(bool)` | Enable/disable vim editing |

## Hooks

| Function | Description |
|----------|-------------|
| `xyron.on(event, fn)` | Register hook callback |

Events: `on_command_start`, `on_command_finish`, `on_cwd_change`, `on_job_state_change`

Hook payloads are Lua tables with fields like `group_id`, `raw`, `cwd`, `exit_code`, `duration_ms`, `timestamp_ms`.

## Prompt

```lua
xyron.prompt({
    "cwd",           -- tilde-contracted path (bold blue)
    " ",             -- literal text
    "git_branch",    -- from .git/HEAD (magenta)
    "spacer",        -- fills remaining width with spaces
    function() return os.date("%H:%M") end,  -- custom Lua segment
    "\n",            -- newline (multiline prompt)
    "symbol",        -- > green on success, < yellow in vim normal, red on error
    " ",
})
```

Built-in segments: `cwd`, `symbol`, `status`, `duration`, `jobs`, `git_branch`, `spacer`, `"\n"`

## Introspection

| Function | Description |
|----------|-------------|
| `xyron.is_attyx()` | Running inside Attyx? |
| `xyron.has_attyx_ui()` | Native UI available? |
| `xyron.last_block()` | Last command block metadata → `{id, input, exit_code, duration_ms, status, cwd}` |

## Native UI (Attyx only)

| Function | Description |
|----------|-------------|
| `xyron.popup(text, title?)` | Show in Attyx popup or print to terminal |
| `xyron.pick(items, title?)` | Open picker → selected string or nil |

---

# Structured Output

Builtins that return structured data use `rich_output.Table`:

| Command | Columns |
|---------|---------|
| `ls [-la]` | permissions, name (colored by type), size (human-readable) |
| `env` | variable (bold cyan), value (truncated at 80 chars) |
| `history [N]` | #, command, exit code (green/red) |
| `jobs` | id, state (green/yellow/dim), command |
| `alias` | alias (yellow), command |
| `ps [args]` | columns from /bin/ps output, PID cyan, %CPU/%MEM yellow |
| `json [path]` | pipe target — parses JSON, renders typed table |

Table renderer features:
- Auto-calculated column widths
- Terminal width awareness (caps columns, truncates with `...`)
- Newlines in cells replaced with spaces
- Header row with `─` separator
- Per-cell ANSI colors

### JSON command

```sh
curl -sS api.com/users | json              # first level
curl -sS api.com | json .data.users        # nested path
curl -sS api.com | json .items.[0]         # array index
curl -sS api.com | json .items.[]          # iterate array
```

Types preserved with colors: string=green, number=cyan, boolean=yellow, null=dim, object=magenta, array=blue.

Array of objects → columns from first object's keys. Object → key/value/type table.

---

# Attyx Integration

## Event emission (classic/enhanced mode)

When running inside Attyx (`ATTYX=1`), Xyron emits OSC 7339 escape sequences to stderr:

```
\x1b]7339;xyron:<json>\x07
```

Events: `command_group_started`, `command_step_started/finished`, `command_group_finished`, `cwd_changed`, `env_changed`, `history_entry_recorded`, `job_started/finished/suspended/resumed`, `history_initialized`

## Native UI bridge

`attyx_bridge.zig` invokes Attyx CLI for native UI:
- `attyx popup <cmd>` — floating overlay
- Picker uses fzf in popup
- Falls back to terminal text when outside Attyx

---

# SQLite Schema

```sql
-- Command history
commands(id INTEGER PRIMARY KEY, raw_input TEXT, cwd TEXT,
         started_at INTEGER, finished_at INTEGER, duration_ms INTEGER,
         exit_code INTEGER, interrupted INTEGER, session_id TEXT)

command_steps(id INTEGER PRIMARY KEY, command_id INTEGER REFERENCES commands,
              step_index INTEGER, argv TEXT, exit_code INTEGER, duration_ms INTEGER)

-- Help introspection cache
command_help_flags(command TEXT, flag TEXT, description TEXT, cached_at INTEGER,
                   PRIMARY KEY(command, flag))
```

---

# Migration Assistant

```sh
migrate analyze <file>    # compatibility report (structured table)
migrate convert <file>    # auto-convert to Xyron/Lua config
```

Converts: `export` → `xyron.setenv()`, `alias` → `xyron.alias()`, `if/fi` → Lua `if/then/end`, `for/done` → Lua `for/do/end`, `[ -f file ]` → `file_exists()`.

Unsupported constructs get `-- UNSUPPORTED:` comments with explanations. Partial conversions show `-- was:` with the original.
