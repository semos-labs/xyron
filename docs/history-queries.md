# History Queries, Replay, and Workflow Primitives

## Overview

Xyron's history system is a structured, queryable runtime dataset backed by SQLite. Every command execution is recorded with metadata (input, cwd, exit code, duration, timestamp). Users, Lua scripts, and Attyx can search, filter, inspect, and replay commands.

## SQLite schema

```sql
commands (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    raw_input TEXT NOT NULL,
    cwd TEXT NOT NULL,
    started_at INTEGER NOT NULL,    -- unix ms
    finished_at INTEGER NOT NULL,   -- unix ms
    duration_ms INTEGER NOT NULL,
    exit_code INTEGER NOT NULL,
    interrupted INTEGER NOT NULL DEFAULT 0,
    session_id TEXT NOT NULL
)
```

Indexed on `started_at` and `cwd`.

## Shell commands

### history [N]

Recent entries (default 25). Table with: #, command, exit code (green/red), duration.

### history search \<text\>

Filter by command text (case-sensitive substring match). Returns up to 25 results.

### history failed [N]

Only commands with non-zero exit code. Default limit 25.

### history show \<id\>

Detailed field/value view for one entry: id, command, cwd, exit_code, duration, started_at.

### history rerun \<id|last|failed\>

Replay a prior command through the normal execution pipeline.

- `history rerun 42` — replay entry #42
- `history rerun last` — replay most recent command
- `history rerun failed` — replay last failed command

Replay creates a new command block and history entry. It runs in the current environment and cwd — it's not time travel.

### history cwd [path]

Commands executed in a specific directory. Defaults to current working directory.

### history slow [min_ms]

Commands that took longer than the threshold. Default: 1000ms (1 second).

## Query model

The `HistoryQuery` struct supports these filters (all optional, combinable):

| Field | Type | Description |
|-------|------|-------------|
| `text_contains` | string | Substring match on command text (LIKE %text%) |
| `cwd_filter` | string | Exact CWD match |
| `only_failed` | bool | exit_code != 0 |
| `only_success` | bool | exit_code == 0 |
| `only_interrupted` | bool | interrupted flag set |
| `since_ms` | i64 | Only entries after this timestamp (unix ms) |
| `min_duration_ms` | i64 | Only entries slower than this |
| `limit` | usize | Max results (default 25, max 100) |

Results are always returned newest-first.

## Lua API

### xyron.history_query(filters) → array

```lua
-- All recent
local all = xyron.history_query({})

-- Failed commands
local fails = xyron.history_query({ failed = true, limit = 5 })

-- Search by text
local gits = xyron.history_query({ text = "git push" })

-- Commands in a specific directory
local here = xyron.history_query({ cwd = "/Users/me/project" })

-- Results are arrays of tables
for _, entry in ipairs(gits) do
    print(entry.id)          -- history ID
    print(entry.input)       -- command string
    print(entry.exit_code)   -- 0-255
    print(entry.duration_ms) -- milliseconds
    print(entry.cwd)         -- working directory
end
```

### xyron.history_replay(id) → boolean

```lua
-- Replay by ID
xyron.history_replay(42)

-- Replay last failed command
local fails = xyron.history_query({ failed = true, limit = 1 })
if #fails > 0 then
    xyron.history_replay(fails[1].id)
end
```

Returns `true` if the entry was found and scheduled for replay, `false` otherwise. The command executes after the current Lua call returns.

## Headless protocol

### query_history (0x0D)

**Request**: `req_id:i64, text_filter:str, cwd_filter:str, only_failed:u8, limit:i64`

**Response**: `req_id:i64, count:i64, [per entry: id:i64, raw:str, cwd:str, exit_code:i64, duration_ms:i64, started_at:i64]`

### replay_command (0x0E)

**Request**: `req_id:i64, history_id:i64`

**Response**: `req_id:i64, success:u8`

Triggers normal command execution — Attyx will receive the usual `evt_command_started` → `evt_output_chunk` → `evt_command_finished` → `evt_prompt` event flow.

## Workflow patterns

### Rerun last failed in Lua hook

```lua
xyron.command("retry", function()
    local fails = xyron.history_query({ failed = true, limit = 1 })
    if #fails > 0 then
        xyron.history_replay(fails[1].id)
    else
        print("No failed commands")
    end
    return 0
end)
```

### Auto-retry on failure

```lua
xyron.on("on_command_finish", function(data)
    if data.exit_code ~= 0 and data.raw:match("^npm test") then
        print("Test failed — retrying in 3s...")
        os.execute("sleep 3")
        -- Schedule replay
        local results = xyron.history_query({ text = data.raw, limit = 1 })
        if #results > 0 then xyron.history_replay(results[1].id) end
    end
end)
```

### Project-scoped history

```lua
xyron.command("project-history", function()
    local cwd = xyron.cwd()
    local entries = xyron.history_query({ cwd = cwd, limit = 20 })
    for _, e in ipairs(entries) do
        local status = e.exit_code == 0 and "✓" or "✗"
        print(string.format("%s #%d %s", status, e.id, e.input))
    end
    return 0
end)
```
