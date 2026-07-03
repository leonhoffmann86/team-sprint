#!/usr/bin/env bash
#
# sprint-lib.sh — shared helpers for the Sprint plan→implement→review hook chain.
# Sourced by sprint-plan.sh, sprint-implement.sh, sprint-review.sh.
#
# Conventions used across the chain:
#   - AUTOPLAN_AGENT=1 in the environment means "this process / its git commits
#     are agent-driven" → the post-commit hook skips, preventing recursion.
#   - The skip convention for TODO.md: items inside <!-- … --> HTML comments, or
#     under a "## 🚧" heading (e.g. "## 🚧 Deferred"), are NOT planned/implemented.

# Repo root (works from a worktree too).
SPRINT_ROOT="$(git rev-parse --show-toplevel)"

# Config defaults, then override from the repo's sprint.conf if present.
# shellcheck disable=SC2034  # these knobs are consumed by the sourcing stage scripts.
sprint_load_config() {
  SPRINT_REVIEW_DIRS="src tests"
  SPRINT_TEST_CMD="echo 'no test command configured' && false"
  SPRINT_CONSTITUTION_FILES="AGENTS.md"
  SPRINT_IMPL_BRANCH="autoplan/impl"
  SPRINT_DELIVERY="branch"       # branch (leave on impl branch) | apply (stage into working tree)
  SPRINT_VENV=""
  SPRINT_CODEGRAPH="auto"
  SPRINT_MODEL=""
  # Per-role model overrides (empty = fall back to SPRINT_MODEL → CLI default).
  SPRINT_MODEL_PLAN=""
  SPRINT_MODEL_PLANNER=""
  SPRINT_MODEL_NAVIGATOR=""
  SPRINT_MODEL_IMPLEMENTER=""
  SPRINT_MODEL_REVIEWER_CORRECTNESS=""
  SPRINT_MODEL_REVIEWER_CONVENTIONS=""
  SPRINT_MODEL_REVIEW=""
  SPRINT_PROXY_URL=""             # Anthropic-compatible translating proxy (cross-vendor models)
  SPRINT_PROXY_TOKEN=""           # proxy auth token — set in ~/.config/sprint/env, NOT in the repo
  SPRINT_REVIEW_AUTONOMOUS="1"
  SPRINT_NOTIFY="0"
  # --- Subagent-team + deterministic-gate block (kept in sync with sprint.conf) ---
  SPRINT_STACK="auto"            # auto | nextjs | react | node | python | php | go | rust
  SPRINT_GATE_LINT=""            # empty → resolved from the detected stack (or skipped)
  SPRINT_GATE_TYPECHECK=""
  SPRINT_GATE_TEST=""            # empty → falls back to SPRINT_TEST_CMD
  SPRINT_GATE_BUILD=""
  SPRINT_FALLOW="auto"           # fallow static analysis: auto (run if installed) | off
  SPRINT_FALLOW_CMD=""           # empty → built-in `fallow audit` default ({base} placeholder)
  SPRINT_MAX_ITER="3"            # bounded implement↔gate↔review loop (convergence guarantee)
  SPRINT_PHASE_TIMEOUT="600"     # per-phase `claude -p` timeout in seconds (bounds lock hold)
  SPRINT_STREAM="auto"           # live tool-call trace in TODO.run.log: auto (needs jq) | off
  SPRINT_VISUAL_MAX_DIFF_RATIO="0.02"   # stage 2 (visual reviewer)
  SPRINT_DEV_URL="http://localhost:3000"  # stage 2 (visual reviewer)
  # shellcheck source=/dev/null
  [ -f "$SPRINT_ROOT/sprint.conf" ] && . "$SPRINT_ROOT/sprint.conf"
  # Machine-local secrets/overrides (never committed): may set SPRINT_PROXY_TOKEN etc.
  # Sourced AFTER the repo conf so secrets stay out of the repo and win over it.
  # shellcheck source=/dev/null
  [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/sprint/env" ] && . "${XDG_CONFIG_HOME:-$HOME/.config}/sprint/env"
  return 0
}

# Mandatory prompt preamble: every agent reads the project constitution first.
# Generic across projects — the actual conventions live in the constitution files.
sprint_preamble() {
  local files="${SPRINT_CONSTITUTION_FILES:-AGENTS.md}"
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
sprint_strip_skipped() {
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
sprint_reap_stale_lock() {
  local lockdir="$1" minutes="${2:-15}"
  if [ -d "$lockdir" ] && [ -z "$(find "$lockdir" -prune -mmin -"$minutes" 2>/dev/null)" ]; then
    rmdir "$lockdir" 2>/dev/null || true
  fi
}

# True if the chain is globally disabled or this is an agent commit.
sprint_should_skip() {
  [ -n "${AUTOPLAN_AGENT:-}" ] && return 0
  [ -f "$SPRINT_ROOT/.git/autoplan.disabled" ] && return 0
  return 1
}

# Build model flag + env arrays for a headless claude call (both empty if no override).
# Usage: sprint_model_flags [role]
#        env ${SPRINT_MODEL_ENV[@]+"${SPRINT_MODEL_ENV[@]}"} claude … "${SPRINT_MODEL_FLAGS[@]}"
# Role-aware resolution: SPRINT_MODEL_<ROLE> (role uppercased, "-" → "_", e.g.
# reviewer-correctness → SPRINT_MODEL_REVIEWER_CORRECTNESS) → SPRINT_MODEL (global)
# → empty (CLI default). Without a role argument it behaves exactly as before.
#
# CROSS-VENDOR: a value of the form "openrouter:<vendor>/<model>" runs the role on a
# non-Claude model behind the Anthropic-compatible proxy SPRINT_PROXY_URL (e.g.
# LiteLLM /v1/messages): SPRINT_MODEL_ENV gets ANTHROPIC_BASE_URL (+ AUTH_TOKEN),
# --model carries the part after the prefix, SPRINT_MODEL_XVENDOR=1. GRACEFUL + LOUD:
# proxy unconfigured/unreachable → fall back to the Claude chain AND record the
# degradation via sprint_model_fallback_note (surfaced ❌, never silent).
# SPRINT_FORCE_CLAUDE=1 ignores the prefix (the garbled-JSON retry path; the caller
# records the reason, so this branch stays quiet).
# shellcheck disable=SC2034  # the SPRINT_MODEL_* results are consumed by the caller.
sprint_model_flags() {
  SPRINT_MODEL_FLAGS=(); SPRINT_MODEL_ENV=(); SPRINT_MODEL_XVENDOR=0
  local role="${1:-}" var model="" xmodel
  if [ -n "$role" ]; then
    var="SPRINT_MODEL_$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
    model="${!var:-}"
  fi
  [ -n "$model" ] || model="${SPRINT_MODEL:-}"
  case "$model" in
    openrouter:*)
      xmodel="${model#openrouter:}"
      if [ -n "${SPRINT_FORCE_CLAUDE:-}" ]; then
        model="${SPRINT_MODEL:-}"; case "$model" in openrouter:*) model="";; esac
      elif [ -z "${SPRINT_PROXY_URL:-}" ]; then
        sprint_model_fallback_note "${role:-global}" "'$xmodel' configured but SPRINT_PROXY_URL is empty"
        model="${SPRINT_MODEL:-}"; case "$model" in openrouter:*) model="";; esac
      elif command -v curl >/dev/null 2>&1 && ! curl -s -o /dev/null --max-time 2 "$SPRINT_PROXY_URL" 2>/dev/null; then
        sprint_model_fallback_note "${role:-global}" "proxy $SPRINT_PROXY_URL unreachable — '$xmodel' skipped"
        model="${SPRINT_MODEL:-}"; case "$model" in openrouter:*) model="";; esac
      else
        SPRINT_MODEL_XVENDOR=1
        SPRINT_MODEL_ENV=("ANTHROPIC_BASE_URL=$SPRINT_PROXY_URL")
        [ -n "${SPRINT_PROXY_TOKEN:-}" ] && SPRINT_MODEL_ENV+=("ANTHROPIC_AUTH_TOKEN=$SPRINT_PROXY_TOKEN")
        model="$xmodel"
      fi
      ;;
  esac
  [ -n "$model" ] && SPRINT_MODEL_FLAGS=(--model "$model")
  return 0
}

