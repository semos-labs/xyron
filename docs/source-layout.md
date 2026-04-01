# Source Layout

```
src/
  main.zig              Entrypoint — mode dispatch (shell/headless)
  shell.zig             REPL loop, orchestrates everything
  term.zig              Raw terminal mode (tcgetattr/tcsetattr)
  keys.zig              Key event types + escape sequence parser
  editor.zig            Line buffer with cursor, vim mode, UTF-8
  input.zig             readLine loop: keys → editor → display → ghost text
  prompt.zig            Prompt engine with modular segments
  token.zig             Lexer (words, pipes, redirects, &, quotes)
  ast.zig               AST types (Pipeline, SimpleCommand, Redirect)
  parser.zig            Tokens → AST (inline env assignments, quoted flags)
  expand.zig            $NAME and ~ expansion
  planner.zig           AST → ExecutionPlan (step IDs, pipe wiring)
  executor.zig          fork+dup2+exec, process groups, WUNTRACED
  environ.zig           Shell environment (wraps EnvMap, toEnvp for children)
  types.zig             IdGenerator, timestampMs
  builtins.zig          Thin re-export from builtins/mod.zig
  builtins/
    mod.zig             Dispatcher + isBuiltin/isProcessOnly
    cd.zig pwd.zig exit.zig export.zig unset.zig exec.zig
    env.zig             Structured table output (sorted, colored)
    ls.zig              Structured directory listing (-l, -a)
    ps.zig              Structured process listing (captures /bin/ps)
    history.zig         Structured history table
    alias.zig           Alias table
    jobs.zig            Job table (id, state, command)
    fg.zig bg.zig
    json.zig            JSON pipe target — parse + table render
    query.zig           SQL-like query for JSON (select/where/sort/limit)
    select.zig          Pick columns from structured data
    where.zig           Filter structured data by condition
    sort_cmd.zig        Sort structured data by field
    csv.zig             CSV parser + structured output
    which.zig type.zig
    popup.zig inspect.zig
    migrate.zig         Bash→Xyron migration assistant
  highlight.zig         Syntax highlighting (inline tokenizer, command cache)
  complete.zig          Interactive picker (fuzzy filter, tab/shift-tab cycle)
  complete_providers.zig  Builtins, lua, PATH, filesystem, env vars, help flags
  complete_help.zig     --help introspection + SQLite cache
  fuzzy.zig             Fuzzy matcher (ported from Attyx)
  history.zig           In-memory history buffer (circular, up/down nav)
  history_db.zig        SQLite history (commands + command_steps tables)
  history_search.zig    Ctrl+R full-screen history search
  sqlite.zig            Thin SQLite C wrapper
  jobs.zig              Job tracking (running/stopped/completed, WNOHANG reap)
  block.zig             Command block model (lifecycle, output association)
  block_ui.zig          Block rendering, output capture, overlay restoration
  aliases.zig           Alias registry
  attyx.zig             Attyx event emission (OSC 7339 on stderr)
  attyx_bridge.zig      Native Attyx UI bridge (picker, popup, inspect)
  protocol.zig          Binary protocol for headless + IPC mode
  headless.zig          Headless runtime loop
  ipc.zig               Unix socket IPC for interactive+query mode
  overlay.zig           Floating overlay system (completion picker positioning)
  pipe_json.zig         Structured pipe utilities (typed JSON, table rendering)
  lua_api.zig           Lua VM + xyron.* API surface
  lua_hooks.zig         Hook registry (on_command_start/finish, cwd, jobs)
  lua_commands.zig      Custom Lua command registry
  path_search.zig       PATH-based command resolution
  rich_output.zig       Table renderer (columns, alignment, colors, truncation)
  json_parser.zig       Minimal JSON parser (objects, arrays, types)
  migrate.zig           Bash/sh analyzer + converter engine
```
