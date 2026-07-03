---
name: bootstrap
description: Bootstraps Sprint into a repo: installs git hooks, configuration, and starter files. Use once per repo to enable autonomous plan→implement→review on every commit. Idempotent; never overwrites existing files without asking.
argument-hint: (none — run inside the target repo)
---

You are installing the **Sprint** plan→implement→review workflow into the user's repo.
This is a one-time, **idempotent** scaffold. Never overwrite an existing file silently.

## 0. Locate the plugin templates
The templates live at `${CLAUDE_PLUGIN_ROOT}/templates` — i.e. the plugin **as installed**,
never a development checkout. Set:
```bash
TPL="${CLAUDE_PLUGIN_ROOT:-}/templates"
# Fallback when CLAUDE_PLUGIN_ROOT is unset (e.g. skill executed manually): resolve the
# INSTALLED plugin from the marketplace cache — most recently installed version wins.
[ -d "$TPL" ] || TPL="$(ls -dt "$HOME"/.claude/plugins/cache/*/sprint/*/templates 2>/dev/null | head -1)"
[ -d "${TPL:-}" ] || { echo "sprint is not installed. Run:
  claude plugin marketplace add leonhoffmann86/team-sprint
  claude plugin install sprint@team-sprint"; }
ROOT="$(git rev-parse --show-toplevel)"   # must be a git repo; if not, offer: git init
```
If neither resolves, **stop** with that install instruction. Do NOT search the filesystem
for a plugin source tree and do NOT accept a git checkout of the plugin repo as `$TPL` —
only the installed (versioned) copy is a valid template source (see `docs/DISTRIBUTION.md`).
If `$ROOT` isn't a git repo, stop and offer to run `git init` first (the chain needs git hooks).

## 1. Detect the project type → propose config defaults
Inspect the repo root and pick sensible `sprint.conf` values:

| Marker file        | Language | `SPRINT_TEST_CMD`                          | `SPRINT_VENV` |
| ------------------ | -------- | ----------------------------------------- | ------------- |
| `pyproject.toml` / `setup.py` | Python | `.venv/bin/python -m pytest {path} -q` (or `python -m pytest {path} -q` if no `.venv`) | `.venv` (if it exists) else empty |
| `package.json`     | Node     | `npm test` (or `pnpm test` / `yarn test` per lockfile) | empty |
| `go.mod`           | Go       | `go test ./...`                           | empty |
| `Cargo.toml`       | Rust     | `cargo test`                              | empty |

For `SPRINT_REVIEW_DIRS`, detect the top-level source + test dirs that exist
(e.g. `src tests`, `app tests`, `lib test`, `pkg`). For `SPRINT_CONSTITUTION_FILES`,
list the constitution files that exist or will be created (default `AGENTS.md`; add
`CLAUDE.md` and any frontend guide if present).