# True (0) if the role's RAW configured model requests a cross-vendor run (before
# any graceful fallback). Used by the implement loop's safety-net retry.
sprint_model_is_xvendor() {
  local role="${1:-}" var v=""
  if [ -n "$role" ]; then
    var="SPRINT_MODEL_$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
    v="${!var:-}"
  fi
  [ -n "$v" ] || v="${SPRINT_MODEL:-}"
  case "$v" in openrouter:*) return 0;; *) return 1;; esac
}

# Record a model degradation: a configured cross-vendor model did NOT run. Appends
# to $SPRINT_MODEL_FALLBACK_LOG (set by the stage scripts) and echoes to stderr.
# The log is surfaced as ❌ lines in TODO.review.md (→ 🔎 pointer + AGENT_LOG +
# optional notify) — degradation must be VISIBLE, never silent.
sprint_model_fallback_note() {  # $1 = role, $2 = reason
  local line; line="$(date '+%Y-%m-%d %H:%M') ${1}: ${2}"
  [ -n "${SPRINT_MODEL_FALLBACK_LOG:-}" ] && printf '%s\n' "$line" >> "$SPRINT_MODEL_FALLBACK_LOG" 2>/dev/null
  printf 'sprint: model fallback — %s\n' "$line" >&2
  return 0
}

