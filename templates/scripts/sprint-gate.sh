#!/usr/bin/env bash
#
# sprint-gate.sh — STAGE 2 deterministic quality GATE (NOT an LLM).
#
# Usage: sprint-gate.sh <worktree-dir> <out-json>
#   Runs the stack-detected gate commands (lint / typecheck / test / build), each
#   binary pass/fail, and writes a Shell-AUTHORED gate.json — the only machine-trusted
#   structured artifact of the chain. Exit 0 = every check passed or was skipped;
#   exit 1 = at least one check failed.
#
# Graceful no-op: a check whose command is unconfigured OR whose tool is not on PATH
# is recorded as "skip", never a hard fail. No LLM, no network — fully deterministic.
#
# The orchestrator (sprint-implement.sh) passes the iteration via SPRINT_ITER.
#
set -uo pipefail   # deliberately NOT -e: every check must run and be aggregated.

# Git injects these into post-commit subprocesses; clear so our git calls resolve
# against the working dir, not the hook's quarantined index.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_QUARANTINE_PATH 2>/dev/null || true

WT="${1:-.}"
OUT="${2:-/dev/stdout}"
cd "$WT" 2>/dev/null || { echo "sprint-gate: worktree '$WT' not found" >&2; exit 1; }

# Source the shared lib + config from this worktree.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$WT")"
# shellcheck source=scripts/sprint-lib.sh
. "$ROOT/scripts/sprint-lib.sh"
sprint_load_config

# JSON string-literal encoder (dependency-free, portable across GNU/BSD): escapes \ and ",
# turns tabs into \t, drops \r, and joins embedded newlines as \n. Keeps gate.json valid
# without jq/tr (BSD `tr` octal ranges are unreliable — awk is consistent everywhere).
jstr() {
  printf '%s' "${1-}" | awk '
    BEGIN { ORS=""; printf "\"" }
    {
      l = $0
      gsub(/\\/, "\\\\", l)
      gsub(/"/,  "\\\"", l)
      gsub(/\t/, "\\t",  l)
      gsub(/\r/, "",     l)
      if (NR > 1) printf "\\n"
      printf "%s", l
    }
    END { printf "\"" }'
}

# Resolve the {path} target: the files changed by the latest commit, space-joined.
# S3: validate against shell metacharacters; on anything unexpected fall back to "."
# (whole worktree) so the eval below can never be injected through a crafted path.
paths="$(git diff --name-only HEAD~1 HEAD 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
if [ -z "$paths" ] || printf '%s' "$paths" | grep -Eq '[^A-Za-z0-9._/ -]'; then
  paths="."
fi

stack="${SPRINT_STACK:-auto}"; [ "$stack" = auto ] && stack="$(sprint_detect_stack)"
iter="${SPRINT_ITER:-0}"
verdict="pass"
records=""

add_record() {  # name cmd status exit summary detail
  local rec
  rec="{\"name\":$(jstr "$1"),\"cmd\":$(jstr "$2"),\"status\":$(jstr "$3"),\"exit\":${4:-null},\"summary\":$(jstr "$5"),\"detail\":$(jstr "${6-}")}"
  if [ -z "$records" ]; then records="$rec"; else records="$records,$rec"; fi
}

for check in lint typecheck test build; do
  cmd="$(sprint_gate_cmd "$check")"
  if [ -z "$cmd" ]; then
    add_record "$check" "" skip "" "no command configured"
    continue
  fi
  first="$(printf '%s' "$cmd" | awk '{print $1}')"
  if ! command -v "$first" >/dev/null 2>&1; then
    add_record "$check" "$cmd" skip "" "tool '$first' not on PATH"
    continue
  fi
  run="${cmd//\{path\}/$paths}"
  out="$(eval "$run" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    add_record "$check" "$run" pass "$rc" "ok"
  else
    verdict="fail"
    add_record "$check" "$run" fail "$rc" "exit $rc" "$(printf '%s' "$out" | tail -n 40)"
  fi
done

# FIFTH check: fallow audit (dead code / duplication / complexity), scoped to the
# changeset and gated "new-only" — only findings INTRODUCED by this change fail
# (exit 1); pre-existing/inherited findings and warn-tier issues pass (exit 0).
# Exit 2 = fallow runtime/config error → recorded as skip, never a hard fail (an
# analysis-tool problem must not block the chain). The raw JSON report is saved
# next to the gate json (fallow.json) for the review surface + reviewer roles.
fcmd="$(sprint_fallow_cmd HEAD~1)"
if [ -z "$fcmd" ]; then
  add_record fallow "" skip "" "fallow off or not installed"
else
  first="$(printf '%s' "$fcmd" | awk '{print $1}')"
  if ! command -v "$first" >/dev/null 2>&1 && [ ! -x "$first" ]; then
    add_record fallow "$fcmd" skip "" "tool '$first' not on PATH"
  else
    out="$(eval "$fcmd" 2>&1)"; rc=$?
    [ "$OUT" != /dev/stdout ] && printf '%s\n' "$out" > "$(dirname "$OUT")/fallow.json" 2>/dev/null
    if [ "$rc" -eq 0 ]; then
      add_record fallow "$fcmd" pass "$rc" "ok (no introduced error-severity findings)"
    elif [ "$rc" -eq 2 ]; then
      add_record fallow "$fcmd" skip "$rc" "fallow runtime/config error — skipped"
    else
      verdict="fail"
      add_record fallow "$fcmd" fail "$rc" "introduced error-severity findings (exit $rc)" "$(printf '%s' "$out" | tail -n 40)"
    fi
  fi
fi

printf '{"iteration":%s,"stack":%s,"verdict":%s,"checks":[%s]}\n' \
  "${iter:-0}" "$(jstr "$stack")" "$(jstr "$verdict")" "$records" > "$OUT"

[ "$verdict" = pass ] && exit 0 || exit 1
