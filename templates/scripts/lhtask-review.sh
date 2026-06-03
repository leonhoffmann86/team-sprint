#!/usr/bin/env bash
#
# lhtask-review.sh — STAGE 3 (REVIEW) of the LHTask agent chain.
#
# Usage: lhtask-review.sh [TARGET]
#   TARGET defaults to HEAD (the human commit that touched a review dir).
#   When called with the impl branch (e.g. autoplan/impl), it reviews the
#   commits that branch introduces over HEAD — so the AUTONOMOUS work gets a
#   review too (the post-commit hook can't, since agent commits set AUTOPLAN_AGENT=1).
#
# Asks headless Claude whether the change correctly implements the related
# TODO/plan item and follows the constitution conventions. Writes a report to the
# gitignored sidecar TODO.review.md. Report-only: never commits to code, never blocks.
# On ❌ findings it surfaces a pointer under "## 🔎 Review-Findings" in TODO.md
# (human-owned; the skip convention keeps the chain from acting on it) + AGENT_LOG.
#
set -euo pipefail

# Git exports GIT_DIR/GIT_INDEX_FILE/… into post-commit hook subprocesses; clear
# them so our own git commands resolve against the working dir, not the hook's
# quarantined index.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_QUARANTINE_PATH 2>/dev/null || true

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
# shellcheck source=scripts/lhtask-lib.sh
. "$ROOT/scripts/lhtask-lib.sh"
lhtask_load_config
lhtask_model_flags

git rev-parse HEAD~1 >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || { echo "lhtask-review: claude CLI not found, skipping." >&2; exit 0; }

TARGET="${1:-HEAD}"
# Chained from implement (a TARGET arg was passed) → append to the existing run
# log; standalone trigger (no arg) → it owns a fresh run log.
CHAINED=0; [ "$#" -ge 1 ] && CHAINED=1
SHA="$(git rev-parse --short "$TARGET" 2>/dev/null || echo "$TARGET")"
LOCKDIR="$ROOT/.git/lhtask-review.lock"
LOG="$ROOT/.git/lhtask-review.log"
RUNLOG="$ROOT/TODO.run.log"

# Decide what to inspect: a branch tip → the range it introduces over HEAD; else
# the single target commit.
if git show-ref --verify --quiet "refs/heads/$TARGET" && [ "$(git rev-parse "$TARGET")" != "$(git rev-parse HEAD)" ]; then
  SCOPE="branch ${TARGET} (autonomous work): inspect every commit it introduces with \`git log --stat HEAD..${TARGET}\` and \`git show <sha>\` per commit"
  WHAT="the autonomous implementation on branch ${TARGET}"
else
  SCOPE="commit ${SHA}: inspect with \`git show ${SHA}\` and \`git show --stat ${SHA}\`"
  WHAT="commit ${SHA}"
fi

read -r -d '' PROMPT <<EOF || true
$(lhtask_preamble)

Review ${WHAT}: does it correctly and completely implement the related TODO/plan
item, and does it follow the conventions in the constitution files?

Procedure (read-only): ${SCOPE}, read the affected files, and cross-check against
TODO.md, DONE.md and TODO.autoplan.md.

Write a concise review report EXCLUSIVELY to TODO.review.md (overwrite). Start with
"> Review of ${WHAT} — $(date '+%Y-%m-%d %H:%M')". One line per checked aspect:
✅ met / ⚠️ deviation / ❌ missing, each with a short reason and file reference.
Do not change any other file, do not commit. A report only.
EOF

lhtask_reap_stale_lock "$LOCKDIR" 15
mkdir "$LOCKDIR" 2>/dev/null || exit 0

# Standalone trigger owns a fresh run log; chained review appends to the existing one.
[ "$CHAINED" = 0 ] && lhtask_runlog_reset "$RUNLOG"

printf '> ⏳ Review of %s running since %s … report appears here when done.\n' \
  "$SHA" "$(date '+%H:%M:%S')" > "$ROOT/TODO.review.md"
echo "→ LHTask review started (${SHA}); report in TODO.review.md (~1–2 min)."

# Surface review results: traffic-light summary, ❌ loopback into TODO.md, AGENT_LOG.
lhtask_surface_review() {
  local report="$ROOT/TODO.review.md"
  [ -f "$report" ] || return 0
  local ok warn bad
  # grep -c already prints a count (0 on no match); just swallow its exit code.
  ok="$(grep -c '✅' "$report" 2>/dev/null || true)";  ok="${ok:-0}"
  warn="$(grep -c '⚠️' "$report" 2>/dev/null || true)"; warn="${warn:-0}"
  bad="$(grep -c '❌' "$report" 2>/dev/null || true)";  bad="${bad:-0}"
  local line="LHTask review ${SHA}: ✅ ${ok}  ⚠️ ${warn}  ❌ ${bad} — see TODO.review.md"
  echo "$line"

  if [ "$bad" -gt 0 ] 2>/dev/null; then
    # Append a human-owned pointer under a 🔎 section (skip convention ignores 🚧,
    # not 🔎 — but plan/implement only act on plain active items, so a 🔎 heading
    # is a visible note, not a task). Replace any prior LHTask-managed block.
    local todo="$ROOT/TODO.md"
    [ -f "$todo" ] || return 0
    awk 'BEGIN{s=0} /^## 🔎 Review-Findings/{s=1} s&&/^## /&&!/^## 🔎 Review-Findings/{s=0} !s{print}' "$todo" > "$todo.tmp" || cp "$todo" "$todo.tmp"
    {
      cat "$todo.tmp"
      printf '\n## 🔎 Review-Findings\n'
      printf -- '- ⚠️ %s — review of %s flagged %s ❌ finding(s). See TODO.review.md; resolve or re-file as a TODO.\n' \
        "$(date '+%Y-%m-%d %H:%M')" "$SHA" "$bad"
    } > "$todo"
    rm -f "$todo.tmp"
    [ -f "$ROOT/AGENT_LOG.md" ] && printf '\n## [%s] LHTask review %s — %s ❌, %s ⚠️ (see TODO.review.md)\n' \
      "$(date '+%Y-%m-%d %H:%M')" "$SHA" "$bad" "$warn" >> "$ROOT/AGENT_LOG.md"
  fi

  # Optional desktop notification.
  if [ "${LHTASK_NOTIFY:-0}" = "1" ]; then
    if command -v terminal-notifier >/dev/null 2>&1; then
      terminal-notifier -title "LHTask review ${SHA}" -message "$line" 2>/dev/null || true
    elif command -v notify-send >/dev/null 2>&1; then
      notify-send "LHTask review ${SHA}" "$line" 2>/dev/null || true
    fi
  fi
}

do_run() {
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
  lhtask_runlog_stage "$RUNLOG" "REVIEW (${SHA})"
  # AUTOPLAN_AGENT=1 defensively prevents any git activity from recursing.
  { AUTOPLAN_AGENT=1 claude -p "$PROMPT" \
      --permission-mode acceptEdits \
      --allowed-tools Read Write Glob Grep Bash \
      ${LHTASK_MODEL_FLAGS[@]+"${LHTASK_MODEL_FLAGS[@]}"} 2>&1 || true; } | tee -a "$RUNLOG" >"$LOG"
  lhtask_surface_review | tee -a "$RUNLOG"
}

if [ -n "${LHTASK_FOREGROUND:-}" ]; then
  ( do_run )
else
  ( do_run ) </dev/null >/dev/null 2>&1 &
fi

exit 0