# model-fallbacks.log → ❌ markdown lines for TODO.review.md.
sprint_model_fallbacks_to_md() {
  local f="$1"
  [ -s "$f" ] || return 0
  sed 's/^/❌ model-fallback: /' "$f"
  printf -- '- a configured cross-vendor model did NOT review this change — fix the proxy/config (sprint.conf: SPRINT_PROXY_URL, docs/CROSS-VENDOR.md)\n'
}

# Tool availability → ✅/⚠️ markdown lines for the "### Tooling" section of
# TODO.review.md. The chain DEGRADES gracefully when supporting tools are missing,
# but degradation must be REPORTED, never silent — codegraph and fallow are core to
# the plugin's review quality ("tool use is the product"). ⚠️ lines count into the
# report's traffic-light summary; deliberate `off` config shows as a neutral note.
sprint_tooling_to_md() {  # $1 = repo root (default: $ROOT/$SPRINT_ROOT)
  local root="${1:-${ROOT:-$SPRINT_ROOT}}"
  # codegraph — code intelligence for navigator/planner/reviewers
  if [ "${SPRINT_CODEGRAPH:-auto}" = off ]; then
    printf -- '- codegraph: disabled (SPRINT_CODEGRAPH=off)\n'
  elif ! command -v codegraph >/dev/null 2>&1; then
    printf '⚠️ codegraph: NOT installed — roles ran without code-graph intelligence (install: https://github.com/colbymchenry/codegraph)\n'
  elif [ ! -f "$root/.codegraph/codegraph.db" ]; then
    printf '⚠️ codegraph: installed but no index in this repo — run `codegraph sync .` once (the hook keeps it fresh afterwards)\n'
  else
    printf '✅ codegraph: active (index present)\n'
  fi
  # fallow — static-analysis gate check
  if [ "${SPRINT_FALLOW:-auto}" = off ]; then
    printf -- '- fallow: disabled (SPRINT_FALLOW=off)\n'
  elif [ -n "${SPRINT_FALLOW_CMD:-}" ] || [ -n "$(sprint_fallow_bin)" ]; then
    printf '✅ fallow: active\n'
  else
    printf '⚠️ fallow: NOT installed — gate ran without dead-code/duplication/complexity analysis (install: npm i -g fallow · https://docs.fallow.tools)\n'
  fi
  # helpers whose absence silently degrades parsing/timeouts
  if command -v jq >/dev/null 2>&1; then
    printf '✅ jq: present\n'
  else
    printf '⚠️ jq: missing — JSON verdicts fall back to grep parsing AND the run log loses the live activity trace (brew install jq)\n'
  fi
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    printf '✅ timeout: present\n'
  else
    printf '⚠️ timeout: missing — headless phases run without a per-phase timeout (macOS: brew install coreutils)\n'
  fi
  # curl — proxy reachability probe; only reported when cross-vendor is configured
  if sprint_any_xvendor; then
    if command -v curl >/dev/null 2>&1; then
      printf '✅ curl: present (cross-vendor proxy probe active)\n'
    else
      printf '⚠️ curl: missing — the cross-vendor proxy cannot be probed before a phase (degradations surface only after the run)\n'
    fi
  fi
  # notifier — only reported when notifications are switched on
  if [ "${SPRINT_NOTIFY:-0}" = "1" ]; then
    if command -v terminal-notifier >/dev/null 2>&1 || command -v notify-send >/dev/null 2>&1; then
      printf '✅ notifier: present\n'
    else
      printf '⚠️ notifier: SPRINT_NOTIFY=1 but neither terminal-notifier nor notify-send is installed — desktop notifications silently dropped\n'
    fi
  fi
}

# True (0) if ANY configured model (global or per-role/stage) requests a cross-vendor
# run — used to decide whether proxy-related tooling (curl) is worth reporting.
sprint_any_xvendor() {
  local v
  for v in "${SPRINT_MODEL:-}" "${SPRINT_MODEL_PLAN:-}" "${SPRINT_MODEL_PLANNER:-}" \
           "${SPRINT_MODEL_NAVIGATOR:-}" "${SPRINT_MODEL_IMPLEMENTER:-}" \
           "${SPRINT_MODEL_REVIEWER_CORRECTNESS:-}" "${SPRINT_MODEL_REVIEWER_CONVENTIONS:-}" \
           "${SPRINT_MODEL_REVIEW:-}"; do
    case "$v" in openrouter:*) return 0;; esac
  done
  return 1
}

# True (0) if a review sidecar holds parseable JSON with a recognizable verdict —
# the precondition for SKIPPING the cross-vendor safety-net retry.
sprint_review_parseable() {
  local f="$1"
  [ -s "$f" ] || return 1
  if command -v jq >/dev/null 2>&1; then jq -e . "$f" >/dev/null 2>&1 || return 1; fi
  grep -Eq '"severity"[[:space:]]*:[[:space:]]*"(blocker|major|minor)"|"verdict"[[:space:]]*:[[:space:]]*"pass"' "$f"
}

