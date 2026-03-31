# Xyron Headless Protocol

## Overview

Xyron's headless mode (`xyron --headless`) turns the shell into a backend runtime controlled via a binary protocol on stdin/stdout. This is how Attyx communicates with Xyron when acting as its frontend.

## Transport

- **stdin**: Attyx sends requests (binary frames)
- **stdout**: Xyron sends responses + events (binary frames)
- **stderr**: unused in headless mode (no OSC events)

## Frame format

```
[4 bytes: payload_len, u32 little-endian]
[1 byte:  msg_type]
[payload_len bytes: payload]
```

Matches Attyx daemon IPC framing. Max payload: 64KB.

## Payload encoding

Values are written sequentially with no delimiters:

- **String**: `[2 bytes: u16 LE length][length bytes: UTF-8 data]`
- **Integer**: `[8 bytes: i64 LE]`
- **Byte**: `[1 byte: u8]`

## Startup sequence

1. Attyx spawns `xyron --headless`
2. Xyron initializes runtime (env, history, Lua config, etc.)
3. Xyron emits `evt_ready` (session_id, version)
4. Xyron emits `evt_prompt` (initial prompt with ANSI colors)
5. Attyx sends `init_session` to get capabilities
6. Normal request/event flow begins

## Request types (Attyx → Xyron)

### init_session (0x01)

Handshake. Returns session metadata.

**Request**: `req_id:i64`

**Response**: `req_id:i64, session_id:str, name:str, version:str, history_count:i64`

### run_command (0x02)

Execute a command string through the full Xyron pipeline.

**Request**: `req_id:i64, input:str`

**Response**: `req_id:i64, exit_code:u8, duration_ms:i64, output:str`

Between request and response, Xyron emits:
- `evt_command_started`
- `evt_output_chunk` (one or more)
- `evt_command_finished`
- `evt_prompt` (updated prompt after execution)

### send_input (0x03)

Send raw bytes to the active foreground process's stdin.

**Request**: `req_id:i64, data:str`

### interrupt (0x04)

Send SIGINT to the active foreground process.

**Request**: `req_id:i64`

### list_jobs (0x07)

Query current job state.

**Request**: `req_id:i64`

**Response**: `req_id:i64, count:i64, [per job: id:i64, raw:str, state:u8, exit_code:u8]`

State values: 0=running, 1=stopped, 2=completed

### get_history (0x08)

Query recent history from SQLite.

**Request**: `req_id:i64, limit:i64`

**Response**: `req_id:i64, count:i64, [per entry: id:i64, raw:str, cwd:str, exit_code:i64, started_at:i64]`

### get_shell_state (0x09)

Current runtime state snapshot.

**Request**: `req_id:i64`

**Response**: `req_id:i64, cwd:str, last_exit_code:u8, job_count:i64`

### get_prompt (0x0B)

Get the current prompt string with ANSI colors.

**Request**: `req_id:i64`

**Response**: `req_id:i64, text:str, visible_len:i64, line_count:i64`

The `text` field contains the full ANSI-colored prompt. `visible_len` is the display width (excluding escape sequences). `line_count` is 1 for single-line, 2+ for multiline prompts.

### resize (0x0C)

Notify Xyron of terminal size change.

**Request**: `rows:i64, cols:i64`

## Event types (Xyron → Attyx)

Events are fire-and-forget — no request ID.

### evt_ready (0xAA)

Emitted once on startup.

**Payload**: `session_id:str, version:str`

### evt_prompt (0xAB)

Emitted after startup and after each command completes.

**Payload**: `text:str, visible_len:i64, line_count:i64`

### evt_command_started (0xA0)

**Payload**: `group_id:i64, input:str, timestamp:i64`

### evt_command_finished (0xA1)

**Payload**: `group_id:i64, input:str, exit_code:u8, duration_ms:i64, timestamp:i64`

### evt_output_chunk (0xA2)

Streamed during command execution. May arrive multiple times.

**Payload**: `stream:str, data:str, timestamp:i64`

