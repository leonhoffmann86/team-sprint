# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the **source of the `lhtask` Claude Code plugin** — not an application. There is no
build, lint, or test toolchain. The "code" is:

- three **skills** (`skills/lh-task`, `skills/bootstrap`, `skills/update`) — markdown prompt files
  with frontmatter,
- three **slash-command wrappers** (`commands/*.md`) — thin 1:1 shims that invoke the matching
  skill via the Skill tool and pass `$ARGUMENTS` through,
- a set of **bash templates** (`templates/`) that `bootstrap` copies into a *target* repo,
- the **subagent team** (`agents/*.md`) — six role definitions (planner, navigator, implementer,
  reviewer-correctness, reviewer-conventions, reviewer-visual) used by the implement loop,
- plugin metadata (`.claude-plugin/plugin.json`, `marketplace.json`, `CHANGELOG.md` — keep the
  version in sync across all three when releasing).

Critical mental model: the scripts in `templates/scripts/` and `templates/githooks/` **do not run
here**. They are parameterized files that get copied (`cp -n`) into another repo by the `bootstrap`
skill, where they execute as a git `post-commit` chain. So editing a script here changes what every
future bootstrapped repo gets; it has no effect on this repo's own git activity.

**Agents are duplicated on purpose:** `agents/` is the plugin-canonical copy (auto-updates with the
plugin, used by interactive sessions); `templates/.claude/agents/` is the vendored copy that
`bootstrap` installs into the target repo, because the headless hook chain reads the role bodies via
`--append-system-prompt` from `$ROOT/.claude/agents/`. **Keep the two directories identical** —
edit `agents/` and run `make sync-agents` to copy them over, then `/lhtask:update` in target repos.
The same applies to `.mcp.json` (codegraph MCP server config) and `templates/.mcp.json`.

## The plan → implement → review chain (the heart of the plugin)

When bootstrapped into a repo, `templates/githooks/post-commit` routes each commit:

- commit changed `TODO.md` → **`lhtask-plan.sh`** (writes `TODO.autoplan.md`) → chains
  **`lhtask-implement.sh`** in the same detached run.
- commit changed any `LHTASK_REVIEW_DIRS/` → **`lhtask-review.sh`** (writes `TODO.review.md`, report-only).

`lhtask-implement.sh` is a **shell-driven subagent-team orchestrator** in an **isolated
`git worktree`** on `LHTASK_IMPL_BRANCH` (default `autoplan/impl`). It runs **planner → navigator**
once, then a bounded loop (up to `LHTASK_MAX_ITER`, default 3):

1. **implementer** — smallest change, **one commit per item** (code + `TODO.md`→`DONE.md` +
   `AGENT_LOG.md`),
2. **deterministic gate** (`lhtask-gate.sh`, pure shell, no LLM) — lint/typecheck/test/build per
   `LHTASK_GATE_*`/`LHTASK_STACK` (stack auto-detected from marker files); red → loop back with the
   failures as the fix list,
3. **reviewers** (correctness + conventions, read-only) — `blocker`/`major` findings → loop back.