# Human-visible run log in the repo root (gitignored): TODO.run.log. Unlike the
# per-stage .git/sprint-*.log files, this is one consolidated, root-level trace you
# can `tail -f`. Reset at the start of each trigger; each stage appends a header
# and tees its agent output into it.
sprint_runlog_reset() {  # $1 = path to TODO.run.log
  { printf '# Sprint run — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# overwritten on each trigger · follow with: tail -f TODO.run.log\n'; } > "$1"
}
sprint_runlog_stage() {  # $1 = path, $2 = stage label
  printf '\n===== %s — %s =====\n' "$2" "$(date '+%H:%M:%S')" >> "$1"
}
sprint_runlog_note() {   # $1 = path, $2 = message
  printf '— %s\n' "$2" >> "$1"
}

# ============================================================================
# Subagent-team + deterministic-gate helpers (used by sprint-implement.sh and
# sprint-gate.sh). All degrade gracefully: missing tools → skip, not crash.
# ============================================================================

# Detect the project stack from marker files in $1 (default cwd).
sprint_detect_stack() {
  local d="${1:-.}"
  if [ -f "$d/next.config.js" ] || [ -f "$d/next.config.mjs" ] || [ -f "$d/next.config.ts" ]; then echo nextjs; return; fi
  if [ -f "$d/package.json" ]; then
    if grep -q '"react"' "$d/package.json" 2>/dev/null; then echo react; else echo node; fi; return
  fi
  if [ -f "$d/pyproject.toml" ] || [ -f "$d/setup.py" ] || [ -f "$d/setup.cfg" ]; then echo python; return; fi
  if [ -f "$d/composer.json" ]; then echo php; return; fi
  if [ -f "$d/go.mod" ]; then echo go; return; fi
  if [ -f "$d/Cargo.toml" ]; then echo rust; return; fi
  echo unknown
}

# Resolve a gate command for a check (lint|typecheck|test|build). Echoes a command
# template (may contain the {path} placeholder) or empty (→ the gate skips it).
# Priority: explicit SPRINT_GATE_<CHECK> → (test only) legacy SPRINT_TEST_CMD →
# built-in per-stack default. SPRINT_STACK=auto → detect from marker files.
sprint_gate_cmd() {
  local check="$1" stack explicit
  case "$check" in
    lint)      explicit="${SPRINT_GATE_LINT:-}";;
    typecheck) explicit="${SPRINT_GATE_TYPECHECK:-}";;
    test)      explicit="${SPRINT_GATE_TEST:-}";;
    build)     explicit="${SPRINT_GATE_BUILD:-}";;
    *) return 0;;
  esac
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
  if [ "$check" = test ] && [ -n "${SPRINT_TEST_CMD:-}" ] \
     && [ "$SPRINT_TEST_CMD" != "echo 'no test command configured' && false" ]; then
    printf '%s' "$SPRINT_TEST_CMD"; return 0
  fi
  stack="${SPRINT_STACK:-auto}"; [ "$stack" = auto ] && stack="$(sprint_detect_stack)"
  case "${stack}:${check}" in
    nextjs:lint)      printf '%s' 'npm run -s lint';;
    nextjs:typecheck) printf '%s' 'npx -y tsc --noEmit';;
    nextjs:test)      printf '%s' 'npm test --silent';;
    nextjs:build)     printf '%s' 'npm run -s build';;
    react:lint)       printf '%s' 'npm run -s lint';;
    react:typecheck)  printf '%s' 'npx -y tsc --noEmit';;
    react:test)       printf '%s' 'npm test --silent';;
    node:lint)        printf '%s' 'npm run -s lint';;
    node:test)        printf '%s' 'npm test --silent';;
    python:lint)      printf '%s' 'ruff check {path}';;
    python:typecheck) printf '%s' 'mypy {path}';;
    python:test)      printf '%s' 'pytest {path} -q';;
    php:lint)         printf '%s' 'vendor/bin/phpcs {path}';;
    php:typecheck)    printf '%s' 'vendor/bin/phpstan analyse {path}';;
    php:test)         printf '%s' 'vendor/bin/pest';;
    go:lint)          printf '%s' 'gofmt -l .';;
    go:test)          printf '%s' 'go test ./...';;
    rust:lint)        printf '%s' 'cargo clippy -- -D warnings';;
    rust:test)        printf '%s' 'cargo test';;
    rust:build)       printf '%s' 'cargo build';;
    *) return 0;;   # no built-in for this (stack,check) → skip
  esac
}

