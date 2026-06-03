# Git hooks — the LHTask TODO agent chain

Tracked hooks for this repo, installed by `/lhtask:bootstrap`. Enable once per clone:

```bash
git config core.hooksPath .githooks
```

## `post-commit` — plan → implement → review

On commit, [`post-commit`](post-commit) routes to headless Claude Code agents (each
reads the constitution files in `lhtask.conf` first and obeys them):

| Trigger (in the commit)            | Stage                         | Script                          | Output |
| ---------------------------------- | ----------------------------- | ------------------------------- | ------ |
| `TODO.md` changed                  | **1 Plan** → chains **2 Implement** | `scripts/lhtask-plan.sh` → `scripts/lhtask-implement.sh` | `TODO.autoplan.md`; commits on the impl branch |
| any `LHTASK_REVIEW_DIRS/` changed  | **3 Review**                  | `scripts/lhtask-review.sh`      | `TODO.review.md` (report-only) |

Shared helpers: `scripts/lhtask-lib.sh`. Config: `lhtask.conf` (single source of truth).

### What the implementer does (stage 2)

Works in an **isolated git worktree** on the impl branch (never your working tree,
never auto-merged). For each active, not-yet-done TODO item:

- **High-risk** (per `AGENTS.md`) → **not implemented**; moved under `## 🚧 Deferred` for a human.
- otherwise → smallest change; the configured test command must be **green**; then one
  commit per item with the code **+** the item moved `TODO.md` → `DONE.md` **+** an `AGENT_LOG.md` entry.

After the batch, the **review stage runs against the impl branch** (`LHTASK_REVIEW_AUTONOMOUS=1`),
so the autonomous work always gets a report — the post-commit hook can't do this itself
because agent commits carry `AUTOPLAN_AGENT=1`.

You review the branch (`git log <impl-branch>`) and merge or discard.

### TODO lifecycle & the skip lever

- `TODO.md` = open (yours). **Skip convention:** items inside `<!-- … -->`, under
  `## 🚧 Deferred`, or under `## 🔎 Review-Findings` are ignored by plan + implement.
- `DONE.md` = done (tracked, with ref) — also the idempotency anchor (done items are skipped).
- `AGENT_LOG.md` = chronological history. `TODO.autoplan.md` / `TODO.review.md` = gitignored sidecars.

### Safety / control

- **Loop-safe:** agent commits carry `AUTOPLAN_AGENT=1`; the hook skips those.
- **Kill switch:** `touch .git/autoplan.disabled` to disable the whole chain; remove to re-enable.
- **Live trace:** `TODO.run.log` in the repo root (gitignored) is a consolidated, human-visible
  log of the current trigger (PLAN → IMPLEMENT → RESULT, or REVIEW), reset each run — `tail -f` it.
- **Non-blocking:** runs are detached (~minutes); a placeholder lands in the sidecar at once.
  Raw per-stage logs: `.git/lhtask-*.log`. Locks: `.git/lhtask-*.lock` (stale locks auto-reaped).
- **No-op if `claude` is missing.**

Debug a stage synchronously:

```bash
LHTASK_FOREGROUND=1 .githooks/post-commit
```

Requires the `claude` CLI on `PATH`.
