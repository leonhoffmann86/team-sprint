---
name: bootstrap
description: Bootstraps LHTask into a repo: installs git hooks, configuration, and starter files. Use once per repo to enable autonomous plan→implement→review on every commit. Idempotent; never overwrites existing files without asking.
argument-hint: (none — run inside the target repo)
---

You are installing the **LHTask** plan→implement→review workflow into the user's repo.
This is a one-time, **idempotent** scaffold. Never overwrite an existing file silently.

## 0. Locate the plugin templates
The templates live at `${CLAUDE_PLUGIN_ROOT}/templates` — i.e. the plugin **as installed**,
never a development checkout. Set:
```bash
TPL="${CLAUDE_PLUGIN_ROOT:-}/templates"
# Fallback when CLAUDE_PLUGIN_ROOT is unset (e.g. skill executed manually): resolve the
# INSTALLED plugin from the marketplace cache — most recently installed version wins.
[ -d "$TPL" ] || TPL="$(ls -dt "$HOME"/.claude/plugins/cache/*/lhtask/*/templates 2>/dev/null | head -1)"
[ -d "${TPL:-}" ] || { echo "lhtask is not installed. Run:
  claude plugin marketplace add leonhoffmann86/lhtask-plugin
  claude plugin install lhtask@lhtask-marketplace"; }
ROOT="$(git rev-parse --show-toplevel)"   # must be a git repo; if not, offer: git init
```
If neither resolves, **stop** with that install instruction. Do NOT search the filesystem
for a plugin source tree and do NOT accept a git checkout of the plugin repo as `$TPL` —
only the installed (versioned) copy is a valid template source (see `docs/DISTRIBUTION.md`).
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