# Resolve the fallow binary (https://docs.fallow.tools — dead code / duplication /
# complexity analysis). Echoes the binary (PATH name or ./node_modules/.bin path
# relative to the CALLER's cwd) or nothing when disabled/not installed. Deliberately
# never `npx fallow`: the gate is offline-deterministic, so only an already-installed
# fallow runs — graceful no-op otherwise.
sprint_fallow_bin() {
  [ "${SPRINT_FALLOW:-auto}" = off ] && return 0
  if command -v fallow >/dev/null 2>&1; then printf 'fallow'; return 0; fi
  [ -x "./node_modules/.bin/fallow" ] && printf '%s' './node_modules/.bin/fallow'
  return 0
}

# Resolve the full fallow command for a given base ref ($1, default HEAD~1).
# Echoes the command or nothing (→ the caller skips). Priority: SPRINT_FALLOW=off →
# empty; explicit SPRINT_FALLOW_CMD (with {base} substituted) → built-in default:
# `fallow audit` scoped to the changeset, "new-only" gate, JSON to stdout.
sprint_fallow_cmd() {
  [ "${SPRINT_FALLOW:-auto}" = off ] && return 0
  local base="${1:-HEAD~1}" bin
  if [ -n "${SPRINT_FALLOW_CMD:-}" ]; then
    printf '%s' "${SPRINT_FALLOW_CMD//\{base\}/$base}"; return 0
  fi
  bin="$(sprint_fallow_bin)"
  [ -n "$bin" ] || return 0
  printf '%s audit --base %s --gate new-only --format json --quiet' "$bin" "$base"
}

