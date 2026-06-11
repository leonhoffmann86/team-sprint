#!/usr/bin/env bash
#
# lhtask-plan.sh — STAGE 1 (PLAN) of the LHTask agent chain.
#
# When a commit changes TODO.md, ask headless Claude to plan concrete sub-todos
# for the ACTIVE items (skip convention honoured) and write them to the gitignored
# sidecar TODO.autoplan.md. Then chain STAGE 2 (implement) in the same detached run.
#
# Loop-safe: writes only the gitignored sidecar; never touches/commits TODO.md.
# Install once:  git config core.hooksPath .githooks
#
set -euo pipefail

# Git exports GIT_DIR/GIT_INDEX_FILE/… into post-commit hook subprocesses; clear
# them so our own git commands (esp. `git worktree add` downstream) resolve paths
# against the working dir, not the hook's quarantined index.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_QUARANTINE_PATH 2>/dev/null || true

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
# shellcheck source=scripts/lhtask-lib.sh
. "$ROOT/scripts/lhtask-lib.sh"
lhtask_load_config
# Degradations of a cross-vendor plan model land here; consumed by the sourced lib
# (lhtask_model_fallback_note) and by the chained implement stage — hence exported.
export LHTASK_MODEL_FALLBACK_LOG="$ROOT/.git/lhtask-model-fallbacks.log"
lhtask_model_flags plan    # stage-level override: LHTASK_MODEL_PLAN (cross-vendor capable)

# First commit has no parent → nothing to diff against.
git rev-parse HEAD~1 >/dev/null 2>&1 || exit 0
# Only act when THIS commit actually changed TODO.md.
git diff --name-only HEAD~1 HEAD -- TODO.md | grep -qx 'TODO.md' || exit 0
command -v claude >/dev/null 2>&1 || { echo "lhtask-plan: claude CLI not found, skipping." >&2; exit 0; }

SHA="$(git rev-parse --short HEAD)"
LOCKDIR="$ROOT/.git/lhtask-plan.lock"
LOG="$ROOT/.git/lhtask-plan.log"
RUNLOG="$ROOT/TODO.run.log"
ACTIVE="$(lhtask_strip_skipped "$ROOT/TODO.md")"

# No ACTIVE checkbox item left (e.g. the commit was an applied/merged chain result
# whose TODO.md change only REMOVED items) → nothing to plan; skip the claude run.
# Tolerant on purpose: `- [ ]`, `* [ ]` and bare `[ ]` all count — a false
# "nothing to do" silently blocks real work, which is worse than one idle run.
if ! printf '%s\n' "$ACTIVE" | grep -qE '^[[:space:]]*([-*][[:space:]]+)?\[ \]'; then
  echo "lhtask-plan: no active TODO items — nothing to plan, skipping." >&2
  exit 0
fi

read -r -d '' PROMPT <<EOF || true
$(lhtask_preamble)

TODO.md was just changed (commit ${SHA}).

Task: for the ACTIVE TODO items (below, already without commented-out / deferred
points) plan 2–4 concrete, actionable sub-steps each — referencing the relevant
files/functions in the repo, short and precise. Mark each item's rough risk tier
(low/medium/high per the constitution / AGENTS.md).

Write the result EXCLUSIVELY to TODO.autoplan.md (overwrite the whole file). Start
with "> Auto-generated from commit ${SHA} — suggestions, not binding." Do not change
any other file and do not commit anything.

ACTIVE TODO items:
${ACTIVE}
EOF

# Reap a stale lock, then take it up front so a concurrent commit skips cleanly.
lhtask_reap_stale_lock "$LOCKDIR" 15
mkdir "$LOCKDIR" 2>/dev/null || exit 0

# Fresh human-visible run log for this trigger (root, gitignored — tail -f it).
lhtask_runlog_reset "$RUNLOG"

# Immediate feedback (the run is detached, ~1–2 min, sidecar is gitignored).
printf '> ⏳ LHTask plan running since %s (commit %s) … result appears here when done.\n' \
  "$(date '+%H:%M:%S')" "$SHA" > "$ROOT/TODO.autoplan.md"
echo "→ LHTask plan started (commit $SHA); live log: TODO.run.log (tail -f). Implement on branch ${LHTASK_IMPL_BRANCH} (~minutes)."

# Plan, then chain implement; release lock on exit. Whitelisted read/write tools.
do_run() {
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
  lhtask_runlog_stage "$RUNLOG" "PLAN (commit $SHA)"
  { env ${LHTASK_MODEL_ENV[@]+"${LHTASK_MODEL_ENV[@]}"} \
      claude -p "$PROMPT" \
      --permission-mode acceptEdits \
      --allowed-tools Read Write Edit Glob Grep \
      ${LHTASK_MODEL_FLAGS[@]+"${LHTASK_MODEL_FLAGS[@]}"} 2>&1 || true; } | tee -a "$RUNLOG" >"$LOG"
  lhtask_runlog_note "$RUNLOG" "Plan written → TODO.autoplan.md. Starting implementation …"
  # STAGE 2: implement the freshly planned items (own lock, own log; tees into RUNLOG itself).
  "$ROOT/scripts/lhtask-implement.sh" >>"$LOG" 2>&1 || true
}

# Default: detached so the commit returns immediately. LHTASK_FOREGROUND=1 runs
# synchronously (debugging / testing).
if [ -n "${LHTASK_FOREGROUND:-}" ]; then
  ( do_run )
else
  ( do_run ) </dev/null >/dev/null 2>&1 &
fi

exit 0
