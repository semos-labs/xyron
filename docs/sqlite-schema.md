# SQLite Schema

```sql
-- Command history
commands(id INTEGER PRIMARY KEY, raw_input TEXT, cwd TEXT,
         started_at INTEGER, finished_at INTEGER, duration_ms INTEGER,
         exit_code INTEGER, interrupted INTEGER, session_id TEXT)

command_steps(id INTEGER PRIMARY KEY, command_id INTEGER REFERENCES commands,
              step_index INTEGER, argv TEXT, exit_code INTEGER, duration_ms INTEGER)

-- Help introspection cache
command_help_flags(command TEXT, flag TEXT, description TEXT, cached_at INTEGER,
                   PRIMARY KEY(command, flag))
```
