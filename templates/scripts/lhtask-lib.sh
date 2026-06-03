#!/usr/bin/env bash
#
# lhtask-lib.sh — shared helpers for the LHTask plan→implement→review hook chain.
# Sourced by lhtask-plan.sh, lhtask-implement.sh, lhtask-review.sh.
#
# Conventions used across the chain:
#   - AUTOPLAN_AGENT=1 in the environment means "this process / its git commits
#     are agent-driven" → the post-commit hook skips, preventing recursion.
#   - The skip convention for TODO.md: items inside <!-- … --> HTML comments, or
#     under a "## 🚧" heading (e.g. "## 🚧 Deferred"), are NOT planned/implemented.

# Repo root (works from a worktree too).
LHTASK_ROOT="$(git rev-parse --show-toplevel)"

# Config defaults, then override from the repo's lhtask.conf if present.
lhtask_load_config() {
  LHTASK_REVIEW_DIRS="src tests"
  LHTASK_TEST_CMD="echo 'no test command configured' && false"
  LHTASK_CONSTITUTION_FILES="AGENTS.md"
  LHTASK_IMPL_BRANCH="autoplan/impl"
  LHTASK_VENV=""
  LHTASK_CODEGRAPH="auto"
  LHTASK_MODEL=""
  LHTASK_REVIEW_AUTONOMOUS="1"
  LHTASK_NOTIFY="0"
  # shellcheck source=/dev/null
  [ -f "$LHTASK_ROOT/lhtask.conf" ] && . "$LHTASK_ROOT/lhtask.conf"
  return 0
}

# Mandatory prompt preamble: every agent reads the project constitution first.
# Generic across projects — the actual conventions live in the constitution files.
lhtask_preamble() {
  local files="${LHTASK_CONSTITUTION_FILES:-AGENTS.md}"
  cat <<EOF
IMPORTANT — first read these project constitution files COMPLETELY and obey their
conventions strictly: ${files}.
(If any of them references further files, e.g. a frontend-specific guide, read those too.)

Core rules that bind every stage of this workflow:
- Make the smallest change that fully solves the item; follow existing patterns.
- Risk tiers (see the constitution / AGENTS.md) are binding. HIGH-RISK work is NEVER
  done autonomously — auth/permissions, payments/billing, DB schema/migrations,
  secrets/env, infrastructure, deletions with broad impact, anything touching
  production/preview. Such items are only NOTED as "needs human approval", never touched.
- Keep new behavior safe-by-default (dry-run / draft-first) where the project applies it.
EOF
}

# Print a file with skipped sections removed: HTML comments, the "## 🚧 …"
# (deferred) section, and the "## 🔎 …" (review-findings) section — neither of
# the latter two is a task the chain should act on.
lhtask_strip_skipped() {
  awk '
    /<!--/ { inc=1 }
    inc { if (/-->/) inc=0; next }
    /^##[[:space:]]/ { if ($0 ~ /🚧/ || $0 ~ /🔎/) { skip=1; next } else { skip=0 } }
    skip { next }
    { print }
  ' "$1"
}

# Reap a stale lock dir (older than $2 minutes) left by a killed run, so a crash
# can never permanently block future runs.
lhtask_reap_stale_lock() {
  local lockdir="$1" minutes="${2:-15}"
  if [ -d "$lockdir" ] && [ -z "$(find "$lockdir" -prune -mmin -"$minutes" 2>/dev/null)" ]; then
    rmdir "$lockdir" 2>/dev/null || true
  fi
}

# True if the chain is globally disabled or this is an agent commit.
lhtask_should_skip() {
  [ -n "${AUTOPLAN_AGENT:-}" ] && return 0
  [ -f "$LHTASK_ROOT/.git/autoplan.disabled" ] && return 0
  return 1
}

# Build a model flag array for headless claude calls (empty if no override).
# Usage: lhtask_model_flags; claude -p ... "${LHTASK_MODEL_FLAGS[@]}"
lhtask_model_flags() {
  LHTASK_MODEL_FLAGS=()
  [ -n "${LHTASK_MODEL:-}" ] && LHTASK_MODEL_FLAGS=(--model "$LHTASK_MODEL")
  return 0
}

# Human-visible run log in the repo root (gitignored): TODO.run.log. Unlike the
# per-stage .git/lhtask-*.log files, this is one consolidated, root-level trace you
# can `tail -f`. Reset at the start of each trigger; each stage appends a header
# and tees its agent output into it.
lhtask_runlog_reset() {  # $1 = path to TODO.run.log
  { printf '# LHTask run — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# overwritten on each trigger · follow with: tail -f TODO.run.log\n'; } > "$1"
}
lhtask_runlog_stage() {  # $1 = path, $2 = stage label
  printf '\n===== %s — %s =====\n' "$2" "$(date '+%H:%M:%S')" >> "$1"
}
lhtask_runlog_note() {   # $1 = path, $2 = message
  printf '— %s\n' "$2" >> "$1"
}