Each role is its **own headless `claude -p`** (not Task-delegation) so the shell can run the gate
between phases and bound the loop. Role prompts get the matching `agents/<role>.md` body via
`--append-system-prompt` (frontmatter stripped by `lhtask_agent_body`); roles exchange JSON sidecars
in `.lhtask-state/` inside the worktree (excluded from commits via the worktree's `info/exclude`).
**Only `gate.json` is machine-trusted** (shell-authored); agent JSON is parsed jq-or-grep,
**fail-closed** (missing/garbled review JSON = blocker → loopback, never a silent DONE).

On convergence or exhaustion, `lhtask_findings_surface` publishes `TODO.review.md` and the
`## 🔎` pointer — the in-loop reviewers replace the old terminal `lhtask-review.sh` call (the hook
can't review agent commits because they set `AUTOPLAN_AGENT=1`; `LHTASK_REVIEW_AUTONOMOUS=0` leaves
a gate-only loop). The impl branch is **never auto-merged** and **hard-reset (`-B`) each run** — it
can carry several unmerged commits, so target-repo users must merge or discard promptly.
`templates/scripts/lhtask-lib.sh` holds shared helpers sourced by all stages, including the gate.

When changing any stage script, preserve these load-bearing invariants:

- **Loop safety:** agent processes export `AUTOPLAN_AGENT=1`; the hook and scripts skip when it's set.
  Anything that commits from inside an agent run must keep this set or it will recurse infinitely.
- **GIT_DIR unset:** every stage script starts by unsetting `GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  GIT_PREFIX GIT_QUARANTINE_PATH`. Git injects these into post-commit subprocesses; without clearing
  them `git worktree add` resolves against the hook's quarantined index and fails. Don't remove this.
- **Skip convention:** `lhtask_strip_skipped` (in `lhtask-lib.sh`) removes items inside `<!-- … -->`,
  under `## 🚧` (Deferred), and under `## 🔎` (Review-Findings). Plan/implement act only on what's left.
  High-risk items are moved under `## 🚧 Deferred`, never implemented autonomously.
- **Locking:** each stage takes a `mkdir` lock under `.git/lhtask-*.lock`; `lhtask_reap_stale_lock`
  clears locks older than N minutes so a killed run can't permanently block the chain.
- **Detached by default:** stages background themselves so the commit returns immediately. Set
  `LHTASK_FOREGROUND=1` to run synchronously (this is the debugging/testing lever).
- **Graceful no-op:** every stage exits 0 if `claude` (or, for codegraph, `codegraph`) is absent;
  the gate records a check whose command is unconfigured or whose tool is off PATH as `skip`,
  never a hard fail; missing `timeout`/`gtimeout` just means no per-phase timeout.
- **Permission hardening:** `AUTOPLAN_AGENT=1` is set centrally in `run_phase` (never per
  call-site). Every role gets the hard deny rules from `lhtask_deny_settings` via `--settings`
  (`git push`/`git reset --hard`/`git rebase`/`rm -rf`/`Task`/`Agent` — deny is evaluated first
  and can't be re-allowed); reviewers/planner/navigator run read-only (`dontAsk` + allowlist),
  the implementer commit-capable (`acceptEdits`). Don't widen these casually.
- **Fail-closed review parsing:** `lhtask_review_max_severity` treats a missing, empty, or
  unparseable review sidecar as `blocker`. Keep that direction — a garbled report must loop back,
  not pass.

## Configuration is the single source of truth

`templates/lhtask.conf` defines every tunable (review dirs, test command with `{path}` placeholder,
constitution files, impl branch, venv to symlink, codegraph mode, model override, autonomous-review
and notify toggles, plus the subagent/gate block: `LHTASK_STACK`, the four `LHTASK_GATE_*` commands,
`LHTASK_MAX_ITER`, `LHTASK_PHASE_TIMEOUT`, and the stage-2 visual-reviewer keys
`LHTASK_VISUAL_MAX_DIFF_RATIO`/`LHTASK_DEV_URL`). Defaults are duplicated in two places that
**must stay in sync** with the conf: `lhtask_load_config` in `lhtask-lib.sh`, and the inline
defaults at the top of `post-commit` (the hook reads only `LHTASK_REVIEW_DIRS` and
`LHTASK_CODEGRAPH` before scripts source the full lib). Empty `LHTASK_GATE_*` keys fall back to
built-in per-stack defaults in `lhtask_gate_cmd` (test additionally falls back to the legacy
`LHTASK_TEST_CMD`).

## The constitution preamble

`lhtask_preamble` (in `lhtask-lib.sh`) is prepended to every agent prompt and forces the agent to
read the project's constitution files (`LHTASK_CONSTITUTION_FILES`, default `AGENTS.md`) first and
obey their risk tiers. `templates/AGENTS.md` is the starter constitution; its risk-tier lists are
what the autonomous implementer refuses to touch. Behavior is meant to be steered by editing the
*constitution in the target repo*, not by hardcoding rules into the scripts.

## Editing skills

Skills are markdown with YAML frontmatter (`name`, `description`, `argument-hint`). `lh-task` is a
*refinement* workflow (idea → one structured `TODO.md` item; never writes code, never auto-commits).
`bootstrap` is an *idempotent installer* (`cp -n` everywhere; never clobbers an existing file without
asking). `update` *re-syncs the vendored chain* in already-bootstrapped repos (overwrites only logic
files — scripts, hooks, agents; never `lhtask.conf` or lifecycle files; `--all` consumes the registry
at `~/.config/lhtask/registry`). Both resolve templates via `${CLAUDE_PLUGIN_ROOT}/templates` — keep
that path relationship intact if you move files. The `description` field is what triggers the skill,
so keep it specific and outcome-oriented. Each skill has a thin wrapper in `commands/<name>.md`
(same frontmatter shape, body just invokes the skill and forwards `$ARGUMENTS`) — when you change a
skill's `description`/`argument-hint`, update the wrapper's to match.

Agent files (`agents/*.md`) carry their own frontmatter (`name`, `description`, `tools`, `model`)
for interactive use; the headless loop strips it. `reviewer-visual` is a **scaffold** — shipped and
vendored, but not yet wired into the implement loop.

## Project commands & doc automation

This repo has no build toolchain, but a small `Makefile` wraps the setup + doc + sync steps:

- `make setup` — one-time per clone: `chmod +x` the hooks/scripts and `git config core.hooksPath
  .githooks` (this is local config, not committed, so every clone must run it).
- `make docs` — run `scripts/docs-refresh.sh`: headless `claude` regenerates the three
  source-of-truth docs (`CLAUDE.md`, `ARCHITECTURE.md`, `README.md`) from the current sources.
- `make check` — `bash -n` (plus `shellcheck` if installed) over every shell script.
- `make sync-agents` — copy `agents/*.md` → `templates/.claude/agents/` (the two must stay identical).

CI (`.github/workflows/ci.yml`) runs on push/PR to `main`: it validates the JSON manifests
(`plugin.json`, `marketplace.json`) and runs `shellcheck` + `bash -n` over the template scripts.

`.githooks/pre-push` keeps those docs in sync: when a push changes a **source** file it regenerates
the docs, commits them, and pushes that commit along (one `git push`, docs included). It is
loop-guarded by `LHTASK_DOCS_PUSH_GUARD` and gated so headless `claude` only runs on real source
changes. Levers: `LHTASK_DOCS_SKIP=1 git push`, kill switch `touch .git/docs-refresh.disabled`.

**Completeness principle (don't break it):** "source" is defined by *exclusion*, not an allowlist —
in both `.githooks/pre-push` (`DOC_EXCLUDE`) and the `docs-refresh.sh` prompt, every tracked file is
a doc source EXCEPT the generated docs (`CLAUDE.md`/`ARCHITECTURE.md`/`README.md`) and noise
(`.gitignore`, `.vscode/`, `.claude/`, `*.DS_Store`). This way a newly added source file can never be
silently forgotten. If you add a real exclusion, change it in *both* places.

## Testing changes to the chain

`tests/smoke-test.sh` is the end-to-end smoke test: it bootstraps the plugin into a throwaway repo
(`claude -p --plugin-dir … "/lhtask:bootstrap"`), commits a `TODO.md` task, runs the chain with
`LHTASK_FOREGROUND=1`, and asserts `TODO.run.log` was produced. It needs the `claude` CLI, so it is
not run in CI. To debug a change manually, bootstrap into a throwaway git repo and use:

```bash
LHTASK_FOREGROUND=1 .githooks/post-commit   # run the triggered stage synchronously
tail -f TODO.run.log                        # consolidated human-visible trace (reset each trigger)
cat .git/lhtask-implement.log               # raw per-stage log
touch .git/autoplan.disabled                # kill switch
```

`shellcheck` is the relevant linter for the bash scripts (scripts carry `# shellcheck source=` hints).
