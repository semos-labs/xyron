# Attyx Integration

## Detection

Xyron detects Attyx via the `ATTYX=1` environment variable (set by Attyx when spawning shells). Additional env vars: `ATTYX_PID` (Attyx process ID).

## Three integration levels

### Level 1: Event emission (passive)

When `ATTYX=1`, Xyron emits structured lifecycle events as OSC escape sequences on stderr:

```
\x1b]7339;xyron:<json>\x07
```

Events are fire-and-forget. Attyx's terminal parser intercepts OSC 7339 sequences. They're invisible in non-Attyx terminals.

**Events emitted:**
- `command_group_started` — group_id, raw input, cwd, timestamp
- `command_step_started` — group_id, step_id, argv, cwd, timestamp
- `command_step_finished` — group_id, step_id, exit_code, duration_ms, timestamp
- `command_group_finished` — group_id, exit_code, duration_ms, timestamp
- `cwd_changed` — old_cwd, new_cwd, timestamp (+ standard OSC 7)
- `env_changed` — kind (set/unset), key, value, timestamp
- `history_entry_recorded` — command_id, raw, cwd, exit_code, duration_ms, timestamp
- `history_initialized` — total_entries, timestamp
- `job_started` — job_id, group_id, raw, cwd, timestamp
- `job_finished` — job_id, exit_code, duration_ms, timestamp
- `job_suspended` — job_id, group_id, timestamp
- `job_resumed` — job_id, group_id, mode, timestamp

### Level 2: Native UI bridge (active)

Xyron can invoke Attyx IPC commands for native UI:

```zig
// attyx_bridge.zig
bridge.popup(content, title, stdout, allocator)  // attyx popup
bridge.picker(items, title, stdout, allocator)    // attyx popup with fzf
bridge.inspect(kind, content, stdout, allocator)  // attyx popup with less
```

Falls back to terminal text output when outside Attyx.

**Lua access:**
```lua
xyron.popup("text", "title")
local choice = xyron.pick({"a", "b", "c"}, "Choose")
```

### Level 3: Headless runtime (full backend)

`xyron --headless` runs Xyron as a pure backend. Attyx becomes the frontend.

See [headless-protocol.md](headless-protocol.md) for the full binary protocol specification.

**Key flow:**
1. Attyx spawns `xyron --headless`
2. Reads `evt_ready` + `evt_prompt` from stdout
3. Sends `run_command` requests
4. Receives `evt_command_started` → `evt_output_chunk`* → `evt_command_finished` → `evt_prompt`
5. Renders block-based UI from structured events

## Building Attyx block UI

For each command executed through the headless protocol:

1. **Block start**: `evt_command_started` → create visual block
2. **Output**: `evt_output_chunk` events (stdout/stderr streams) → append to block
3. **Block end**: `evt_command_finished` → finalize with exit code + duration
4. **Prompt**: `evt_prompt` → render before the next input area

The prompt contains full ANSI color codes and can be rendered directly. `visible_len` tells you the display width for cursor positioning. `line_count` tells you how many terminal rows the prompt occupies.

## Terminal state

- Xyron manages raw/cooked terminal mode
- Before spawning children, Xyron restores cooked mode so interactive programs (vim, less) work
- After children exit, raw mode is re-enabled
- Terminal attributes are saved once (first `enableRawMode`) and never re-saved from a child's corrupted state
- SIGTSTP, SIGINT, SIGTTIN, SIGTTOU are handled by the shell (not ignored via SIG_IGN — children can reset to SIG_DFL)
