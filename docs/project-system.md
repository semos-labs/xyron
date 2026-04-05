# Project System

Xyron is a project-aware shell. Every directory can be a project, and Xyron understands what that project needs — its environment, its commands, its services — without you wiring it together manually.

This document covers the entire project system: how projects are defined, how context works, what commands are available, and why each piece exists.

---

## xyron.toml

A project is defined by a `xyron.toml` file at its root. This is the only file Xyron needs. Everything else — environment files, services, commands — is declared here and resolved by the runtime.

```toml
[project]
name = "api-platform"

[commands]
dev = "bun run dev"
build = "bun run build"
test = "bun test"

[commands.migrate]
command = "bun run db:migrate"
cwd = "./packages/database"

[env]
sources = [".env", ".env.local"]

[env.values]
OPENAI_API_KEY = "${secret:OPENAI_KEY}"
DATABASE_URL = "postgres://user:${secret:DB_PASS}@localhost/mydb"
STATIC_VALUE = "hello"

[secrets]
required = ["DATABASE_URL", "JWT_SECRET"]

[services.web]
command = "bun run dev"

[services.db]
command = "docker compose up postgres"
cwd = "./infra"

[services.worker]
command = "bun run worker:start"
```

### Sections

**`[project]`** — Project metadata.
- `name` — Display name. Optional. Falls back to directory name.

**`[commands]`** — Named commands that run inside the project context.
- Shorthand: `dev = "bun run dev"` — name maps directly to a shell command.
- Full form: `[commands.migrate]` with `command` and optional `cwd` — for commands that need a different working directory.
- `cwd` defaults to the project root when not specified.

**`[env]`** — Environment configuration.
- `sources` — Ordered list of `.env` files to load. Later files override earlier ones.
- Files are resolved relative to the project root.
- Missing files produce a warning, not an error — `.env.local` is often gitignored and may not exist until the developer creates it.

**`[env.values]`** — Explicit environment variables with optional secret interpolation.
- Plain values: `STATIC_VALUE = "hello"`
- Secret references: `API_KEY = "${secret:MY_SECRET}"` — resolved from `xyron secrets` at runtime.
- Interpolation: `DB_URL = "postgres://user:${secret:DB_PASS}@localhost/db"` — secrets can be embedded in strings.
- Values from `[env.values]` override env file values but are overridden by explicit overrides.
- Secret-sourced values are automatically redacted in `xyron context explain`.

**`[secrets]`** — Required environment keys.
- `required` — List of keys that must be present in the resolved environment.
- These are checked after all env sources are merged. If a key is missing, `xyron doctor` flags it, and the prompt widget shows it.
- Xyron does not store secret values here — this is a declaration of what the project needs.

**`[services.<name>]`** — Long-running background processes.
- `command` — The shell command to run.
- `cwd` — Working directory, defaults to project root.
- Services are scoped to the project. Same service names in different projects never collide.

---

## Project Detection

Xyron finds the active project by walking upward from the current directory, looking for the nearest `xyron.toml`. The first match wins.

```
~/projects/api/packages/web/src/
    → checks ~/projects/api/packages/web/src/
    → checks ~/projects/api/packages/web/
    → checks ~/projects/api/packages/
    → checks ~/projects/api/          ← xyron.toml found here
```

This means:
- Nested projects are supported. A `xyron.toml` inside `packages/web/` would take priority over the parent project when you're inside that directory.
- Moving between directories can change the active project.
- The project root is always the directory containing `xyron.toml`.

---

## Context Engine

The context engine is the core of Xyron's project intelligence. It answers: *what environment should this project have right now?*

### How It Works

When a project activates, Xyron merges environment values from multiple sources in a fixed precedence order:

1. **System environment** (lowest priority) — inherited from the process
2. **Project env files** — `.env`, `.env.local`, etc., in the order declared in `env.sources`
3. **Explicit overrides** (highest priority) — reserved for future use

Later sources win. If `.env` sets `PORT=3000` and `.env.local` sets `PORT=8080`, the final value is `8080`.

### Provenance

Every value tracks where it came from. Xyron records:
- Which source provided the final value (the "winner")
- All sources that contributed a value for the same key
- Whether the value was overridden by a higher-priority source

This provenance chain powers `xyron context explain` — you can always ask *why is this value what it is?*

### Fingerprinting

The resolved context has a stable fingerprint (hash of all key-value pairs). When context changes — an env file is edited, a new key appears — the fingerprint changes. This is used to detect stale services and trigger context reloads.

---

## Smart Entry

When you `cd` into a project directory, Xyron automatically:

1. Detects the project via nearest `xyron.toml`
2. Resolves the full context (env files, system env)
3. Applies project environment to the shell session
4. Shows a one-line status:

```
project: api-platform · env: 2 loaded · 1 secret(s) missing · 3 cmd(s)
```

When you leave the project, Xyron removes the project-applied environment variables. Your shell returns to its baseline state.

### Transitions

Xyron classifies every directory change:

