# fz — Fuzzy Finder

Built-in fuzzy finder with full-screen TUI, inline mode, preview pane, and multi-select.

## Usage

```sh
fz                          # find files in current directory
ls | fz                     # pick from piped input
fz --preview                # with file preview (syntax highlighted)
fz -m                       # multi-select mode
fz -q "pattern"             # start with pre-filled query
cat list.txt | fz --exact   # exact substring match
```

## Options

| Flag | Description |
|------|-------------|
| `-q`, `--query STRING` | Pre-fill the search filter |
| `--prompt STRING` | Custom prompt (default: `"> "`) |
| `--header STRING` | Header text displayed above the list |
| `--header-lines N` | Treat first N input lines as header (not selectable) |
| `-e`, `--exact` | Exact case-insensitive substring match (not fuzzy) |
| `-m`, `--multi` | Multi-select mode (Tab to toggle, Enter to confirm all) |
| `-p`, `--preview` | Show file preview in right pane |
| `--preview-cmd "cmd {}"` | Custom preview command (`{}` replaced with selected item) |
| `-i`, `--inline` | Inline mode (no alternate screen) |
| `-0`, `--print0` | NUL-terminated output instead of newlines |
| `--reverse` | Top-down layout (prompt at top, items below) |
| `--height N` | Limit display to N rows |
| `-h`, `--help` | Show help |

## Keys

| Key | Action |
|-----|--------|
| Type | Fuzzy search / filter |
| Up / Down | Navigate |
| Tab / Shift-Tab | Toggle selection (multi-select) |
| Enter | Confirm selection |
| Escape / Ctrl+C | Cancel (exit code 1) |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Selection made |
| 1 | Cancelled or no matches |

## Preview & Syntax Highlighting

When `--preview` is enabled, fz shows a preview pane on the right side. If [bat](https://github.com/sharkdp/bat) is installed, fz automatically uses it for **syntax-highlighted** previews. If bat is not found, fz falls back to plain text.

### Install bat

```sh
# macOS
brew install bat

# Ubuntu/Debian
apt install bat

# Arch
pacman -S bat
```

bat is auto-detected at `/usr/local/bin/bat`, `/opt/homebrew/bin/bat`, or `/usr/bin/bat`.

### Custom preview command

Override the default preview with `--preview-cmd`:

```sh
fz --preview-cmd "head -50 {}"           # first 50 lines
fz --preview-cmd "bat --theme=Nord {}"    # bat with custom theme
fz --preview-cmd "file {}"                # file type info
```

## Examples

```sh
# Find and edit a file
vim $(fz --preview)

# Git add with preview
git diff --name-only | fz -m --preview | xargs git add

# Select from custom list with header
echo -e "dev\nstaging\nprod" | fz --header "Select environment:"

# Search with pre-filled query
fz -q ".zig" --preview
```
