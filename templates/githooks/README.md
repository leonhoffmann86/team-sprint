# Git hooks — the Sprint TODO agent chain

Tracked hooks for this repo, installed by `/sprint:bootstrap`. Enable once per clone:

```bash
git config core.hooksPath .githooks
```

## `post-commit` — plan → implement → review

On commit, [`post-commit`](post-commit) routes to headless Claude Code agents (each
reads the constitution files in `sprint.conf` first and obeys them):

| Trigger (in the commit)            | Stage                         | Script                          | Output |
| ---------------------------------- | ----------------------------- | ------------------------------- | ------ |
| `TODO.md` changed                  | **1 Plan** → chains **2 Implement** | `scripts/sprint-plan.sh` → `scripts/sprint-implement.sh` | `TODO.autoplan.md`; commits on the impl branch |
| any `SPRINT_REVIEW_DIRS/` changed  | **3 Review**                  | `scripts/sprint-review.sh`      | `TODO.review.md` (report-only) |

Shared helpers: `scripts/sprint-lib.sh`. Config: `sprint.conf` (single source of truth).

### What the implementer does (stage 2)

Works in an **isolated git worktree** on the impl branch (never your working tree,
never auto-merged) and runs a **subagent team** in a bounded loop (`sprint-implement.sh`),
each role its own headless `claude -p`:

1. **planner** → classifies risk (high-risk → `## 🚧 Deferred`, never implemented) and writes a
   bounded plan with verifiable acceptance criteria.
2. **navigator** → finds the existing patterns/conventions + blast radius (codegraph if present).
3. loop, up to `SPRINT_MAX_ITER` times:
   - **implementer** → smallest change; one commit per item (code **+** `TODO.md`→`DONE.md` **+**
     `AGENT_LOG.md`). It can commit but **cannot** push / `git reset --hard` / `rm -rf` (denied).
   - **deterministic gate** (`sprint-gate.sh`, pure shell, no LLM) → runs the stack's
     lint / typecheck / test / build (`SPRINT_GATE_*` / `SPRINT_STACK`) plus, if installed,
     **fallow** static analysis (`fallow audit`: dead code / duplication / complexity, scoped to
     the changeset, "new-only" — only findings the change *introduces* fail; `SPRINT_FALLOW`).
     A missing tool is skipped, not failed. **Red → loop back** to the implementer with the
     failures as the fix list.
   - **reviewers** (read-only) → correctness + conventions. `blocker`/`major` findings → loop back.
   - all green + no blocker/major → **DONE**.
4. loop exhausted without converging → escalated to `## 🔎 Review-Findings` (+ `AGENT_LOG`); the
   partial work stays on the impl branch for you.

A traffic-light report is written to `TODO.review.md` either way (the in-loop reviewers replace the
old terminal review call; `SPRINT_REVIEW_AUTONOMOUS=0` turns the reviewer phase off, leaving a
gate-only loop).

You review the branch (`git log <impl-branch>`) and **merge or discard promptly** — it is hard-reset
on the next run and may carry several unmerged commits.

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
  Raw per-stage logs: `.git/sprint-*.log`. Locks: `.git/sprint-*.lock` (stale locks auto-reaped).
- **No-op if `claude` is missing.**

Debug a stage synchronously:

```bash
SPRINT_FOREGROUND=1 .githooks/post-commit
```

Requires the `claude` CLI on `PATH`.
