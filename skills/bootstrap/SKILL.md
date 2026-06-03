---
name: bootstrap
description: Install the LHTask autonomous TODO workflow into the current repository — writes the parameterized git hooks, the lhtask.conf config, and the starter constitution/lifecycle files, then sets core.hooksPath. Use once per repo to make it plug-and-play. Idempotent; never overwrites existing files without asking.
argument-hint: (none — run inside the target repo)
---

You are installing the **LHTask** plan→implement→review workflow into the user's repo.
This is a one-time, **idempotent** scaffold. Never overwrite an existing file silently.

## 0. Locate the plugin templates
The templates live at `${CLAUDE_PLUGIN_ROOT}/templates`. Set:
```bash
TPL="${CLAUDE_PLUGIN_ROOT:-}/templates"
[ -d "$TPL" ] || echo "CLAUDE_PLUGIN_ROOT not set — ask the user for the plugin path."
ROOT="$(git rev-parse --show-toplevel)"   # must be a git repo; if not, offer: git init
```
If `$ROOT` isn't a git repo, stop and offer to run `git init` first (the chain needs git hooks).

## 1. Detect the project type → propose config defaults
Inspect the repo root and pick sensible `lhtask.conf` values:

| Marker file        | Language | `LHTASK_TEST_CMD`                          | `LHTASK_VENV` |
| ------------------ | -------- | ----------------------------------------- | ------------- |
| `pyproject.toml` / `setup.py` | Python | `.venv/bin/python -m pytest {path} -q` (or `python -m pytest {path} -q` if no `.venv`) | `.venv` (if it exists) else empty |
| `package.json`     | Node     | `npm test` (or `pnpm test` / `yarn test` per lockfile) | empty |
| `go.mod`           | Go       | `go test ./...`                           | empty |
| `Cargo.toml`       | Rust     | `cargo test`                              | empty |

For `LHTASK_REVIEW_DIRS`, detect the top-level source + test dirs that exist
(e.g. `src tests`, `app tests`, `lib test`, `pkg`). For `LHTASK_CONSTITUTION_FILES`,
list the constitution files that exist or will be created (default `AGENTS.md`; add
`CLAUDE.md` and any frontend guide if present).

**Confirm the proposed values with the user** via `AskUserQuestion` whenever the project
type is ambiguous (e.g. multiple lockfiles, monorepo, no obvious test command). Otherwise
state the detected defaults and proceed.

## 2. Copy the chain (don't clobber)
```bash
mkdir -p "$ROOT/.githooks" "$ROOT/scripts"
cp -n "$TPL/githooks/post-commit"   "$ROOT/.githooks/post-commit"
cp -n "$TPL/githooks/README.md"     "$ROOT/.githooks/README.md"
cp -n "$TPL/scripts/lhtask-lib.sh"      "$ROOT/scripts/lhtask-lib.sh"
cp -n "$TPL/scripts/lhtask-plan.sh"     "$ROOT/scripts/lhtask-plan.sh"
cp -n "$TPL/scripts/lhtask-implement.sh" "$ROOT/scripts/lhtask-implement.sh"
cp -n "$TPL/scripts/lhtask-review.sh"   "$ROOT/scripts/lhtask-review.sh"
chmod +x "$ROOT/.githooks/post-commit" "$ROOT"/scripts/lhtask-*.sh
```
`cp -n` never overwrites. If a target already exists and differs, tell the user and ask
before replacing (show a diff).

## 3. Write `lhtask.conf` with the confirmed values
If `$ROOT/lhtask.conf` exists, do **not** overwrite — show what differs and let the user decide.
Otherwise start from `$TPL/lhtask.conf` and substitute the detected values for
`LHTASK_REVIEW_DIRS`, `LHTASK_TEST_CMD`, `LHTASK_CONSTITUTION_FILES`, `LHTASK_VENV`.

## 4. Seed the lifecycle + constitution files (only if missing)
For each of `TODO.md`, `DONE.md`, `AGENT_LOG.md`, `AGENTS.md`: copy from `$TPL/` **only if the
file does not already exist** (`cp -n`). Never touch an existing `AGENTS.md`/`CLAUDE.md` — the
user's conventions win.

## 5. Update `.gitignore`
Append (if not already present): `TODO.autoplan.md`, `TODO.review.md`, `TODO.run.log` (the
human-visible consolidated run log). The `.git/lhtask-*.log` and lock files live under `.git/`
and are never tracked. Don't duplicate existing entries.

## 6. Activate the hooks
```bash
git -C "$ROOT" config core.hooksPath .githooks
```

## 7. Minimal Claude settings (clean, no absolute paths)
If `$ROOT/.claude/settings.json` is missing, create one with a small allowlist that lets the
chain run without prompts — and **no machine-specific absolute paths**. Suggested allow entries:
`Bash(claude --version)`, `Bash(git *)`, `Bash(codegraph *)`, plus the project's test runner
(e.g. `Bash(.venv/bin/python -m pytest *)` or `Bash(npm test*)`). If the file exists, **merge**
the allowlist rather than overwriting, and never copy entries containing absolute home paths.

## 8. Summarize and hand off
Print what was created/skipped, the final `lhtask.conf` values, and the next steps:
- Capture work with `/lhtask:lh-task "<idea>"`.
- Commit `TODO.md` to start the chain (implementation lands on the impl branch, never auto-merged).
- Kill switch: `touch .git/autoplan.disabled`. Debug a stage: `LHTASK_FOREGROUND=1 .githooks/post-commit`.
- Remind the user this needs the `claude` CLI on PATH, and (optionally) the `codegraph` CLI/MCP
  for caller/impact analysis — it degrades gracefully to Grep/Glob without it.
