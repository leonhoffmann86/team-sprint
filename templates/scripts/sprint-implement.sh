#!/usr/bin/env bash
#
# sprint-implement.sh — STAGE 2 (IMPLEMENT) of the Sprint agent chain.
#
# Shell-driven subagent-team orchestrator. In an ISOLATED git worktree on the impl
# branch it runs: planner → navigator (once), then a bounded loop —
#   implementer → deterministic GATE (sprint-gate.sh) → reviewers — up to
# SPRINT_MAX_ITER times. Gate FAIL or blocker/major review findings loop back to the
# implementer with the findings as the fix list; otherwise the item is DONE. On loop
# exhaustion the work is escalated (🔎 pointer + AGENT_LOG; high-risk → 🚧 on branch).
# Never touches the working tree, never auto-merges.
#
# Each role is its OWN headless `claude -p` (separate calls, not Task-delegation) so
# the shell can run the deterministic gate BETWEEN phases and bound the loop. Roles get
# per-role permission flags (read-only reviewers via dontAsk; implementer via acceptEdits)
# plus hard deny-rules — see run_phase. Only gate.json is machine-trusted (shell-authored);
# agent JSON is read from gitignored sidecars in .sprint-state/ with jq-or-grep + fail-closed.
#
set -euo pipefail

# Git exports GIT_DIR/GIT_INDEX_FILE/… into post-commit hook subprocesses; clear
# them so our own git commands (esp. `git worktree add`) resolve paths against the
# working dir, not the hook's quarantined index — otherwise the worktree add fails.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_QUARANTINE_PATH 2>/dev/null || true

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
# shellcheck source=scripts/sprint-lib.sh
. "$ROOT/scripts/sprint-lib.sh"
sprint_load_config
sprint_mcp_flags   # model flags are resolved PER ROLE inside run_phase

[ -f "$ROOT/.git/autoplan.disabled" ] && exit 0
command -v claude >/dev/null 2>&1 || { echo "sprint-implement: claude CLI not found, skipping." >&2; exit 0; }

LOCKDIR="$ROOT/.git/sprint-implement.lock"
LOG="$ROOT/.git/sprint-implement.log"
RUNLOG="$ROOT/TODO.run.log"
# Sibling dir OUTSIDE the repo (and outside .git/): the agent permission layer
# auto-denies every write under a .git/ path, which silently broke all
# implementer runs (impl-error after 0 edits).
WT="$(dirname "$ROOT")/.sprint-worktree-$(basename "$ROOT")"
BR="${SPRINT_IMPL_BRANCH:-autoplan/impl}"

sprint_reap_stale_lock "$LOCKDIR" 30
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

ACTIVE="$(sprint_strip_skipped "$ROOT/TODO.md")"
PLAN="$( [ -f "$ROOT/TODO.autoplan.md" ] && cat "$ROOT/TODO.autoplan.md" || echo '(no plan available)' )"
DONE="$( [ -f "$ROOT/DONE.md" ] && cat "$ROOT/DONE.md" || echo '(empty)' )"

# Fresh worktree/branch from HEAD. Prune first so a stale registration left by a
# killed earlier run (dir gone but still recorded) can't block the add.
git worktree remove --force "$WT" 2>/dev/null || true
rm -rf "$WT"
git worktree prune 2>/dev/null || true
git worktree add -f -B "$BR" "$WT" HEAD >/dev/null 2>&1 || { echo "sprint-implement: worktree add failed" >&2; exit 0; }
# Symlink the venv (so tests run against worktree code) only if configured.
if [ -n "${SPRINT_VENV:-}" ] && [ -e "$ROOT/$SPRINT_VENV" ]; then
  ln -s "$ROOT/$SPRINT_VENV" "$WT/$SPRINT_VENV" 2>/dev/null || true