`stream` is `"stdout"` or `"stderr"`.

### evt_block_started (0xAC) / evt_block_finished (0xAD)

Reserved for command block lifecycle. Will carry block_id for Attyx block UI.

## Error handling

- If a request fails, Xyron sends `resp_error` (0x81) with `req_id:i64, message:str`
- Unknown request types get `resp_error` with "unknown request"
- If Attyx disconnects (stdin EOF), Xyron exits cleanly

### get_completions (0x10)

Get completion candidates for a buffer at a cursor position. Uses Xyron's full completion engine (builtins, aliases, lua commands, PATH executables, filesystem, env vars, help-derived flags).

**Request**: `req_id:i64, buffer:str, cursor:i64`

**Response**:
```
req_id:      i64
context_kind: u8    # 0=command, 1=argument, 2=flag, 3=env_var, 4=redirect_target, 5=none
word_start:   i64   # byte offset where the completing word starts
word_end:     i64   # byte offset where the completing word ends (usually = cursor)
count:        i64   # number of candidates

# repeated `count` times (capped at 50):
  text:        str   # candidate text (what gets inserted)
  description: str   # help text (may be empty)
  kind:        u8    # 0=builtin, 1=lua_cmd, 2=alias, 3=external_cmd,
                     # 4=file, 5=directory, 6=env_var, 7=flag
  score:       i64   # sort score (higher = better match)
```

Candidates are pre-sorted by score (fuzzy match quality + kind priority). Attyx should display them in the order received.

**Context kinds** determine what's being completed:
- `command` (0): first word — builtins, aliases, lua commands, PATH executables
- `argument` (1): after a command — filesystem paths + help-derived flags/subcommands
- `flag` (2): starts with `-` — help-derived flags + filesystem
- `env_var` (3): starts with `$` — environment variable names
- `redirect_target` (4): after `>`, `<`, `2>` — filesystem paths
- `none` (5): no completion context

**Candidate kinds** for styling:
- `builtin` (0): cyan — shell built-in command
- `lua_cmd` (1): magenta — Lua-defined custom command
- `alias` (2): yellow — shell alias
- `external_cmd` (3): green — found in PATH or help-derived subcommand
- `file` (4): default — regular file
- `directory` (5): blue — directory (text includes trailing `/`)
- `env_var` (6): yellow — environment variable (text includes `$` prefix)
- `flag` (7): cyan — command flag from help introspection

**Word replacement**: when the user selects a candidate, replace `buffer[word_start..word_end]` with the candidate text. Append a space after non-directory candidates.

### get_ghost (0x11)

Get ghost text suggestion from command history. Returns the best prefix-matching history entry for inline display.

**Request**: `req_id:i64, buffer:str`

**Response**:
```
req_id:         i64
has_suggestion: u8    # 1 if suggestion found, 0 if not

# only if has_suggestion == 1:
  suggestion:   str   # full command string (includes the typed prefix)
```

The suggestion always starts with the buffer content (prefix match). Ghost text to display is `suggestion[buffer.len..]`. The user accepts with Right arrow.

Suggestions are ranked by fuzzy score + recency (newer commands win ties).

## Example session (Python)

```python
import struct, subprocess

proc = subprocess.Popen(['xyron', '--headless'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE)

def read_frame(proc):
    hdr = proc.stdout.read(5)
    plen = struct.unpack('<I', hdr[:4])[0]
    mtype = hdr[4]
    payload = proc.stdout.read(plen)
    return mtype, payload

def send_frame(proc, mtype, payload):
    hdr = struct.pack('<IB', len(payload), mtype)
    proc.stdin.write(hdr + payload)
    proc.stdin.flush()

# Read ready event
mtype, payload = read_frame(proc)  # 0xAA

# Run a command
req = struct.pack('<q', 1) + struct.pack('<H', 7) + b'echo hi'
send_frame(proc, 0x02, req)

# Read events until response
while True:
    mtype, payload = read_frame(proc)
    if mtype == 0x80:  # success response
        break
```
