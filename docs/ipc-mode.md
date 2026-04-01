# IPC Mode (`--ipc`)

Interactive shell with a Unix domain socket side channel. Xyron handles all UI rendering (prompt, overlay, blocks, ghost text) through the PTY. External tools (Attyx, scripts) connect to the socket to query shell state using the binary protocol.

```sh
xyron --ipc                    # Start with IPC enabled (auto-enabled when ATTYX=1)
# Socket created at $XDG_RUNTIME_DIR/xyron-{pid}.sock
# Path emitted as OSC 7339 ipc_ready event
```

## Architecture

```
External tool (Attyx, scripts)
├── PTY ←→ Xyron interactive (all ANSI rendering)
├── stderr ← OSC 7339 events (lifecycle, state changes)
└── Unix socket ← binary protocol queries (same as headless)
```

## Supported IPC requests

Same binary protocol as headless mode:

| Message | Description |
|---------|-------------|
| `get_completions` (0x10) | Completion candidates for buffer+cursor |
| `get_ghost` (0x11) | Ghost text suggestion from history |
| `get_shell_state` (0x09) | CWD, last exit code, job count |
| `get_history` (0x08) | Recent history entries |
| `query_history` (0x0D) | Filtered history search |
| `list_jobs` (0x07) | Active job table |

## Attyx connection handshake

1. Xyron creates socket, emits OSC on stderr:
   ```
   \x1b]7339;xyron:{"event":"ipc_ready","socket":"/tmp/xyron-{pid}.sock"}\x07
   ```
2. Attyx connects to Xyron's socket and sends `handshake` (0x12):
   ```
   socket_path:str    — Attyx's IPC socket path
   pane_id:str        — pane/tab ID this shell runs in
   ```
3. Xyron responds with:
   ```
   socket_path:str    — Xyron's socket (confirmation)
   name:str           — "xyron"
   version:str        — "0.1.0"
   ```
4. Both sides store each other's socket. Bidirectional IPC is ready.

## Completion overlay protocol

When Attyx is connected, Xyron delegates overlay rendering to Attyx instead of drawing ANSI overlays in the terminal.

### Xyron → Attyx (events over IPC socket)

| Code | Event | Payload |
|------|-------|---------|
| 0xB0 | `evt_overlay_show` | `selected:i64, scroll:i64, total:i64, visible_count:i64`, then per candidate: `text:str, desc:str, kind:u8` |
| 0xB1 | `evt_overlay_update` | Same format — sent on selection/filter changes |
| 0xB2 | `evt_overlay_dismiss` | (empty) — remove overlay |

**Candidate kind values:** 0=builtin, 1=lua_cmd, 2=alias, 3=external_cmd, 4=file, 5=directory, 6=env_var, 7=flag

### Attyx → Xyron (requests over Xyron's IPC socket)

| Code | Request | Payload |
|------|---------|---------|
| 0x13 | `overlay_select` | `index:i64` — user picked completion at this index |
| 0x14 | `overlay_dismiss` | (empty) — user dismissed via Attyx UI |

### Flow

1. User types → Xyron gathers completions → sends `evt_overlay_show` → Attyx renders native overlay
2. User continues typing → Xyron sends updated `evt_overlay_show` → Attyx re-renders
3. User navigates (up/down/tab) → Xyron sends `evt_overlay_show` with updated `selected`
4. User picks completion in Attyx → Attyx sends `overlay_select` with index → Xyron inserts it
5. Dismiss (Escape, click outside) → either side sends dismiss → overlay removed

When `attyx_connected = false`, Xyron falls back to terminal-based ANSI overlay rendering.
