<h1 align="center">🐚 Xyron</h1>

<p align="center">
  <strong>A modern shell built in Zig with Lua scripting</strong>
</p>

<p align="center">
  <a href="https://github.com/semos-labs/xyron/releases/latest"><img src="https://img.shields.io/github/v/release/semos-labs/xyron?label=Release&color=green" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/Zig-0.15-f7a41d?logo=zig&logoColor=white" alt="Zig 0.15">
  <img src="https://img.shields.io/badge/Lua-5.4-2C2D72?logo=lua&logoColor=white" alt="Lua 5.4">
  <img src="https://img.shields.io/badge/SQLite-History-003B57?logo=sqlite&logoColor=white" alt="SQLite">
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License">
</p>

<p align="center">
  <a href="#-features">Features</a>
  &middot;
  <a href="#-install">Install</a>
  &middot;
  <a href="#-configuration">Configuration</a>
  &middot;
  <a href="https://github.com/semos-labs/xyron/issues">Issues</a>
</p>

---

## 💡 About

Xyron is a shell that replaces bash, zsh, and fish. Not POSIX — by design. Lua instead of shell script, SQLite instead of a flat history file, structured tables instead of raw text. Built from scratch in Zig, under 2MB.

Works standalone in any terminal. Works best inside [✨ Attyx](https://github.com/semos-labs/attyx), where it becomes a runtime backend with native UI integration and a binary protocol for headless operation.

---

## 🚀 Features

🌙 **Lua scripting** — Config, hooks, custom commands, automation. `~/.config/xyron/config.lua` is your entire shell setup. No more `.bashrc` spaghetti, no cryptic syntax.

📊 **Structured output** — Builtins like `ls`, `ps`, `env`, `jobs`, and `history` return colored, aligned tables. Pipe JSON through `json` for typed rendering. Query CSV with `csv`. Sort anything with `sort`.

🗄️ **SQLite history** — Every command recorded with exit code, duration, working directory, and timestamp. Search, filter by status, filter by directory, rerun. Full-text fuzzy search with Ctrl+R or the interactive history explorer.

🔍 **Smart completions** — Fuzzy picker with descriptions. Xyron parses `--help` output and caches flag info in SQLite. Path, environment variable, and command completions built in.

👻 **Ghost text** — History-based suggestions appear inline as you type. Right arrow to accept.

⌨️ **Vim mode** — Optional modal editing with `xyron.vim_mode(true)`. Cursor shape and prompt symbol change with mode. Supports `h l w b 0 $ x D dw db dd i a I A` in normal mode.

🎨 **Prompt engine** — Composable segments: cwd, git branch, jobs count, last command duration, custom Lua functions, right-alignment via spacer. Multiline support.

⚙️ **Job control** — Background processes with `&`, Ctrl+Z suspend, `fg`/`bg` resume, process group management.

📂 **Directory jumping** — `j` command for frecency-based directory jumping. Learns from your `cd` usage.

🔐 **Secrets manager** — Built-in encrypted secrets store. Set once, reference in commands and scripts without exposing values in history or environment.

🔎 **Fuzzy finder** — Built-in `fz` command for fuzzy file and directory search. No external dependencies.

🔄 **Migration assistant** — `migrate analyze` scans your existing shell config. `migrate convert` translates bash/zsh aliases, exports, and paths to Lua.

🖥️ **Attyx integration** — When running inside [Attyx](https://github.com/semos-labs/attyx): structured lifecycle events, native popup/picker overlays, IPC socket for external tooling, and a headless binary protocol for block-based terminal UI.

---

## 📦 Install

Requires **Zig 0.15.2+**, **SQLite3**, and **Lua 5.4**.

```bash
# macOS (Homebrew)
brew install zig lua sqlite

# Build and run
zig build
./zig-out/bin/xyron

# Run tests
zig build test
```

---

## ⚡ Configuration

Everything lives in `~/.config/xyron/config.lua`:

```lua
-- Environment
xyron.setenv("EDITOR", "vim")

-- Aliases
xyron.alias("ll", "ls -la")
xyron.alias("gs", "git status")

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

-- Hook: run after every command
xyron.on("on_command_finish", function(data)
    if data.exit_code ~= 0 then
        io.stderr:write("✘ exit " .. data.exit_code .. "\n")
    end
end)
```

---

## 📚 Documentation

Detailed reference docs live in [`docs/`](docs/):

| Doc | Description |
|-----|-------------|
| 🌙 [Lua API](docs/lua-api.md) | Scripting reference |
| 📡 [Headless protocol](docs/headless-protocol.md) | Binary wire format |
| 🧱 [Block model](docs/block-model.md) | Command lifecycle |
| 📊 [Structured output](docs/structured-output.md) | Table renderer and builtins |
| 🖥️ [Attyx integration](docs/attyx-integration.md) | Native terminal bridge |
| 🗄️ [History queries](docs/history-queries.md) | SQLite history and replay |
| 🔄 [Migration assistant](docs/migration-assistant.md) | Bash/zsh conversion |

---

## 📄 License

MIT

---

<p align="center">
  <sub>⚡ Built with Zig &bull; 🌙 Lua &bull; 🗄️ SQLite &bull; 🚫 a distaste for POSIX</sub>
</p>
