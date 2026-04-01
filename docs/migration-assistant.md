# Migration Assistant

```sh
migrate analyze <file>    # compatibility report (structured table)
migrate convert <file>    # auto-convert to Xyron/Lua config
```

Converts: `export` → `xyron.setenv()`, `alias` → `xyron.alias()`, `if/fi` → Lua `if/then/end`, `for/done` → Lua `for/do/end`, `[ -f file ]` → `file_exists()`.

Unsupported constructs get `-- UNSUPPORTED:` comments with explanations. Partial conversions show `-- was:` with the original.