fi
# Symlink the fresh code-graph DB for caller/impact analysis, if present.
if [ "${SPRINT_CODEGRAPH:-auto}" != "off" ] && [ -f "$ROOT/.codegraph/codegraph.db" ]; then
  mkdir -p "$WT/.codegraph" 2>/dev/null || true
  ln -s "$ROOT/.codegraph/codegraph.db" "$WT/.codegraph/codegraph.db" 2>/dev/null || true
fi

# Role sidecars live in a state dir INSIDE the worktree, but excluded from commits
# (via the worktree's info/exclude) so the implementer's `git add` can never sweep them.
STATE_DIR="$WT/.sprint-state"
mkdir -p "$STATE_DIR"
# Cross-vendor degradations land here and are surfaced ❌ by sprint_findings_surface.
SPRINT_MODEL_FALLBACK_LOG="$STATE_DIR/model-fallbacks.log"
export SPRINT_MODEL_FALLBACK_LOG
EXCL="$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)"
[ -n "$EXCL" ] && { mkdir -p "$(dirname "$EXCL")" 2>/dev/null || true; grep -qxF '.sprint-state/' "$EXCL" 2>/dev/null || echo '.sprint-state/' >> "$EXCL"; }

AGENTS_DIR="$ROOT/.claude/agents"
DENY_JSON="$(sprint_deny_settings)"
sprint_timeout_cmd
sprint_stream_setup   # live tool-call trace flags (jq-gated; SPRINT_STREAM=off disables)

# One headless `claude -p` per role. AUTOPLAN_AGENT=1 is set HERE (never per call-site)
# so no role can recurse the post-commit hook. Per-role permission flags + the hard deny
# settings enforce read-only reviewers (dontAsk: only allowlisted tools run) and a
# commit-but-not-destructive implementer (acceptEdits + deny push/reset/rebase/rm -rf).
run_phase() {  # $1 = role, $2 = prompt → returns the claude/timeout exit code
  local role="$1" prompt="$2"
  local -a perm
  case "$role" in
    implementer)
      perm=(--permission-mode acceptEdits --allowed-tools "Read,Edit,Write,Glob,Grep,Bash(git add *),Bash(git commit *),Bash(git status *),Bash(git show *),Bash(git diff *),Bash(git mv *),Bash(npm *),Bash(npx *),Bash(pnpm *),Bash(yarn *),Bash(node *),Bash(pytest *),Bash(python *),Bash(python3 *),Bash(ruff *),Bash(mypy *),Bash(go *),Bash(cargo *),Bash(php *),Bash(composer *)") ;;
    *)   # planner / navigator / reviewers: read-only + sidecar write + read-only git
      perm=(--permission-mode dontAsk --allowed-tools "Read,Grep,Glob,Write,Bash(git show *),Bash(git log *),Bash(git diff *),mcp__codegraph__*") ;;
  esac
  sprint_runlog_stage "$RUNLOG" "IMPLEMENT/$role (branch $BR, iter ${ITER:-0})"
  # Per-role model resolution (SPRINT_MODEL_<ROLE> → SPRINT_MODEL → CLI default) —
  # must run PER PHASE, since each role may use a different model. Cross-vendor roles
  # additionally get ANTHROPIC_BASE_URL/_AUTH_TOKEN injected via `env` (per process,
  # never exported globally — sibling roles stay on the native API).
  sprint_model_flags "$role"
  # Live trace: with jq the phase streams every tool call into the run log
  # (sprint_stream_trace renders the NDJSON); `tail -f TODO.run.log` = live status.
  # NOTE: the trace filter runs in a pipeline subshell — it reads the role from a
  # SHELL variable, not from the env prefix of the claude process.
  # shellcheck disable=SC2034  # consumed by sprint_stream_trace (sourced lib).
  local SPRINT_TRACE_ROLE="$role"
  AUTOPLAN_AGENT=1 SPRINT_ITER="${ITER:-0}" \
    env ${SPRINT_MODEL_ENV[@]+"${SPRINT_MODEL_ENV[@]}"} \
    ${SPRINT_TIMEOUT[@]+"${SPRINT_TIMEOUT[@]}"} \
    claude -p "$prompt" \
      --append-system-prompt "$(sprint_agent_body "$AGENTS_DIR/$role.md")" \
      "${perm[@]}" \
      --settings "$DENY_JSON" \
      ${SPRINT_MCP_FLAGS[@]+"${SPRINT_MCP_FLAGS[@]}"} \
      ${SPRINT_MODEL_FLAGS[@]+"${SPRINT_MODEL_FLAGS[@]}"} \
      ${SPRINT_STREAM_FLAGS[@]+"${SPRINT_STREAM_FLAGS[@]}"} \
      2>&1 | sprint_stream_trace | tee -a "$RUNLOG" >>"$LOG"
}