| From | To | Transition |
|---|---|---|
| No project | Project | **Enter** — activate context |
| Project | No project | **Leave** — remove overlay |
| Project A | Project B | **Switch** — swap contexts |
| Same project, same config | Same project, same config | **Stay** — no-op |
| Same project, config changed | Same project, config changed | **Reload** — re-resolve |

### Prompt Widget

The `xyron_project` prompt segment shows the active project on the right side of the prompt:

```
~/projects/api   main  +2 ~1                                  ◆ api-platform
>
```

If secrets are missing, it shows a count: `◆ api-platform ✗2`

Add it to your prompt config:
```lua
xyron.prompt.init({
    "cwd", " ", "git", "spacer", "xyron_project",
    "\n", "symbol", " ",
})
```

---

## Commands

### `xyron run <command>`

Run a project-defined command inside the resolved context.

```
$ xyron run dev
$ xyron run test
$ xyron run migrate
```

The command runs with:
- The shell's current environment, which includes the project overlay
- The command's `cwd` (defaults to project root, configurable per command)

If the command isn't found, Xyron shows the available commands:

```
$ xyron run deploy
unknown command: deploy

Available commands:
  ▸ dev    bun run dev
  ▸ build  bun run build
  ▸ test   bun test
```

With no arguments, `xyron run` lists available commands.

### Why It Exists

Every project has its own scripts — `npm run dev`, `cargo test`, `go run .` — but the patterns differ across ecosystems. `xyron run` normalizes this. You define commands once in `xyron.toml` and they work the same way regardless of the underlying toolchain.

More importantly, commands always run inside the resolved context. Environment variables from `.env` files are applied, so you don't need to remember `dotenv run --` or `source .env &&` prefixes.

---

## Services

Services are long-running background processes — dev servers, databases, workers — managed by Xyron as part of the project runtime.

### `xyron up [service]`

Start all project services, or a specific one:

```
$ xyron up
  ● web      started
  ● db       started
  ● worker   started

$ xyron up db
  ● db  started
```

Services run detached from the shell session. They survive after you close the terminal.

### `xyron down`

Stop all running services for the current project:

```
$ xyron down
  ● web      stopped
  ● db       stopped
  ● worker   stopped
```

### `xyron restart <service>`

Stop and restart a single service with fresh context:

```
$ xyron restart web
  ● web  started
```

This re-resolves the project context, so if you changed `.env`, the restarted service picks up the new values.

### `xyron ps`

Show service status for the current project:

```
$ xyron ps
Services
  ● web      running  pid 12345
  ● db       running  pid 12346
  ○ worker   stopped
```

If a service was launched with a different context fingerprint than the current one, it shows a stale warning:

```
  ● web  running  pid 12345  (stale)
```

This means the environment changed since the service was started — a `xyron restart web` would pick up the new values.

### `xyron logs <service>`

View logs for a service:

```
$ xyron logs web
--- service start: web ---
listening on port 3000
GET /api/health 200 2ms
GET /api/users 200 15ms
```

Logs are captured to `~/.local/share/xyron/logs/` and persist across shell sessions.

### Why It Exists

Development usually involves running multiple processes — a web server, a database, a background worker. Most developers either open multiple terminal tabs, use tmux, or rely on docker-compose. Xyron makes this a first-class part of the project definition.

Services are project-scoped. `xyron ps` in project A shows only project A's services. The same service name (`db`) in different projects refers to different processes with no collision.

---

## Doctor

### `xyron doctor`

Diagnose project issues. Doctor inspects the real system state — it doesn't guess or simulate.

```
$ xyron doctor

Project
  PASS  project detected  /home/user/api-platform
  PASS  config valid  xyron.toml loaded successfully

Environment
  PASS  .env  loaded (5 keys)
  WARN  .env.local  file not found
        → create .env.local or remove from env.sources

Secrets
  PASS  DATABASE_URL  present
  FAIL  JWT_SECRET  missing
        → add JWT_SECRET to .env or run: xyron secrets add JWT_SECRET <value>

Commands
  PASS  dev  ready
  PASS  build  ready
  PASS  test  ready

Services
  PASS  web  running (pid 12345)
  WARN  db  running but stale (context changed since launch)
        → xyron restart db

Git
  PASS  repository  branch: main

issues found  11 checks: 8 passed, 2 warnings, 1 failed
```

### Check Categories

| Category | What It Checks |
|---|---|
| **Project** | xyron.toml exists and parses correctly |
| **Environment** | Each declared env source loads or reports why not |
| **Secrets** | Each required key is present in the resolved context |
| **Commands** | Working directory exists for each declared command |
| **Services** | Process state, cwd validity, staleness detection |
| **Git** | Repository exists, detached HEAD, rebase/merge in progress, conflicts |

### Exit Codes

- `0` — healthy (warnings are ok)
- `1` — failures found

### Why It Exists

When something doesn't work in a project, the usual debugging process is: check the README, check environment variables, check if services are running, check if the database is reachable, check git state. Doctor does all of this in one command.

It's especially useful for onboarding — a new developer clones a repo, runs `xyron doctor`, and immediately sees what's missing.

---

## Context Explain

### `xyron context explain`

Show a summary of the active context:

