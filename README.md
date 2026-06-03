# LHTask — autonomous TODO workflow, as a portable Claude Code plugin

Turn a rough idea into one well-formed `TODO.md` item, then let a git-hook chain
**plan → implement → review** it: the implementer works in an isolated worktree on a
branch that is **never auto-merged**, and a reviewer checks the result. High-risk work
is never done autonomously. Language-agnostic and config-driven, so it drops into any repo.

## What you get

- **`/lhtask:lh-task <idea>`** — refine an idea/question into one structured, risk-tiered
  TODO item, grounded in the real code (code graph if available, else Grep/Glob).
- **`/lhtask:bootstrap`** — install the chain into the current repo (hooks, config, starters).
- A **post-commit chain**:
  - change `TODO.md` → **plan** (`TODO.autoplan.md`) → **implement** on the impl branch
    (one commit per item: code + `TODO.md`→`DONE.md` + `AGENT_LOG.md`).
  - change a source dir → **review** (`TODO.review.md`).
  - the implementer also triggers a **review of its own autonomous commits**.

## Install

```bash
# Local / personal:
claude --plugin-dir /path/to/lhtask-plugin

# Or via a (private) marketplace repo:
/plugin marketplace add <git-url-of-this-repo>
/plugin install lhtask
```

Then, inside any repo you want to enable:

```bash
/lhtask:bootstrap          # detects project type, writes hooks + lhtask.conf, sets core.hooksPath
/lhtask:lh-task "your idea" # capture the first task
git add TODO.md && git commit -m "task: ..."   # starts the chain
```

## Configuration — `lhtask.conf` (single source of truth)

| Key | Meaning |
| --- | --- |
| `LHTASK_REVIEW_DIRS` | dirs whose changes trigger the review stage (e.g. `src tests`) |
| `LHTASK_TEST_CMD` | test command the implementer must pass; `{path}` → chosen target |
| `LHTASK_CONSTITUTION_FILES` | files every stage reads first (e.g. `AGENTS.md CLAUDE.md`) |
| `LHTASK_IMPL_BRANCH` | branch the implementer commits to (default `autoplan/impl`) |
| `LHTASK_VENV` | venv to symlink into the worktree (Python); empty for Node/Go |
| `LHTASK_CODEGRAPH` | `auto` \| `on` \| `off` |
| `LHTASK_MODEL` | model override for headless runs (empty = default) |
| `LHTASK_REVIEW_AUTONOMOUS` | `1` = also review the impl-branch commits |
| `LHTASK_NOTIFY` | `1` = desktop notification on review completion |

## Safety / control

- **Isolation:** implementation happens in a throwaway worktree on the impl branch; you merge.
- **Risk tiers:** high-risk items (auth, payments, schema/migrations, secrets, infra, …) are
  deferred to `## 🚧 Deferred`, never implemented autonomously.
- **Loop-safe:** agent commits set `AUTOPLAN_AGENT=1`; the hook skips them.
- **Kill switch:** `touch .git/autoplan.disabled`.
- **No-op without `claude`** on PATH; code graph is optional (Grep/Glob fallback).

## Layout

```
.claude-plugin/plugin.json   # manifest
marketplace.json             # for /plugin marketplace add
skills/lh-task/SKILL.md       # idea → one TODO item
skills/bootstrap/SKILL.md     # scaffold the chain into a repo
templates/                    # parameterized chain + starters copied by bootstrap
  ├── githooks/post-commit, README.md
  ├── scripts/lhtask-{lib,plan,implement,review}.sh
  ├── lhtask.conf
  └── AGENTS.md, TODO.md, DONE.md, AGENT_LOG.md
```

## Debugging

```bash
tail -f TODO.run.log                        # human-visible live trace (reset each trigger)
LHTASK_FOREGROUND=1 .githooks/post-commit   # run the triggered stage synchronously
cat .git/lhtask-implement.log               # raw per-stage logs
```