# fallow.json (audit --format json) → one ✅/⚠️/❌ markdown line for TODO.review.md.
# Report-only consumer, so FAIL-OPEN: a missing file just means fallow didn't run
# (off / not installed) — the gate already enforced the verdict where it matters.
sprint_fallow_to_md() {
  local f="$1"
  [ -s "$f" ] || { printf -- '- fallow: not run (disabled or not installed)\n'; return; }
  if command -v jq >/dev/null 2>&1 && jq -e . "$f" >/dev/null 2>&1; then
    jq -r '
      (if .verdict=="pass" then "✅" elif .verdict=="warn" then "⚠️" else "❌" end)
      + " fallow: " + (.verdict // "?")
      + " — introduced: dead-code " + ((.attribution.dead_code_introduced // 0)|tostring)
      + ", complexity " + ((.attribution.complexity_introduced // 0)|tostring)
      + ", duplication " + ((.attribution.duplication_introduced // 0)|tostring)
      + " (" + ((.changed_files_count // 0)|tostring) + " changed files; details: .sprint-state/fallow.json)"' "$f"
  elif grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"fail"' "$f"; then
    printf '❌ fallow: error-severity findings (see fallow.json)\n'
  elif grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"warn"' "$f"; then
    printf '⚠️ fallow: warn-severity findings (see fallow.json)\n'
  elif grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"pass"' "$f"; then
    printf '✅ fallow: clean\n'
  else
    printf '⚠️ fallow: unrecognizable report\n'
  fi
}

# Build an --mcp-config flag array for headless claude (empty if no vendored config
# or codegraph disabled). Usage: sprint_mcp_flags; claude … "${SPRINT_MCP_FLAGS[@]}"
# shellcheck disable=SC2034  # SPRINT_MCP_FLAGS is consumed by the caller.
sprint_mcp_flags() {
  SPRINT_MCP_FLAGS=()
  if [ "${SPRINT_CODEGRAPH:-auto}" != off ] && [ -f "$SPRINT_ROOT/.mcp.json" ]; then
    SPRINT_MCP_FLAGS=(--mcp-config "$SPRINT_ROOT/.mcp.json")
  fi
  return 0
}

# Build a timeout prefix array for each headless phase (empty if no timeout tool —
# graceful no-op). macOS ships no `timeout`; use `gtimeout` (coreutils) if present.
# Usage: sprint_timeout_cmd; "${SPRINT_TIMEOUT[@]}" claude …
# shellcheck disable=SC2034  # SPRINT_TIMEOUT is consumed by the caller.
sprint_timeout_cmd() {
  SPRINT_TIMEOUT=()
  local t="${SPRINT_PHASE_TIMEOUT:-600}"
  if   command -v timeout  >/dev/null 2>&1; then SPRINT_TIMEOUT=(timeout "$t")
  elif command -v gtimeout >/dev/null 2>&1; then SPRINT_TIMEOUT=(gtimeout "$t")
  fi
  return 0
}

# Live activity trace: decide whether headless phases stream their tool calls.
# Sets SPRINT_STREAM_FLAGS (extra claude flags) and SPRINT_STREAM_ACTIVE (consumed
# by sprint_stream_trace). Streaming needs jq to render the NDJSON events; without
# jq (or SPRINT_STREAM=off) everything behaves exactly as before — the phase is
# silent until it finishes. The per-phase timeout still bounds every run.
# shellcheck disable=SC2034  # results are consumed by the stage scripts.
sprint_stream_setup() {
  SPRINT_STREAM_FLAGS=(); SPRINT_STREAM_ACTIVE=""
  if [ "${SPRINT_STREAM:-auto}" != off ] && command -v jq >/dev/null 2>&1; then
    SPRINT_STREAM_FLAGS=(--output-format stream-json --verbose)
    SPRINT_STREAM_ACTIVE=1
  fi
  return 0
}

# Convert `claude -p --output-format stream-json` NDJSON into terse LIVE activity
# lines — without this the run log is silent for a whole phase ("hung or working?").
# Inactive (no jq / SPRINT_STREAM=off) → pure passthrough. Non-JSON lines (stderr,
# e.g. real errors) stay visible verbatim; uninteresting events are dropped.
sprint_stream_trace() {  # stdin → stdout; role label via $SPRINT_TRACE_ROLE
  if [ -z "${SPRINT_STREAM_ACTIVE:-}" ]; then cat; return 0; fi
  jq -rR --unbuffered --arg role "${SPRINT_TRACE_ROLE:-agent}" '
    (fromjson? // null) as $e
    | if $e == null then .
      elif $e.type == "assistant" then
        ($e.message.content[]? | select(.type == "tool_use")
          | "  ⚙ \($role) → \(.name): " +
            ((.input.file_path // .input.command // .input.pattern // .input.description // "")
             | tostring | gsub("\n"; " ") | .[0:110]))
      elif $e.type == "result" then
        "  ✔ \($role) done — \(($e.num_turns // "?") | tostring) turns: " +
        (($e.result // "") | tostring | gsub("\n"; " ") | .[0:200])
      else empty end' 2>/dev/null || cat
}

# Hard deny-rules for every headless role, as a --settings JSON string. Deny is
# evaluated first (deny→ask→allow) and cannot be re-allowed by any layer — so this
# blocks destructive/remote git + rm -rf + spontaneous Agent/Task spawns regardless
# of the per-role --allowed-tools or permission-mode.
sprint_deny_settings() {
  printf '%s' '{"permissions":{"deny":["Bash(git push *)","Bash(git reset --hard *)","Bash(git rebase *)","Bash(rm -rf *)","Task","Agent"]}}'
}

# Print an agent .md body WITHOUT its YAML frontmatter (the header is config for
# interactive subagent loading; headless --append-system-prompt must not see it as
# literal noise). Files without frontmatter are printed verbatim.
sprint_agent_body() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk 'NR==1 && $0 !~ /^---[[:space:]]*$/ {plain=1} plain{print; next} /^---[[:space:]]*$/{c++; next} c>=2{print}' "$f"
}

# Highest severity across one or more EXPECTED review json files. FAIL-CLOSED:
# a missing/empty/unparseable/unrecognizable decision sidecar returns "blocker"
# (→ loopback, never a silent DONE). Echoes: blocker|major|minor|none.
sprint_review_max_severity() {
  local max=0 rank f
  for f in "$@"; do
    if [ ! -s "$f" ]; then echo blocker; return; fi
    if command -v jq >/dev/null 2>&1 && ! jq -e . "$f" >/dev/null 2>&1; then echo blocker; return; fi
    if   grep -Eq '"severity"[[:space:]]*:[[:space:]]*"blocker"' "$f"; then rank=3
    elif grep -Eq '"severity"[[:space:]]*:[[:space:]]*"major"'   "$f"; then rank=2
    elif grep -Eq '"severity"[[:space:]]*:[[:space:]]*"minor"'   "$f"; then rank=1
    elif grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"pass"'     "$f"; then rank=0
    else echo blocker; return; fi
    [ "$rank" -gt "$max" ] && max="$rank"
  done
  case "$max" in 3) echo blocker;; 2) echo major;; 1) echo minor;; *) echo none;; esac
}

# One-line human summary of a gate.json (failing check names).
sprint_gate_summary() {
  local f="$1"
  [ -s "$f" ] || { printf 'gate result unavailable'; return; }
  if command -v jq >/dev/null 2>&1 && jq -e . "$f" >/dev/null 2>&1; then
    jq -r '[.checks[]?|select(.status=="fail")|.name] | if length>0 then "failed: "+join(", ") else "all checks passed/skipped" end' "$f"
  else
    if grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"fail"' "$f"; then printf 'one or more checks failed (see gate.json)'; else printf 'all checks passed/skipped'; fi
  fi
}

# gate.json → ✅/❌/⚠️/skip markdown lines (for TODO.review.md). A check skipped
# because its TOOL IS MISSING is ⚠️ (visible degradation — install it or configure
# SPRINT_GATE_*); a check with no command configured stays a neutral note.
sprint_json_checks_to_md() {
  local f="$1"
  [ -s "$f" ] || { printf -- '- gate result unavailable\n'; return; }
  if command -v jq >/dev/null 2>&1 && jq -e . "$f" >/dev/null 2>&1; then
    jq -r '.checks[]?
      | if .status=="pass" then "✅ gate:\(.name)"
        elif .status=="fail" then "❌ gate:\(.name) — \(.summary // "fail")"
        elif ((.summary // "") | test("not on PATH")) then "⚠️ gate:\(.name) — \(.summary) (install it or set \(if .name=="fallow" then "SPRINT_FALLOW_CMD" else "SPRINT_GATE_\(.name|ascii_upcase)" end))"
        else "- gate:\(.name): skipped (\(.summary // "no command configured"))" end' "$f"
  elif grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"fail"' "$f"; then
    printf '❌ gate: one or more checks failed (see gate.json)\n'
  else
    printf '✅ gate: all checks passed/skipped\n'
  fi
}

# review-<name>.json → ✅/⚠️/❌ markdown lines. Missing/unparseable → ❌ (fail-closed).
sprint_json_findings_to_md() {
  local f="$1" agent
  agent="$(basename "$f" .json)"
  [ -s "$f" ] || { printf '❌ %s: report missing (treated as blocker)\n' "$agent"; return; }
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$f" >/dev/null 2>&1; then printf '❌ %s: unparseable report (treated as blocker)\n' "$agent"; return; fi
    jq -r --arg a "$agent" '(.agent // $a) as $n
      | if ((.findings|length)==0) and (.verdict=="pass") then "✅ \($n): ok"
        else (.findings[]? | (if (.severity=="blocker" or .severity=="major") then "❌ " elif .severity=="minor" then "⚠️ " else "⚠️ " end) + "\($n):\(.loc // "?") — \(.problem // "")") end' "$f"
  elif grep -Eq '"severity"[[:space:]]*:[[:space:]]*"(blocker|major)"' "$f"; then
    printf '❌ %s: blocker/major findings (see review json)\n' "$agent"
  elif grep -Eq '"severity"[[:space:]]*:[[:space:]]*"minor"' "$f"; then
    printf '⚠️ %s: minor findings\n' "$agent"
  elif grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"pass"' "$f"; then
    printf '✅ %s: ok\n' "$agent"
  else
    printf '❌ %s: no recognizable verdict (treated as blocker)\n' "$agent"
  fi
}

# Surface review results: traffic-light summary line, ❌-loopback pointer into
# TODO.md under "## 🔎 Review-Findings", AGENT_LOG entry, optional notification.
# Reads $ROOT/TODO.review.md; uses $SHA for labels. (Moved here from sprint-review.sh
# so the implement loop can reuse the exact same surface.)
sprint_surface_review() {
  local root="${ROOT:-$SPRINT_ROOT}" sha="${SHA:-}"
  local report="$root/TODO.review.md"
  [ -f "$report" ] || return 0
  local ok warn bad
  # Count only LINE-LEADING markers: findings are one-per-line by convention, while
  # free-text review prose may mention a marker mid-sentence ("no ❌ findings") —
  # which must NOT count as a finding (it caused false 🔎 pointers, whose AGENT_LOG
  # append then dirtied the tree and tripped the next apply-delivery overlap check).
  ok="$(grep -c -E '^[[:space:]]*✅' "$report" 2>/dev/null || true)";  ok="${ok:-0}"
  warn="$(grep -c -E '^[[:space:]]*⚠️' "$report" 2>/dev/null || true)"; warn="${warn:-0}"
  bad="$(grep -c -E '^[[:space:]]*❌' "$report" 2>/dev/null || true)";  bad="${bad:-0}"
  local line="Sprint review ${sha}: ✅ ${ok}  ⚠️ ${warn}  ❌ ${bad} — see TODO.review.md"
  echo "$line"

  if [ "$bad" -gt 0 ] 2>/dev/null; then
    local todo="$root/TODO.md"
    [ -f "$todo" ] || return 0
    awk 'BEGIN{s=0} /^## 🔎 Review-Findings/{s=1} s&&/^## /&&!/^## 🔎 Review-Findings/{s=0} !s{print}' "$todo" > "$todo.tmp" || cp "$todo" "$todo.tmp"
    {
      cat "$todo.tmp"
      printf '\n## 🔎 Review-Findings\n'
      printf -- '- ⚠️ %s — review of %s flagged %s ❌ finding(s). See TODO.review.md; resolve or re-file as a TODO.\n' \
        "$(date '+%Y-%m-%d %H:%M')" "$sha" "$bad"
    } > "$todo"
    rm -f "$todo.tmp"
    [ -f "$root/AGENT_LOG.md" ] && printf '\n## [%s] Sprint review %s — %s ❌, %s ⚠️ (see TODO.review.md)\n' \
      "$(date '+%Y-%m-%d %H:%M')" "$sha" "$bad" "$warn" >> "$root/AGENT_LOG.md"
  fi

  if [ "${SPRINT_NOTIFY:-0}" = "1" ]; then
    if command -v terminal-notifier >/dev/null 2>&1; then
      terminal-notifier -title "Sprint review ${sha}" -message "$line" 2>/dev/null || true
    elif command -v notify-send >/dev/null 2>&1; then
      notify-send "Sprint review ${sha}" "$line" 2>/dev/null || true
    fi
  fi
}

# Deliver CONVERGED impl-branch work into the user's working tree as STAGED,
# uncommitted changes (SPRINT_DELIVERY=apply): `git merge --squash` — IDE-native
# review, the USER makes the commit (never auto-committed; the no-auto-merge
# invariant holds). Applies ONLY when provably conflict-free:
#   1. the branch sits strictly on top of the current HEAD (it is created from HEAD
#      each run; HEAD moved during the run → fallback), and
#   2. none of the branch-changed paths overlap local uncommitted changes.
# Returns 0 = applied; 1 = fallback to branch mode, with the REASON on stdout (the
# caller surfaces it — degradation is visible, never silent). Shell-only → unit-testable.
sprint_apply_impl() {  # $1 = repo root, $2 = impl branch
  local root="$1" br="$2" base changed dirty overlap prestaged
  base="$(git -C "$root" merge-base HEAD "$br" 2>/dev/null || true)"
  if [ -z "$base" ] || [ "$base" != "$(git -C "$root" rev-parse HEAD)" ]; then
    printf 'HEAD moved during the run — result left on %s' "$br"; return 1
  fi
  changed="$(git -C "$root" diff --name-only "HEAD..$br" 2>/dev/null)"
  if [ -z "$changed" ]; then
    printf 'branch introduces no changes'; return 1
  fi
  # Paths from porcelain: strip the 2-char status + space; unquote is not needed for
  # the overlap test (both sides come from git and quote identically).
  dirty="$(git -C "$root" status --porcelain 2>/dev/null | cut -c4- | sed 's/.* -> //')"
  overlap="$(printf '%s\n' "$changed" | grep -Fx -f <(printf '%s\n' "$dirty") 2>/dev/null || true)"
  [ -z "$dirty" ] && overlap=""
  if [ -n "$overlap" ]; then
    printf 'local uncommitted changes overlap the result (%s) — left on %s' \
      "$(printf '%s' "$overlap" | tr '\n' ' ' | sed 's/ $//')" "$br"; return 1
  fi
  prestaged="$(git -C "$root" diff --cached --name-only 2>/dev/null)"
  if ! git -C "$root" merge --squash "$br" >/dev/null 2>&1; then
    # Emergency cleanup of a partial squash — but NEVER unstage the user's own
    # pre-existing staged work; only reset when the index was empty before.
    [ -z "$prestaged" ] && git -C "$root" reset --quiet 2>/dev/null
    printf 'git merge --squash failed unexpectedly — result left on %s' "$br"; return 1
  fi
  return 0
}

# Build TODO.review.md from the structured artifacts (gate + reviews), then hand off
# to sprint_surface_review for the ## 🔎 / AGENT_LOG / notify surface (verbatim).
sprint_findings_surface() {  # $1 = gate.json ; $2.. = review-*.json files
  local root="${ROOT:-$SPRINT_ROOT}" gate="$1" f fallow fb; shift
  fallow="$(dirname "$gate")/fallow.json"          # written by sprint-gate.sh when fallow ran
  fb="$(dirname "$gate")/model-fallbacks.log"      # written by sprint_model_fallback_note
  {
    printf '> Review of %s — %s\n\n' "${SHA:-autoplan/impl}" "$(date '+%Y-%m-%d %H:%M')"
    printf '### Gate\n'
    sprint_json_checks_to_md "$gate"
    if [ -s "$fallow" ]; then
      printf '\n### Fallow (static analysis)\n'
      sprint_fallow_to_md "$fallow"
    fi
    if [ -s "$fb" ]; then
      printf '\n### Model fallbacks (cross-vendor NOT active)\n'
      sprint_model_fallbacks_to_md "$fb"
    fi
    printf '\n### Reviews\n'
    for f in "$@"; do sprint_json_findings_to_md "$f"; done
    if [ -n "${SPRINT_DELIVERY_MD:-}" ]; then
      # Set by sprint-implement.sh when SPRINT_DELIVERY=apply: how the converged
      # work reached the user (staged into the working tree, or why it stayed on
      # the branch). Counts into the traffic-light summary.
      printf '\n### Delivery\n%s\n' "$SPRINT_DELIVERY_MD"
    fi
    printf '\n### Tooling\n'
    sprint_tooling_to_md "$root"
  } > "$root/TODO.review.md"
  sprint_surface_review
}
