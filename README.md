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

| | Feature | Description |
|---|---------|-------------|
| 🌙 | **Lua scripting** | Config, hooks, custom commands, automation — all in `config.lua`. No more `.bashrc` spaghetti. |
| 📊 | **Structured output** | `ls`, `ps`, `env`, `jobs`, `history` return colored tables. Pipe through `select`, `where`, `sort`, `to_json`. |
| 🗄️ | **SQLite history** | Every command recorded with exit code, duration, cwd. Search, filter, rerun. Ctrl+R fuzzy search. |
| 🔍 | **Smart completions** | Fuzzy picker with descriptions. Parses `--help` and caches flags. Path, env, command providers. |
| 👻 | **Ghost text** | History-based inline suggestions as you type. Right arrow to accept. |
| ⌨️ | **Vim mode** | Optional modal editing. Cursor shape and prompt change with mode. |
| 🎨 | **Prompt engine** | Composable segments: cwd, git branch, jobs, duration, Lua functions. Multiline + right-align. |
| ⚙️ | **Job control** | Background `&`, Ctrl+Z suspend, `fg`/`bg` resume, process groups. |
| 📂 | **Directory jumping** | Frecency-based `j` command. Learns from your `cd` usage. |
| 🔐 | **Secrets manager** | Encrypted store. Reference secrets in commands without exposing in history or env. |
| 🔎 | **Fuzzy finder** | Built-in `fz` for fuzzy file and directory search. Zero dependencies. |
| 🔄 | **Migration assistant** | `migrate analyze` + `migrate convert` — translates bash/zsh config to Lua. |
| 🖥️ | **Attyx integration** | Native popups, IPC socket, headless binary protocol. Structured lifecycle events. |

---

## 📊 Structured data pipeline

Builtins output colored tables interactively, and JSON when piped — so you can chain `select`, `where`, and `sort` to build pipelines. No `awk`/`sed`/`jq` needed.

```bash
# Structured ls — table in terminal, JSON when piped
> ls -la
permissions  name         type  size
────────────────────────────────────
drwxr-xr-x   .git/        dir      -
-rw-r--r--   build.zig    file  2.8K
drwxr-xr-x   src/         dir      -

# Pipe commands chain together
> ps | where %cpu > 5.0 | sort %cpu desc | select pid,command,%cpu
> ls -la | where type == "file" | sort size desc

# Query history like a database
> history failed
> history slow 5000
> history cwd ~/Projects/xyron
> history search "docker"

# Render external JSON as tables
> curl -s api/users | json .data.[]
name     age  role
──────────────────
Alice     30  admin
Bob       25  user

# Or query it with the full pipeline
> curl -s api/users | query .data.[] select name,age where .age > 25 sort .age desc

# CSV/TSV to structured table
> cat report.csv | csv
> cat data.tsv | csv --sep "\t"

# Output raw JSON for external tools
> ls | to_json                              # plain JSON array
> ps | where %cpu > 5 | select pid,command | to_json | jq .
```

---

## 📂 Directory jumping

Built-in `j` command — a zoxide-style smart jumper. Learns from every `cd` and ranks by frecency (frequency + recency).

```bash
> j proj           # jumps to ~/Projects (or fuzzy picks if ambiguous)
> j xy             # jumps to ~/Projects/xyron
> j ~/Documents    # literal path — acts as cd
> jump list        # see all tracked directories with scores
> jump clean       # remove stale entries
> jump migrate     # import your zoxide database
```

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
