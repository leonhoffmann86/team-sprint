#!/usr/bin/env bash
#
# sprint-plan.sh — STAGE 1 (PLAN) of the Sprint agent chain.
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
# shellcheck source=scripts/sprint-lib.sh
. "$ROOT/scripts/sprint-lib.sh"
sprint_load_config
# Degradations of a cross-vendor plan model land here; consumed by the sourced lib
# (sprint_model_fallback_note) and by the chained implement stage — hence exported.
export SPRINT_MODEL_FALLBACK_LOG="$ROOT/.git/sprint-model-fallbacks.log"
sprint_model_flags plan    # stage-level override: SPRINT_MODEL_PLAN (cross-vendor capable)

# Commit trigger (default): only act when THIS commit actually changed TODO.md.
# The scan trigger (sprint-scan.sh, SPRINT_TRIGGER=scan) has already decided via
# content hash that there is new work — no commit involved, so no diff to check.
if [ "${SPRINT_TRIGGER:-commit}" = "commit" ]; then
  # First commit has no parent → nothing to diff against.
  git rev-parse HEAD~1 >/dev/null 2>&1 || exit 0
  git diff --name-only HEAD~1 HEAD -- TODO.md | grep -qx 'TODO.md' || exit 0
fi
command -v claude >/dev/null 2>&1 || { echo "sprint-plan: claude CLI not found, skipping." >&2; exit 0; }

SHA="$(git rev-parse --short HEAD)"
LOCKDIR="$ROOT/.git/sprint-plan.lock"
LOG="$ROOT/.git/sprint-plan.log"
RUNLOG="$ROOT/TODO.run.log"
ACTIVE="$(sprint_strip_skipped "$ROOT/TODO.md")"

# No ACTIVE checkbox item left (e.g. the commit was an applied/merged chain result
# whose TODO.md change only REMOVED items) → nothing to plan; skip the claude run.
# Tolerant on purpose: `- [ ]`, `* [ ]` and bare `[ ]` all count — a false
# "nothing to do" silently blocks real work, which is worse than one idle run.
if ! printf '%s\n' "$ACTIVE" | grep -qE '^[[:space:]]*([-*][[:space:]]+)?\[ \]'; then
  echo "sprint-plan: no active TODO items — nothing to plan, skipping." >&2
  exit 0
fi

read -r -d '' PROMPT <<EOF || true
$(sprint_preamble)

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
sprint_reap_stale_lock "$LOCKDIR" 15
mkdir "$LOCKDIR" 2>/dev/null || exit 0

# Fresh human-visible run log for this trigger (root, gitignored — tail -f it).
sprint_runlog_reset "$RUNLOG"

# Immediate feedback (the run is detached, ~1–2 min, sidecar is gitignored).
printf '> ⏳ Sprint plan running since %s (commit %s) … result appears here when done.\n' \
  "$(date '+%H:%M:%S')" "$SHA" > "$ROOT/TODO.autoplan.md"
echo "→ Sprint plan started (commit $SHA); live log: TODO.run.log (tail -f). Implement on branch ${SPRINT_IMPL_BRANCH} (~minutes)."

# Plan, then chain implement; release lock on exit. Whitelisted read/write tools.
sprint_stream_setup   # live tool-call trace (jq-gated)
# shellcheck disable=SC2034  # consumed by sprint_stream_trace (sourced lib).
SPRINT_TRACE_ROLE="plan"

do_run() {
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
  sprint_runlog_stage "$RUNLOG" "PLAN (commit $SHA)"
  { env ${SPRINT_MODEL_ENV[@]+"${SPRINT_MODEL_ENV[@]}"} \
      claude -p "$PROMPT" \
      --permission-mode acceptEdits \
      --allowed-tools Read Write Edit Glob Grep \
      ${SPRINT_MODEL_FLAGS[@]+"${SPRINT_MODEL_FLAGS[@]}"} \
      ${SPRINT_STREAM_FLAGS[@]+"${SPRINT_STREAM_FLAGS[@]}"} 2>&1 || true; } \
    | sprint_stream_trace | tee -a "$RUNLOG" >"$LOG"
  sprint_runlog_note "$RUNLOG" "Plan written → TODO.autoplan.md. Starting implementation …"
  # STAGE 2: implement the freshly planned items (own lock, own log; tees into RUNLOG itself).
  "$ROOT/scripts/sprint-implement.sh" >>"$LOG" 2>&1 || true
}

# Default: detached so the commit returns immediately. SPRINT_FOREGROUND=1 runs
# synchronously (debugging / testing).
if [ -n "${SPRINT_FOREGROUND:-}" ]; then
  ( do_run )
else
  ( do_run ) </dev/null >/dev/null 2>&1 &
fi

exit 0