Also pick the **deterministic-gate** values (used by the implement loop's `lhtask-gate.sh`):

| Marker file        | `LHTASK_STACK` | Gate commands (lint / typecheck / test / build) |
| ------------------ | -------------- | ----------------------------------------------- |
| `next.config.*`    | `nextjs` | `npm run -s lint` / `npx -y tsc --noEmit` / `npm test --silent` / `npm run -s build` |
| `package.json` + react | `react` | `npm run -s lint` / `npx -y tsc --noEmit` / `npm test --silent` / (none) |
| `pyproject.toml` / `setup.py` | `python` | `ruff check {path}` / `mypy {path}` / `pytest {path} -q` / (none) |
| `composer.json`    | `php`  | `vendor/bin/phpcs {path}` / `vendor/bin/phpstan analyse {path}` / `vendor/bin/pest` / (none) |
| `go.mod`           | `go`   | `gofmt -l .` / (none) / `go test ./...` / (none) |
| `Cargo.toml`       | `rust` | `cargo clippy -- -D warnings` / (none) / `cargo test` / `cargo build` |

You may leave `LHTASK_STACK="auto"` and the `LHTASK_GATE_*` empty — `lhtask-gate.sh` then
auto-detects the stack and uses the same built-in defaults at runtime. Set them explicitly only
to override. Each gate command is skipped (not failed) if its tool isn't on PATH.

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
cp -n "$TPL/scripts/lhtask-gate.sh"     "$ROOT/scripts/lhtask-gate.sh"
chmod +x "$ROOT/.githooks/post-commit" "$ROOT"/scripts/lhtask-*.sh

# Subagent team (vendored copy — the headless loop reads these via --append-system-prompt;
# the plugin also ships the same agents/ so interactive sessions get them and they auto-update).
mkdir -p "$ROOT/.claude/agents"
for a in planner navigator implementer reviewer-correctness reviewer-conventions reviewer-visual; do
  cp -n "$TPL/.claude/agents/$a.md" "$ROOT/.claude/agents/$a.md"
done

# codegraph MCP config (used as the headless navigator's --mcp-config fallback). MERGE,
# don't clobber: if $ROOT/.mcp.json already exists, add the "codegraph" server into its
# mcpServers (keep the user's other servers) rather than overwriting.
cp -n "$TPL/.mcp.json" "$ROOT/.mcp.json"
```
`cp -n` never overwrites. If a target already exists and differs, tell the user and ask
before replacing (show a diff).

## 3. Write `lhtask.conf` with the confirmed values
If `$ROOT/lhtask.conf` exists, do **not** overwrite — show what differs and let the user decide.
Otherwise start from `$TPL/lhtask.conf` and substitute the detected values for
`LHTASK_REVIEW_DIRS`, `LHTASK_TEST_CMD`, `LHTASK_CONSTITUTION_FILES`, `LHTASK_VENV`, and the
gate block (`LHTASK_STACK` + any explicit `LHTASK_GATE_*` overrides from step 1; leave empty to
auto-detect). `LHTASK_MAX_ITER`/`LHTASK_PHASE_TIMEOUT` defaults are usually fine.

## 4. Seed the lifecycle + constitution files (only if missing)
For each of `TODO.md`, `DONE.md`, `AGENT_LOG.md`, `AGENTS.md`: copy from `$TPL/` **only if the
file does not already exist** (`cp -n`). Never touch an existing `AGENTS.md`/`CLAUDE.md` — the
user's conventions win.

## 5. Update `.gitignore`
Append (if not already present): `TODO.autoplan.md`, `TODO.review.md`, `TODO.run.log` (the
human-visible consolidated run log), and `.lhtask-state/` (the per-run role sidecars; also
excluded inside the worktree, but ignore it in the main repo too). The `.git/lhtask-*.log` and
lock files live under `.git/` and are never tracked. Don't duplicate existing entries.

## 6. Activate the hooks
```bash
git -C "$ROOT" config core.hooksPath .githooks
```

## 7. Minimal Claude settings (allowlist + hard deny rules, no absolute paths)
If `$ROOT/.claude/settings.json` is missing, create one with a small allowlist that lets the
chain run without prompts — and **no machine-specific absolute paths**. Suggested allow entries:
`Bash(claude --version)`, `Bash(git *)`, `Bash(codegraph *)`, plus the project's test runner
(e.g. `Bash(.venv/bin/python -m pytest *)` or `Bash(npm test*)`).

**Also add a `permissions.deny` block** (defense-in-depth — the implement loop already passes the
same denies via `--settings`, but committing them makes every clone inherit them; deny is evaluated
first and cannot be re-allowed by any layer):

```json
{
  "permissions": {
    "allow": ["Bash(git *)", "Bash(claude --version)", "Bash(codegraph *)"],
    "deny": ["Bash(git push *)", "Bash(git reset --hard *)", "Bash(git rebase *)", "Bash(rm -rf *)"]
  }
}
```

If the file exists, **merge** allow + deny rather than overwriting, and never copy entries
containing absolute home paths.

## 8. Summarize and hand off
Print what was created/skipped, the final `lhtask.conf` values, and the next steps:
- Capture work with `/lhtask:lh-task "<idea>"`.
- Commit `TODO.md` to start the chain. The implement stage runs a subagent team
  (planner → navigator → implementer → deterministic gate → reviewers, bounded by
  `LHTASK_MAX_ITER`) in an isolated worktree on the impl branch. **Never auto-merged** — and it
  now carries up to `LHTASK_MAX_ITER` unmerged commits, so review and merge/discard the branch
  promptly (`git log <impl-branch>`).
- Kill switch: `touch .git/autoplan.disabled`. Debug a stage: `LHTASK_FOREGROUND=1 .githooks/post-commit`.
- Needs the `claude` CLI on PATH; `codegraph` CLI/MCP is optional (gate + reviewers degrade
  gracefully to Grep/Glob without it). Per-stack gate tools (eslint/tsc, ruff/mypy/pytest,
  phpcs/phpstan/pest) are skipped — not failed — when absent.
- Refresh the chain later (after a plugin update) with `/lhtask:update`.
