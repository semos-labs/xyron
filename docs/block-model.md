# Command Block Model

## Overview

Every command execution in Xyron produces exactly one **Block**. Blocks are the fundamental unit for:
- Attyx block-based UI
- Structured history
- Output association
- Lua introspection

## Block structure

```
Block {
    id: u64             Unique, monotonic within session
    group_id: u64       Links to the execution plan's group ID
    raw_input: string   The command as typed (max 256 bytes)
    cwd: string         Working directory at execution time (max 256 bytes)
    status: enum        running | success | failed | interrupted
    exit_code: u8       Set when block finishes (0 = success)
    start_ms: i64       Unix timestamp in milliseconds
    end_ms: i64         Unix timestamp (0 while running)
    is_background: bool Whether this was a background job (&)
    job_id: u32         Links to job table (0 for foreground commands)
}
```

## Lifecycle

```
  create()
     │
     ▼
  running ──────► finish(exit_code) ──► success (code=0) or failed (code>0)
     │
     └──────────► interrupt() ──────► interrupted (code=130)
```

### State transitions

| From | To | Trigger |
|------|----|---------|
| (new) | running | Command starts executing |
| running | success | Command exits with code 0 |
| running | failed | Command exits with code > 0 |
| running | interrupted | Ctrl+Z stops the foreground job |
| running | success/failed | Background job reaped by shell |

## Block table

The shell maintains a `BlockTable` with up to 32 recent blocks in memory. When full, old completed blocks are compacted (keeping the last 16 completed + all running).

## Integration with other systems

### Execution engine

In `shell.zig`'s `executeLine`:
1. Block created with `blocks.create(group_id, input, cwd, background)`
2. Execution proceeds normally
3. On completion: `block.finish(exit_code)`
4. On Ctrl+Z: `block.interrupt()`
5. On background: block stays running, finalized when job reaped

### Jobs

When a background job completes (detected by `reapAndNotify`), the shell finds the associated block by `job_id` and calls `finish(exit_code)`.

### History

Block IDs align with command group IDs from the execution plan. SQLite history entries can be correlated with blocks via the group_id.

### Headless protocol

Events carry block lifecycle:
- `evt_block_started` (0xAC) — block created
- `evt_output_chunk` (0xA2) — output associated with current block
- `evt_block_finished` (0xAD) — block finalized

Attyx reconstructs blocks from these events for its UI.

### Lua

```lua
local blk = xyron.last_block()
-- Returns: {id, input, exit_code, duration_ms, status, cwd}
```

## For Attyx integration

To render block-based UI, Attyx should:

1. Listen for `evt_block_started` → create a visual block container
2. Collect `evt_output_chunk` events → append to the block's output display
3. Listen for `evt_block_finished` → finalize block status, show exit code
4. Use `evt_prompt` to render the prompt before each block
5. Use `get_prompt` request to get the current prompt with ANSI colors

Each block maps to one visual "card" in the terminal: prompt + command + output + status.
