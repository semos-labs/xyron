# Structured Output

## Overview

Xyron builtins return structured data rendered as colored tables via `rich_output.Table`. This replaces the plain text output of traditional shells with typed, aligned, terminal-width-aware tables.

## Table renderer (`rich_output.zig`)

### Features

- Auto-calculated column widths
- Terminal width detection (ioctl TIOCGWINSZ)
- Column caps at 60% of terminal width
- Automatic truncation with `...` for overflowing cells
- Newlines in cell content replaced with spaces
- Header row in bold white with `─` separator line
- Per-column alignment (left or right)
- Per-column default color + per-cell color override
- Periodic flushing for large tables

### API

```zig
var tbl = rich.Table{};
tbl.addColumn(.{ .header = "name", .color = "\x1b[36m" });
tbl.addColumn(.{ .header = "size", .align_ = .right, .color = "" });

const r = tbl.addRow();
tbl.setCell(r, 0, "file.txt");
tbl.setCellColor(r, 1, "1.2K", "\x1b[32m");  // per-cell color

tbl.render(stdout);
```

### Color helpers

```zig
rich.fileTypeColor(kind)   // dir=bold blue, link=cyan, etc.
rich.sizeColor(bytes)      // small=green, medium=yellow, large=red
rich.formatSize(buf, bytes) // 1.2K, 3.5M, etc.
```

## Builtin output formats

### ls [-la] [path]

| Flag | Columns |
|------|---------|
| (none) | name |
| `-l` | permissions, name, size |
| `-a` | includes dotfiles |
| `-la` | permissions + dotfiles + size |

Colors: directories=bold blue, symlinks=bold cyan, executables=default. Sizes: small=green, medium=yellow, large=red.

Unknown flags (e.g., `-R`, `-t`) fall through to external `/bin/ls`.

### env

Columns: `variable` (bold cyan), `value` (white, truncated at 80 chars). Sorted alphabetically by key.

### history [N]

Columns: `#` (dim, right-aligned), `command`, `exit` (green for 0, red for non-zero). Default limit: 25.

### jobs

Columns: `id` (bold white, right-aligned), `state` (green=running, yellow=stopped, dim=completed), `command`.

### alias

Columns: `alias` (bold yellow), `command` (white). Only shown when called with no arguments.

### ps [args]

Runs `/bin/ps` with controlled format (`-eo pid,user,%cpu,%mem,stat,command` by default). Parses output into table. PID=cyan, %CPU/%MEM=yellow.

### json [path]

Pipe target for JSON formatting:

```sh
cat data.json | json           # render first level
curl api | json .data.users    # nested path access
curl api | json .items.[0]     # array index
curl api | json .items.[]      # iterate array
```

Rendering rules:
- **Object** → key / value / type table
- **Array of objects** → columns from first object's keys
- **Array of primitives** → # / value / type table
- **Primitive** → plain text

Type colors: string=green, number=cyan, boolean=yellow, null=dim, object=magenta `{...}`, array=blue `[N items]`.

## Adding new structured builtins

1. Create `src/builtins/mycommand.zig`
2. Import `rich = @import("../rich_output.zig")`
3. Build a `rich.Table`, add columns, add rows with data
4. Call `tbl.render(stdout)`
5. Register in `src/builtins/mod.zig` (add to `builtin_names`, import, dispatch)
6. Add completion description in `src/complete_providers.zig`