```
$ xyron context explain

project   api-platform
root      /home/user/api-platform
status    valid
fprint    a3f8c19e2b4d7011

sources
  ● system  system (95 keys)
  ● .env  file (5 keys)
  ● .env.local  file (3 keys)

values    103 total, 8 from project

missing required
  ✗ JWT_SECRET
```

### `xyron context explain <KEY>`

Explain where a specific value came from:

```
$ xyron context explain DATABASE_URL

key       DATABASE_URL
present   yes
value     postgres://prod-server/live
winner    .env.local  (env file)
override  yes

candidates  (lowest → highest priority)
    system  (system env)
  → .env  (env file)
  → .env.local  (env file)

scope     api-platform (/home/user/api-platform)
```

For sensitive keys, values are automatically redacted:

```
$ xyron context explain API_KEY

key       API_KEY
present   yes
value     sk****yz  (redacted)
winner    .env.local  (env file)
required  yes

scope     api-platform (/home/user/api-platform)
```

Keys containing `SECRET`, `TOKEN`, `KEY`, `PASSWORD`, `AUTH`, or `PRIVATE` are redacted by default.

### Why It Exists

Environment variables are invisible by default. When something breaks because a value is wrong or missing, you need to know: where did this come from? Was it overridden? Which source won?

Context explain makes the runtime transparent. Instead of grepping through env files, you ask Xyron and get a concrete answer backed by the actual merge logic.

---

## Bootstrapping

### `xyron init`

Generate a `xyron.toml` for an existing project:

```
$ cd ~/projects/my-api
$ xyron init
✓ Initialized my-api project  (bun, detected via package.json)
  commands: dev, build, test
  env: .env, .env.local

  Created xyron.toml
```

Xyron inspects existing files to detect the ecosystem and infer commands:

| Marker File | Ecosystem | Inferred Commands |
|---|---|---|
| `package.json` + `bun.lock` | Bun | Scripts from `package.json` |
| `package.json` | Node | Scripts from `package.json` |
| `Cargo.toml` | Rust | build, test, run |
| `go.mod` | Go | run, test |
| `build.zig` / `build.zig.zon` | Zig | build, test |
| `pyproject.toml` / `setup.py` | Python | test |

If `xyron.toml` already exists, init refuses to overwrite it.

### `xyron new <ecosystem> [name]`

Create a new project using the ecosystem's native scaffolding tool, then apply Xyron setup:

```
$ xyron new bun my-app
Running: bun init my-app
Done!

✓ Created my-app with xyron.toml  (bun)
```

```
$ xyron new rust my-crate
Running: cargo new my-crate
     Created binary (application) `my-crate` package

✓ Created my-crate with xyron.toml  (rust)
```

Supported ecosystems and their native tools:

| Ecosystem | Native Command |
|---|---|
| `bun` | `bun init` |
| `node` | `npm init -y` |
| `rust` / `cargo` | `cargo new` / `cargo init` |
| `go` | `go mod init` |
| `zig` | `zig init` |

If the native tool isn't installed, Xyron tells you rather than trying to work around it.

### Why It Exists

Writing `xyron.toml` by hand is fine, but unnecessary for common setups. `xyron init` reads what's already there and generates a correct starting point. `xyron new` goes further — it creates the project through the ecosystem's own tool, then adds Xyron support on top.

The goal is zero-friction adoption. Take any existing repo, run `xyron init`, and the project system activates immediately.

---

## Quick Reference

| Command | Description |
|---|---|
| `xyron init` | Generate xyron.toml for existing project |
| `xyron new <eco> [name]` | Create project with native tool + xyron.toml |
| `xyron run <command>` | Run a project command |
| `xyron up [service]` | Start project services |
| `xyron down` | Stop project services |
| `xyron restart <service>` | Restart a service |
| `xyron ps` | Show service status |
| `xyron logs <service>` | View service logs |
| `xyron doctor` | Diagnose project issues |
| `xyron context explain [KEY]` | Explain context / value origin |
| `xyron project info` | Show project summary |
| `xyron project context` | Show resolved context detail |

---

## How It All Connects

```
xyron.toml                    ← project definition
    │
    ├── Project Detection     ← nearest xyron.toml wins
    │
    ├── Context Engine        ← merge system env + .env files
    │   ├── provenance        ← track where each value came from
    │   └── fingerprint       ← detect when context changes
    │
    ├── Smart Entry           ← auto-activate on cd
    │   └── prompt widget     ← show active project
    │
    ├── Commands              ← xyron run
    │
    ├── Services              ← xyron up/down/ps/logs
    │   └── stale detection   ← fingerprint comparison
    │
    ├── Doctor                ← xyron doctor
    │   └── checks env, secrets, commands, services, git
    │
    ├── Context Explain       ← xyron context explain
    │   └── provenance display, redaction
    │
    └── Bootstrap             ← xyron init / xyron new
        └── ecosystem detection + manifest generation
```

Each layer consumes the one above it. Doctor doesn't re-parse TOML — it reads the same `ProjectModel` that the runtime uses. Context explain doesn't re-merge environment — it reads the same provenance the context engine already computed. Services don't load their own env — they use the context engine's resolved values.

One source of truth, all the way through.