cd "$WT"
echo "→ Implementation running on branch ${BR} (worktree, subagent team) …"

# --- Phase A/B: plan + navigate (once; advisory sidecars → fail-open) ---
PLANNER_PROMPT="$(sprint_preamble)

You are planning the ACTIVE TODO item(s) below for autonomous implementation on branch ${BR}.
Write your plan JSON to: .sprint-state/plan.json

ACTIVE TODO item(s):
${ACTIVE}

Existing non-binding suggestions (TODO.autoplan.md):
${PLAN}

Already done (skip these):
${DONE}"

NAV_PROMPT="$(sprint_preamble)

For the ACTIVE TODO item(s) and the plan in .sprint-state/plan.json, gather code intelligence.
Write your navigation JSON to: .sprint-state/navigation.json

ACTIVE TODO item(s):
${ACTIVE}"

ITER=0
run_phase planner   "$PLANNER_PROMPT" || sprint_runlog_note "$RUNLOG" "planner phase failed — continuing without plan"
run_phase navigator "$NAV_PROMPT"     || sprint_runlog_note "$RUNLOG" "navigator phase failed — continuing without navigation"

# --- The bounded implement ↔ gate ↔ review loop (convergence guaranteed by the cap) ---
STATUS="pending"
while [ "$ITER" -lt "${SPRINT_MAX_ITER:-3}" ]; do
  ITER=$((ITER + 1))

  FIXCTX=""
  if [ "$ITER" -gt 1 ]; then
    # `|| true` is load-bearing: a glob with no match (no review json yet, e.g. after a
    # gate-only loopback) makes `cat` exit non-zero, which would fail this assignment and —
    # under `set -e` — kill the orchestrator mid-loop.
    FIXCTX="This is loopback iteration ${ITER}. FIX ONLY the findings below, then amend/re-commit
the single item commit. Do not change unrelated code.

[deterministic gate findings — .sprint-state/gate.json]
$(cat "$STATE_DIR/gate.json" 2>/dev/null || true)

[fallow static analysis (dead code/duplication/complexity) — .sprint-state/fallow.json]
$(cat "$STATE_DIR/fallow.json" 2>/dev/null || true)

[reviewer findings]
$(cat "$STATE_DIR"/review-*.json 2>/dev/null || true)
"
  fi
  IMPL_PROMPT="$(sprint_preamble)

Implement the ACTIVE TODO item(s) on branch ${BR} in this worktree.
Plan: .sprint-state/plan.json   Navigation (conventions to follow): .sprint-state/navigation.json
${FIXCTX}
ACTIVE TODO item(s):
${ACTIVE}

Already done (skip these):
${DONE}"

  if ! run_phase implementer "$IMPL_PROMPT"; then
    sprint_runlog_note "$RUNLOG" "implementer phase errored (iter $ITER) — escalating"
    STATUS="impl-error"; break
  fi

  # Deterministic GATE (pure shell). A FAIL exit is DATA (handled), never a crash.
  if SPRINT_ITER="$ITER" "$ROOT/scripts/sprint-gate.sh" "$WT" "$STATE_DIR/gate.json"; then
    sprint_runlog_note "$RUNLOG" "gate PASS (iter $ITER)"
  else
    sprint_runlog_note "$RUNLOG" "gate FAIL (iter $ITER): $(sprint_gate_summary "$STATE_DIR/gate.json")"
    STATUS="gate-fail"; continue
  fi

  # Reviewers (only if enabled). Missing/garbled review json → fail-closed (loopback).
  if [ "${SPRINT_REVIEW_AUTONOMOUS:-1}" = "1" ]; then
    rm -f "$STATE_DIR"/review-*.json
    REV_BASE="$(sprint_preamble)