Also pick the **deterministic-gate** values (used by the implement loop's `sprint-gate.sh`):

| Marker file        | `SPRINT_STACK` | Gate commands (lint / typecheck / test / build) |
| ------------------ | -------------- | ----------------------------------------------- |
| `next.config.*`    | `nextjs` | `npm run -s lint` / `npx -y tsc --noEmit` / `npm test --silent` / `npm run -s build` |
| `package.json` + react | `react` | `npm run -s lint` / `npx -y tsc --noEmit` / `npm test --silent` / (none) |
| `pyproject.toml` / `setup.py` | `python` | `ruff check {path}` / `mypy {path}` / `pytest {path} -q` / (none) |
| `composer.json`    | `php`  | `vendor/bin/phpcs {path}` / `vendor/bin/phpstan analyse {path}` / `vendor/bin/pest` / (none) |
| `go.mod`           | `go`   | `gofmt -l .` / (none) / `go test ./...` / (none) |
| `Cargo.toml`       | `rust` | `cargo clippy -- -D warnings` / (none) / `cargo test` / `cargo build` |

You may leave `SPRINT_STACK="auto"` and the `SPRINT_GATE_*` empty — `sprint-gate.sh` then
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
cp -n "$TPL/scripts/sprint-lib.sh"      "$ROOT/scripts/sprint-lib.sh"
cp -n "$TPL/scripts/sprint-plan.sh"     "$ROOT/scripts/sprint-plan.sh"
cp -n "$TPL/scripts/sprint-implement.sh" "$ROOT/scripts/sprint-implement.sh"
cp -n "$TPL/scripts/sprint-review.sh"   "$ROOT/scripts/sprint-review.sh"
cp -n "$TPL/scripts/sprint-gate.sh"     "$ROOT/scripts/sprint-gate.sh"
cp -n "$TPL/scripts/sprint-scan.sh"     "$ROOT/scripts/sprint-scan.sh"
cp -n "$TPL/scripts/sprint-standup.sh"  "$ROOT/scripts/sprint-standup.sh"
chmod +x "$ROOT/.githooks/post-commit" "$ROOT"/scripts/sprint-*.sh

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

## 3. Write `sprint.conf` with the confirmed values
If `$ROOT/sprint.conf` exists, do **not** overwrite — show what differs and let the user decide.
Otherwise start from `$TPL/sprint.conf` and substitute the detected values for
`SPRINT_REVIEW_DIRS`, `SPRINT_TEST_CMD`, `SPRINT_CONSTITUTION_FILES`, `SPRINT_VENV`, and the
gate block (`SPRINT_STACK` + any explicit `SPRINT_GATE_*` overrides from step 1; leave empty to
auto-detect). `SPRINT_MAX_ITER`/`SPRINT_PHASE_TIMEOUT` defaults are usually fine.

## 4. Seed the lifecycle + constitution files (only if missing)
For each of `TODO.md`, `DONE.md`, `AGENT_LOG.md`, `AGENTS.md`: copy from `$TPL/` **only if the
file does not already exist** (`cp -n`). Never touch an existing `AGENTS.md`/`CLAUDE.md` — the
user's conventions win.

## 5. Update `.gitignore`
Append (if not already present): `TODO.autoplan.md`, `TODO.review.md`, `TODO.run.log` (the
human-visible consolidated run log), and `.sprint-state/` (the per-run role sidecars; also
excluded inside the worktree, but ignore it in the main repo too). The `.git/sprint-*.log` and
lock files live under `.git/` and are never tracked. Don't duplicate existing entries.

## 6. Choose the trigger mode, then activate it
**Ask the user** which trigger fits this repo (see `templates/trigger/README.md`):
- **commit** (default; `TODO.md` is tracked): activate the hook —
  ```bash
  git -C "$ROOT" config core.hooksPath .githooks
  ```
- **scan** (poll; `TODO.md` deliberately untracked, or nobody should have to
  commit to queue work): install the 30s poll from the plugin's trigger templates —
  macOS: fill `$TPL/../trigger/sprint-poll.plist.tmpl` (`__REPO__`, `__SLUG__`) into
  `~/Library/LaunchAgents/net.sprint.<slug>.plist`, then `launchctl bootstrap gui/$(id -u) <plist>`.
  Linux: `sprint@.service` + `sprint@.timer` as systemd user units.
  **Before activating**, seed the state so pre-existing open items don't instantly fire:
  `scripts/sprint-scan.sh --seed` — or skip the seed if the user WANTS the open
  items picked up immediately.
  The hook can stay active alongside (both triggers share locks + kill switch), or
  stay off if commits must never start agent runs (multi-agent repos).
Kill switch for both modes: `touch .git/autoplan.disabled`.

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

## 8. Tooling check (MANDATORY — the chain lives on its tool use)
The chain degrades gracefully when supporting tools are missing, but the user must be told
EXPLICITLY, with install commands and the concrete impact:
- **codegraph** (<https://github.com/colbymchenry/codegraph>): `command -v codegraph`; if
  installed but `.codegraph/codegraph.db` is missing, offer to run `codegraph sync .` once
  (the post-commit hook keeps it fresh afterwards). Missing entirely → planner/navigator/
  reviewers run WITHOUT code-graph intelligence.
- **fallow** (<https://docs.fallow.tools>): on PATH or `./node_modules/.bin/fallow`. Missing →
  the deterministic gate runs without dead-code/duplication/complexity analysis; suggest
  `npm i -g fallow` + `fallow init` (JS/TS projects).
- **jq**, **timeout/gtimeout**: missing → degraded JSON parsing / no per-phase timeout.
The same status appears as the `### Tooling` section in every `TODO.review.md`.

## 9. Registry (opt-in)
Ask the user whether to register this repo in `${XDG_CONFIG_HOME:-$HOME/.config}/sprint/registry`
(consumed by `/sprint:update --all`). Default to NO for internal/private repos — users keep those
out of the registry deliberately (see `docs/DISTRIBUTION.md`).

## 10. Summarize and hand off
Print what was created/skipped, the final `sprint.conf` values, the tooling report, and the next steps:
- Capture work with `/sprint:ticket "<idea>"`.
- Commit `TODO.md` to start the chain. The implement stage runs a subagent team
  (planner → navigator → implementer → deterministic gate → reviewers, bounded by
  `SPRINT_MAX_ITER`) in an isolated worktree on the impl branch. **Never auto-merged** — and it
  now carries up to `SPRINT_MAX_ITER` unmerged commits, so review and merge/discard the branch
  promptly (`git log <impl-branch>`).
- Kill switch: `touch .git/autoplan.disabled`. Debug a stage: `SPRINT_FOREGROUND=1 .githooks/post-commit`.
- Needs the `claude` CLI on PATH; `codegraph` CLI/MCP is optional (gate + reviewers degrade
  gracefully to Grep/Glob without it). Per-stack gate tools (eslint/tsc, ruff/mypy/pytest,
  phpcs/phpstan/pest) are skipped — not failed — when absent.
- Refresh the chain later (after a plugin update) with `/sprint:update`.
