#!/usr/bin/env bash
#
# lhtask-implement.sh — STAGE 2 (IMPLEMENT) of the LHTask agent chain.
#
# Runs headless Claude in an ISOLATED git worktree on the configured impl branch
# to implement the active, not-yet-done TODO items. Never touches the working
# tree, never auto-merges. Done items move TODO.md → DONE.md; high-risk/failed
# items move under "## 🚧 Deferred"; every step appends to AGENT_LOG.md — all
# committed only on the impl branch, for the human to review and merge.
#
# After the batch, if LHTASK_REVIEW_AUTONOMOUS=1, the review stage is run against
# the new impl-branch commits (the post-commit hook can't, since agent commits
# carry AUTOPLAN_AGENT=1) — so the autonomous work always gets a review report.
#
# Idempotency (no hidden state file): items already in DONE.md or under the 🚧
# section are skipped — both are human-visible and committed on the branch.
#
set -euo pipefail

# Git exports GIT_DIR/GIT_INDEX_FILE/… into post-commit hook subprocesses; clear
# them so our own git commands (esp. `git worktree add`) resolve paths against the
# working dir, not the hook's quarantined index — otherwise the worktree add fails.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_QUARANTINE_PATH 2>/dev/null || true

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
# shellcheck source=scripts/lhtask-lib.sh
. "$ROOT/scripts/lhtask-lib.sh"
lhtask_load_config
lhtask_model_flags

[ -f "$ROOT/.git/autoplan.disabled" ] && exit 0
command -v claude >/dev/null 2>&1 || { echo "lhtask-implement: claude CLI not found, skipping." >&2; exit 0; }

LOCKDIR="$ROOT/.git/lhtask-implement.lock"
LOG="$ROOT/.git/lhtask-implement.log"
RUNLOG="$ROOT/TODO.run.log"
WT="$ROOT/.git/lhtask-worktree"
BR="${LHTASK_IMPL_BRANCH:-autoplan/impl}"

lhtask_reap_stale_lock "$LOCKDIR" 30
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

ACTIVE="$(lhtask_strip_skipped "$ROOT/TODO.md")"
PLAN="$( [ -f "$ROOT/TODO.autoplan.md" ] && cat "$ROOT/TODO.autoplan.md" || echo '(no plan available)' )"
DONE="$( [ -f "$ROOT/DONE.md" ] && cat "$ROOT/DONE.md" || echo '(empty)' )"
TEST_CMD="${LHTASK_TEST_CMD:-echo 'no test command configured' && false}"

# Fresh worktree/branch from HEAD. Prune first so a stale registration left by a
# killed earlier run (dir gone but still recorded) can't block the add.
git worktree remove --force "$WT" 2>/dev/null || true
rm -rf "$WT"
git worktree prune 2>/dev/null || true
git worktree add -f -B "$BR" "$WT" HEAD >/dev/null 2>&1 || { echo "lhtask-implement: worktree add failed" >&2; exit 0; }
# Symlink the venv (so tests run against worktree code) only if configured.
if [ -n "${LHTASK_VENV:-}" ] && [ -e "$ROOT/$LHTASK_VENV" ]; then
  ln -s "$ROOT/$LHTASK_VENV" "$WT/$LHTASK_VENV" 2>/dev/null || true
fi
# Symlink the fresh code-graph DB for caller/impact analysis, if present.
if [ "${LHTASK_CODEGRAPH:-auto}" != "off" ] && [ -f "$ROOT/.codegraph/codegraph.db" ]; then
  mkdir -p "$WT/.codegraph" 2>/dev/null || true
  ln -s "$ROOT/.codegraph/codegraph.db" "$WT/.codegraph/codegraph.db" 2>/dev/null || true
fi

read -r -d '' PROMPT <<EOF || true
$(lhtask_preamble)

You work in an ISOLATED git worktree on branch ${BR} (NOT the working branch).
Implement the ACTIVE, not-yet-done TODO items. Rules:

- For EACH active item, first classify risk per the constitution / AGENTS.md.
  * HIGH-RISK (auth/permissions, payments/billing, schema/migrations, secrets/env,
    infra, broad deletions, production/preview): DO NOT implement. Move the item in
    TODO.md under the heading "## 🚧 Deferred" with the note "High-risk: needs human approval".
  * Otherwise: smallest complete implementation per the project conventions.
- Tests: run the narrowest sensible selection using this command template, replacing
  {path} with the target you choose:  ${TEST_CMD}
  On GREEN: exactly ONE commit per item, containing together:
    (a) the code change,
    (b) the item REMOVED from TODO.md and moved to DONE.md (with date + "${BR}"),
    (c) an AGENT_LOG.md entry (what, why, which tests are green).
  On RED (after a reasonable attempt): discard the code change, move the item in
  TODO.md under "## 🚧 Deferred" with a short failure cause, doc-only commit + AGENT_LOG note.
- DO NOT push, DO NOT merge, DO NOT switch branches. Commit only on ${BR}.
- Skip items already present in DONE.md.

ACTIVE TODO items:
${ACTIVE}

PLAN (TODO.autoplan.md):
${PLAN}

DONE.md (already done — skip):
${DONE}
EOF

cd "$WT"
echo "→ Implementation running on branch ${BR} (worktree) …"
lhtask_runlog_stage "$RUNLOG" "IMPLEMENT (branch ${BR})"
# AUTOPLAN_AGENT=1 → the agent's own commits skip the post-commit hook (no recursion).
{ AUTOPLAN_AGENT=1 claude -p "$PROMPT" \
    --permission-mode acceptEdits \
    --allowed-tools Read Write Edit Glob Grep Bash \
    ${LHTASK_MODEL_FLAGS[@]+"${LHTASK_MODEL_FLAGS[@]}"} 2>&1 || true; } | tee -a "$RUNLOG" >"$LOG"

cd "$ROOT"
# Capture the impl-branch tip before dropping the worktree, for the review stage.
IMPL_SHA="$(git rev-parse --short "$BR" 2>/dev/null || echo '')"
BASE_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo '')"
# Keep the branch (commits persist in the repo); drop the worktree dir.
git worktree remove --force "$WT" 2>/dev/null || true
# Summarize the autonomous commits into the run log (human-visible).
lhtask_runlog_stage "$RUNLOG" "RESULT — commits on ${BR}"
git log --oneline "$BR" --not HEAD 2>/dev/null | sed 's/^/  /' >> "$RUNLOG" || true
echo "✓ Implementation done on branch ${BR}. Review: git log ${BR} — then merge or discard."

# Gap fix: review the autonomous commits (the hook won't, AUTOPLAN_AGENT=1).
if [ "${LHTASK_REVIEW_AUTONOMOUS:-1}" = "1" ] && [ -n "$IMPL_SHA" ] && [ "$IMPL_SHA" != "$BASE_SHA" ]; then
  AUTOPLAN_AGENT=1 LHTASK_FOREGROUND=1 "$ROOT/scripts/lhtask-review.sh" "$BR" >>"$LOG" 2>&1 || true
fi

exit 0