The deterministic gate is already GREEN — do not re-run it. Review the latest commit on
branch ${BR}. Plan: .sprint-state/plan.json   Navigation: .sprint-state/navigation.json
If .sprint-state/fallow.json exists, read it too (deterministic fallow static analysis:
dead code, duplication, complexity for this change) and fold relevant findings into
your verdict — it is part of this review.
ACTIVE TODO item(s):
${ACTIVE}"
    REV_PROMPT_CORRECTNESS="${REV_BASE}

Write your verdict JSON to: .sprint-state/review-correctness.json"
    REV_PROMPT_CONVENTIONS="${REV_BASE}

Write your verdict JSON to: .sprint-state/review-conventions.json"
    run_phase reviewer-correctness "$REV_PROMPT_CORRECTNESS" \
      || sprint_runlog_note "$RUNLOG" "reviewer-correctness phase errored (iter $ITER)"
    run_phase reviewer-conventions "$REV_PROMPT_CONVENTIONS" \
      || sprint_runlog_note "$RUNLOG" "reviewer-conventions phase errored (iter $ITER)"

    # Cross-vendor SAFETY NET: a foreign reviewer whose verdict sidecar is missing or
    # unparseable gets ONE retry on the Claude chain before fail-closed kicks in — a
    # JSON-untrue foreign model degrades to a Claude review instead of a permanent
    # loopback. The degradation is recorded (→ ❌ surface) so it is fixed, not hidden.
    for rrole in reviewer-correctness reviewer-conventions; do
      rfile="$STATE_DIR/review-${rrole#reviewer-}.json"
      if sprint_model_is_xvendor "$rrole" && ! sprint_review_parseable "$rfile"; then
        sprint_model_fallback_note "$rrole" "cross-vendor verdict missing/unparseable (iter $ITER) — one-shot Claude retry"
        case "$rrole" in
          reviewer-correctness) SPRINT_FORCE_CLAUDE=1 run_phase "$rrole" "$REV_PROMPT_CORRECTNESS" || true ;;
          reviewer-conventions) SPRINT_FORCE_CLAUDE=1 run_phase "$rrole" "$REV_PROMPT_CONVENTIONS" || true ;;
        esac
        # Var-prefix before a FUNCTION call may persist in some bash modes — make
        # sure the force never leaks into later phases/iterations.
        unset SPRINT_FORCE_CLAUDE
      fi
    done
    SEV="$(sprint_review_max_severity "$STATE_DIR/review-correctness.json" "$STATE_DIR/review-conventions.json")"
    if [ "$SEV" = blocker ] || [ "$SEV" = major ]; then
      sprint_runlog_note "$RUNLOG" "review loopback (iter $ITER): max severity ${SEV}"
      STATUS="review-fail"; continue
    fi
  fi

  STATUS="done"; break
done

# --- Surface + teardown (back in the main repo) ---
cd "$ROOT"
IMPL_SHA="$(git rev-parse --short "$BR" 2>/dev/null || echo '')"
SHA="${IMPL_SHA:-$BR}"   # label used by the review surface

