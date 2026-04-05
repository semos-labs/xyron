---
name: release
description: Create a new release — bump version, create release branch, write release notes. Use when the user says "/release", "release", "cut a release", etc.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
argument-hint: [patch|minor|major] [--rc] [--dry-run]
---

# Release Skill

You are helping the user create a new Xyron release. The release process has two phases: **version bump** and **release notes**.

## Phase 1: Version Bump

Parse the user's arguments to determine the release type:

| User says | Command |
|-----------|---------|
| `/release` or `/release patch` | `bun release` |
| `/release minor` | `bun release --minor` |
| `/release major` | `bun release --major` |
| `/release rc` or `/release patch rc` | `bun release --rc` |
| `/release minor rc` | `bun release --minor --rc` |
| `/release major rc` | `bun release --major --rc` |
| `/release dry` or `/release -n` | `bun release -n` |

**Steps:**

1. Run the appropriate `bun release` command. This will:
   - Bump version in `src/main.zig` and `build.zig.zon`
   - Create/switch to the `release-X.Y.Z` branch
   - Commit, tag, push, create draft GitHub release
   - Switch back to main

2. If the command fails, report the error and stop.

3. If `--dry-run` was used, show what would happen and stop — no phase 2.

## Phase 2: Release Notes

After the version bump succeeds:

1. **Determine the version** from the release script output (e.g. `v0.2.0`).

2. **Check out the release branch**: `git checkout release-X.Y.Z`

3. **Gather changes** since the last release tag:
   - Run `git log --oneline <previous-tag>..HEAD` to see all commits
   - Read any relevant PR descriptions for context
   - Focus on user-facing changes only

4. **Write release notes** to `releases/vX.Y.Z.md`:
   - Focus on what users can do, how to use it, and why it matters
   - No technical deep dives, internal architecture details, or implementation specifics
   - Always include PR links for each fix or feature (e.g. `(#42)`)
   - Concise and practical — readers should immediately understand what changed
   - Use the format from existing release notes in `releases/` as a reference
   - Do NOT include a header like `# Xyron vX.Y.Z` — the GitHub release title handles that

5. **Show the release notes** to the user for review before committing.

6. After user approval, **commit and push**:
   ```bash
   git add releases/vX.Y.Z.md
   git commit -m "release notes for vX.Y.Z"
   git push
   ```

7. **Switch back to main**: `git checkout main`

8. Tell the user the release is ready and provide the GitHub release link:
   `https://github.com/semos-labs/xyron/releases/tag/vX.Y.Z`

## Important

- Never run `bun release` without confirming the release type with the user if ambiguous
- If the user just says `/release` with no args, default to patch
- RC releases don't need release notes (they're pre-releases)
- The release notes CI workflow will automatically update the GitHub release body when the notes file is pushed to the release branch
