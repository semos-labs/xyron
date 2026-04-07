# Xyron Lua API

## Config file

`~/.config/xyron/config.lua` (or `$XDG_CONFIG_HOME/xyron/config.lua`)

Loaded on shell startup. Errors are reported but don't prevent the shell from starting.

## API reference

All functions are on the global `xyron` table.

### Environment

```lua
xyron.getenv("PATH")           -- returns string or nil
xyron.setenv("EDITOR", "vim")  -- sets env var (inherited by children)
xyron.unsetenv("FOO")          -- removes env var
xyron.cwd()                    -- returns current working directory
```

### Commands and aliases

```lua
-- Custom command (callable from shell like a builtin)
xyron.command("greet", function(args)
    print("Hello, " .. (args[1] or "world") .. "!")
    return 0  -- exit code
end)

-- Alias (text substitution before parsing)
xyron.alias("ll", "ls -la")
xyron.alias("gs", "git status")

-- Run a command via /bin/sh
local result = xyron.exec("ls -la /tmp")
print(result.exit_code)
```

### Hooks

```lua
xyron.on("on_command_start", function(data)
    -- data.group_id, data.raw, data.cwd, data.timestamp_ms
end)

xyron.on("on_command_finish", function(data)
    -- data.group_id, data.raw, data.cwd
    -- data.exit_code, data.duration_ms, data.timestamp_ms
end)

xyron.on("on_cwd_change", function(data)
    -- data.old_cwd, data.new_cwd, data.timestamp_ms
end)

xyron.on("on_job_state_change", function(data)
    -- data.job_id, data.group_id, data.raw
    -- data.old_state, data.new_state, data.timestamp_ms
end)
```

### Prompt configuration

```lua
xyron.prompt.init({
    "cwd",           -- ~/path (bold blue)
    " ",             -- literal text
    "git",           -- branch from .git/HEAD (magenta)
    "jobs",          -- ⚙N when background jobs exist (yellow)
    "spacer",        -- fills remaining width (pushes next items right)
    function()       -- custom Lua segment (returns string)
        return os.date("%H:%M")
    end,
    "\n",            -- newline for multiline prompt
    "status",        -- ✘N on non-zero exit (red)
    "duration",      -- "took Ns" for commands >1s (yellow)
    "symbol",        -- > (green) or > (red on error) or < (yellow in vim normal)
    " ",
})
```

Segments return empty string when not applicable (e.g., `jobs` hidden when no jobs).

### Powerline prompt

Segments can be tables with `fg` and `bg` colors. Pass a `separator` in the options to enable powerline-style transitions between segments.

```lua
xyron.prompt.init({
    { "cwd", fg = "white", bg = "blue" },
    { "git", fg = "white", bg = "magenta" },
    { "duration", fg = "black", bg = "yellow" },
    "\n",
    "symbol", " ",
}, { separator = "" })  -- or "" for rounded style
```

Available colors: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, and bright variants (`bright_black`, `bright_red`, etc.). These map to the terminal's base 16 palette, so they respect the user's theme.

Segments without `bg` on a powerline line render normally (no background or separator). This lets you mix powerline segments with plain ones (e.g., `symbol` on the second line).

Custom widgets and Lua functions also support powerline colors:

```lua
xyron.prompt.register("clock", function()
    return os.date("%H:%M")
end)

xyron.prompt.init({
    { "cwd", fg = "white", bg = "blue" },
    { "clock", fg = "black", bg = "green" },
    "\n",
    "symbol", " ",
}, { separator = "" })
```

### Vim mode

```lua
xyron.vim_mode(true)  -- enable vim-style modal editing
```

Insert mode: normal typing. Normal mode: h/l/w/b/0/$/x/dw/db/dd/D/i/a/I/A.

### Completion

```lua
xyron.completion(true)                          -- enable (default)
xyron.completion(false)                         -- disable all completions
xyron.completion(true, { on_demand = true })    -- only on Tab/Ctrl+Space (no as-you-type)
```

When enabled (default), completions trigger as-you-type in Attyx or via Tab/Ctrl+Space in any terminal. `on_demand` disables as-you-type — completions only appear when explicitly triggered.

Keys: Tab/Ctrl+Space (trigger), Ctrl+P/N or arrows (navigate), Enter/Tab/Ctrl+Y (accept), Esc (cancel).

### Attyx integration

```lua
if xyron.is_attyx() then
    -- Running inside Attyx terminal
end

if xyron.has_attyx_ui() then
    -- Native UI available (popup, picker)
    xyron.popup("Hello!", "My Title")
    local choice = xyron.pick({"option1", "option2"}, "Choose")
end
```

### Introspection

```lua
local blk = xyron.last_block()
if blk then
    print(blk.id)          -- block ID
    print(blk.input)       -- command string
    print(blk.exit_code)   -- 0-255
    print(blk.duration_ms) -- milliseconds
    print(blk.status)      -- "success", "failed", "interrupted", "running"
    print(blk.cwd)         -- working directory
end
```

### Resolution order

When the user types a command:
1. Builtins (`cd`, `ls`, `ps`, `env`, `history`, etc.)
2. Aliases (`xyron.alias()`)
3. Lua custom commands (`xyron.command()`)
4. External commands (PATH search)

## Example config

```lua
-- Environment
xyron.setenv("EDITOR", "vim")
xyron.setenv("PAGER", "less")

-- Aliases
xyron.alias("ll", "ls -la")
xyron.alias("gs", "git status")
xyron.alias("gp", "git push")

-- Custom command
xyron.command("mkcd", function(args)
    if #args == 0 then
        io.stderr:write("usage: mkcd <dir>\n")
        return 1
    end
    os.execute("mkdir -p " .. args[1])
    xyron.exec("cd " .. args[1])
    return 0
end)

-- Prompt
xyron.prompt.init({
    "cwd", " ", "git", "\n", "symbol", " ",
})

-- Notify on failure
xyron.on("on_command_finish", function(data)
    if data.exit_code ~= 0 then
        io.stderr:write("✘ exit " .. data.exit_code .. "\n")
    end
end)
```