# Delivery: with SPRINT_DELIVERY=apply, FULLY converged work is staged into the
# user's working tree (git merge --squash — IDE-native review, the USER commits).
# Anything else stays on the branch; the fallback reason is surfaced, never silent.
# Computed BEFORE the findings surface so the ✅/⚠️ line counts into the traffic light
# (rendered as "### Delivery" by sprint_findings_surface via SPRINT_DELIVERY_MD).
SPRINT_DELIVERY_MD=""
if [ "${SPRINT_DELIVERY:-branch}" = "apply" ] && [ "$STATUS" = "done" ]; then
  if APPLY_REASON="$(sprint_apply_impl "$ROOT" "$BR")"; then
    SPRINT_DELIVERY_MD="✅ delivery: applied as STAGED changes in your working tree — review in the IDE, then commit yourself (branch ${BR} kept as backup until the next run)"
  else
    SPRINT_DELIVERY_MD="⚠️ delivery: ${APPLY_REASON} — review via \`git log ${BR}\`, then merge or discard"
  fi
elif [ "${SPRINT_DELIVERY:-branch}" = "apply" ]; then
  SPRINT_DELIVERY_MD="⚠️ delivery: not converged (status: ${STATUS}) — nothing applied; work stays on ${BR}"
fi
export SPRINT_DELIVERY_MD

# Stage-1 handoff (NEEDS_HUMAN): explicit CTAs with the pre-merge SHA recorded, so
# testing and rolling back never require looking up a branch name or SHA. Only in
# branch mode — apply mode already lands the diff in the working tree.
SPRINT_HANDOFF_MD=""
if [ "$STATUS" = "done" ] && [ "${SPRINT_DELIVERY:-branch}" != "apply" ]; then
  HANDOFF_REPLY="$(jq -r '.reporter_reply // empty' "$STATE_DIR/review-correctness.json" 2>/dev/null || true)"
  SPRINT_HANDOFF_MD="$(sprint_handoff_block "$ROOT" "$BR" "$HANDOFF_REPLY")"
fi
export SPRINT_HANDOFF_MD

# Publish TODO.review.md (✅/⚠️/❌) from the structured artifacts, then run the existing
# surface (## 🔎 pointer into TODO.md + AGENT_LOG + notify) — reused verbatim.
if [ -f "$STATE_DIR/gate.json" ]; then
  shopt -s nullglob
  REVFILES=("$STATE_DIR"/review-*.json)
  shopt -u nullglob
  sprint_findings_surface "$STATE_DIR/gate.json" ${REVFILES[@]+"${REVFILES[@]}"} | tee -a "$RUNLOG" || true
fi

if [ "$STATUS" != "done" ]; then
  sprint_runlog_note "$RUNLOG" "item(s) NOT converged (status=${STATUS}) after ${ITER}/${SPRINT_MAX_ITER:-3} iteration(s) — left on ${BR}; see TODO.review.md"
  [ -f "$ROOT/AGENT_LOG.md" ] && printf '\n## [%s] Sprint implement %s — not converged (%s) after %s iteration(s); see TODO.review.md\n' \
    "$(date '+%Y-%m-%d %H:%M')" "$SHA" "$STATUS" "$ITER" >> "$ROOT/AGENT_LOG.md"
fi

# Keep the branch (commits persist in the repo); drop the worktree dir. NOTE: this is a
# hard -B reset of the branch each run — up to SPRINT_MAX_ITER unmerged commits now ride on
# it, so merge or discard the branch promptly (never auto-merged on purpose).
git worktree remove --force "$WT" 2>/dev/null || true

sprint_runlog_stage "$RUNLOG" "RESULT — commits on ${BR}"
git log --oneline "$BR" --not HEAD 2>/dev/null | sed 's/^/  /' >> "$RUNLOG" || true
[ -n "$SPRINT_DELIVERY_MD" ] && sprint_runlog_note "$RUNLOG" "$SPRINT_DELIVERY_MD"
case "$SPRINT_DELIVERY_MD" in
  "✅ delivery:"*) echo "✓ Implementation finished (status: ${STATUS}) — result is STAGED in your working tree: review the changes in your IDE, then commit." ;;
  *)              echo "✓ Implementation finished on branch ${BR} (status: ${STATUS}). Review: git log ${BR} — then merge or discard." ;;
esac

exit 0
