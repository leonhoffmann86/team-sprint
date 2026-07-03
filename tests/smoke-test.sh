#!/usr/bin/env bash
set -euo pipefail

# Smoke test: bootstrap Sprint into a throwaway repo and run one cycle.
# Run with: bash tests/smoke-test.sh
# Prerequisites: claude CLI on PATH, Sprint plugin accessible.

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== Sprint Smoke Test ==="
echo "Plugin dir: $PLUGIN_DIR"
echo "Working in:  $TMPDIR"

# --- Unit: per-role model resolution (pure shell, no claude needed) ---
echo ""
echo "--- Unit: sprint_model_flags resolution ---"
(
  cd "$TMPDIR"
  git init -q model-unit && cd model-unit   # lib needs a git toplevel
  export XDG_CONFIG_HOME="$PWD/.xdg"        # isolate from the user's real ~/.config/sprint/env
  # shellcheck source=/dev/null
  . "$PLUGIN_DIR/templates/scripts/sprint-lib.sh"
  sprint_load_config

  assert_flags() {  # $1 = label, $2 = expected ("--model X" or empty)
    local got="${SPRINT_MODEL_FLAGS[*]:-}"
    if [ "$got" = "$2" ]; then echo "  ok:  $1"
    else echo "  UNIT FAIL: $1 — expected '$2', got '$got'"; exit 1; fi
  }

  # 1) no config at all → empty (CLI default)
  sprint_model_flags implementer
  assert_flags "no override → empty" ""
  # 2) global only → global wins for any role and for no-role calls
  SPRINT_MODEL="opus"
  sprint_model_flags implementer
  assert_flags "global fallback (role)" "--model opus"
  sprint_model_flags
  assert_flags "global fallback (no role, legacy)" "--model opus"
  # 3) role-specific beats global; dash→underscore mapping
  SPRINT_MODEL_REVIEWER_CORRECTNESS="sonnet"
  sprint_model_flags reviewer-correctness
  assert_flags "role-specific beats global (+ - → _ mapping)" "--model sonnet"
  # 4) other roles keep falling back to global
  sprint_model_flags reviewer-conventions
  assert_flags "unset role falls back to global" "--model opus"
  # 5) stage names map too
  SPRINT_MODEL_REVIEW="haiku"
  sprint_model_flags review
  assert_flags "stage name (review)" "--model haiku"
  SPRINT_MODEL_PLAN="haiku"
  sprint_model_flags plan
  assert_flags "stage name (plan)" "--model haiku"

  # --- cross-vendor (openrouter: prefix) ---
  SPRINT_MODEL_FALLBACK_LOG="$PWD/fallbacks.log"
  SPRINT_MODEL_REVIEWER_CORRECTNESS="openrouter:openai/gpt-5"
  # 6) prefix without proxy → graceful Claude fallback + RECORDED degradation
  SPRINT_PROXY_URL=""
  sprint_model_flags reviewer-correctness 2>/dev/null
  assert_flags "xvendor w/o proxy → Claude fallback" "--model opus"
  grep -q "SPRINT_PROXY_URL is empty" fallbacks.log \
    || { echo "  UNIT FAIL: fallback not recorded"; exit 1; }
  echo "  ok:  fallback recorded (no proxy)"
  # 7) reachable proxy (file:// satisfies the curl reachability probe) → env + model
  SPRINT_PROXY_URL="file://$PWD/fallbacks.log"
  SPRINT_PROXY_TOKEN="sk-test"
  sprint_model_flags reviewer-correctness
  assert_flags "xvendor active → vendor model" "--model openai/gpt-5"
  [ "${SPRINT_MODEL_XVENDOR}" = "1" ] || { echo "  UNIT FAIL: XVENDOR flag"; exit 1; }
  [ "${SPRINT_MODEL_ENV[0]}" = "ANTHROPIC_BASE_URL=$SPRINT_PROXY_URL" ] \
    && [ "${SPRINT_MODEL_ENV[1]}" = "ANTHROPIC_AUTH_TOKEN=sk-test" ] \
    || { echo "  UNIT FAIL: env injection"; exit 1; }
  echo "  ok:  env injection (base url + token)"
  # 8) unreachable proxy → graceful fallback + recorded
  SPRINT_PROXY_URL="http://127.0.0.1:1"
  sprint_model_flags reviewer-correctness 2>/dev/null
  assert_flags "xvendor proxy unreachable → Claude fallback" "--model opus"
  grep -q "unreachable" fallbacks.log \
    || { echo "  UNIT FAIL: unreachable fallback not recorded"; exit 1; }
  echo "  ok:  fallback recorded (unreachable proxy)"
  # 9) forced Claude retry path ignores the prefix (and stays quiet)
  SPRINT_PROXY_URL="file://$PWD/fallbacks.log"
  SPRINT_FORCE_CLAUDE=1 sprint_model_flags reviewer-correctness
  assert_flags "FORCE_CLAUDE ignores prefix" "--model opus"
  [ "${SPRINT_MODEL_XVENDOR}" = "0" ] || { echo "  UNIT FAIL: forced run must not be xvendor"; exit 1; }
  echo "  ok:  forced Claude retry"
  # 10) raw-config detector for the safety net
  sprint_model_is_xvendor reviewer-correctness || { echo "  UNIT FAIL: is_xvendor positive"; exit 1; }
  ! sprint_model_is_xvendor reviewer-conventions || { echo "  UNIT FAIL: is_xvendor negative"; exit 1; }
  echo "  ok:  is_xvendor raw detection"

  # --- tooling surface: every supporting tool is reported, never silent ---
  TOOLING="$(sprint_tooling_to_md "$PWD")"
  for tool in codegraph fallow jq timeout; do
    printf '%s\n' "$TOOLING" | grep -q "$tool" \
      || { echo "  UNIT FAIL: tooling report misses '$tool'"; exit 1; }
  done
  printf '%s\n' "$TOOLING" | grep -Eq '^(✅|⚠️|-) codegraph' \
    || { echo "  UNIT FAIL: codegraph line has no status marker"; exit 1; }
  SPRINT_CODEGRAPH="off"
  sprint_tooling_to_md "$PWD" | grep -q -- '- codegraph: disabled' \
    || { echo "  UNIT FAIL: codegraph off not neutral"; exit 1; }
  SPRINT_CODEGRAPH="auto"
  echo "  ok:  tooling surface reports all tools"

  # conditional tooling lines: curl only with cross-vendor config, notifier only with NOTIFY=1
  sprint_tooling_to_md "$PWD" | grep -q "curl" \
    || { echo "  UNIT FAIL: curl line missing despite cross-vendor config"; exit 1; }
  SPRINT_MODEL_REVIEWER_CORRECTNESS=""
  ! sprint_tooling_to_md "$PWD" | grep -q "curl" \
    || { echo "  UNIT FAIL: curl line shown without cross-vendor config"; exit 1; }
  SPRINT_NOTIFY="1"
  sprint_tooling_to_md "$PWD" | grep -q "notifier" \
    || { echo "  UNIT FAIL: notifier line missing with SPRINT_NOTIFY=1"; exit 1; }
  SPRINT_NOTIFY="0"
  ! sprint_tooling_to_md "$PWD" | grep -q "notifier" \
    || { echo "  UNIT FAIL: notifier line shown with SPRINT_NOTIFY=0"; exit 1; }
  echo "  ok:  conditional tooling lines (curl / notifier)"

  # gate skip rendering: missing TOOL is ⚠️ with config hint; unconfigured stays neutral
  cat > gate-fixture.json <<'EOF'
{"iteration":1,"stack":"node","verdict":"pass","checks":[
 {"name":"lint","cmd":"eslint .","status":"skip","exit":null,"summary":"tool 'eslint' not on PATH","detail":""},
 {"name":"build","cmd":"","status":"skip","exit":null,"summary":"no command configured","detail":""},
 {"name":"fallow","cmd":"fallow audit","status":"skip","exit":null,"summary":"tool 'fallow' not on PATH","detail":""}]}
EOF
  GATE_MD="$(sprint_json_checks_to_md gate-fixture.json)"
  printf '%s\n' "$GATE_MD" | grep -q "⚠️ gate:lint — tool 'eslint' not on PATH (install it or set SPRINT_GATE_LINT)" \
    || { echo "  UNIT FAIL: missing-tool skip not rendered as ⚠️"; printf '%s\n' "$GATE_MD"; exit 1; }
  printf '%s\n' "$GATE_MD" | grep -q -- "- gate:build: skipped (no command configured)" \
    || { echo "  UNIT FAIL: unconfigured skip not neutral"; printf '%s\n' "$GATE_MD"; exit 1; }
  printf '%s\n' "$GATE_MD" | grep -q "SPRINT_FALLOW_CMD" \
    || { echo "  UNIT FAIL: fallow skip hint wrong"; printf '%s\n' "$GATE_MD"; exit 1; }
  echo "  ok:  gate missing-tool skips rendered as ⚠️ with config hint"

  # --- SPRINT_DELIVERY=apply: sprint_apply_impl (squash-stage into the working tree) ---
  APPLY_REPO="$TMPDIR/apply-unit"
  git init -q "$APPLY_REPO" && (
    cd "$APPLY_REPO"
    git config user.email t@t && git config user.name t
    echo base > file.txt && echo keep > other.txt
    git add -A && git commit -qm base
    # impl branch strictly on top of HEAD, one change
    git branch impl && git checkout -q impl && echo changed > file.txt && git commit -aqm impl && git checkout -q -
    # 1) happy path: clean tree → applied (staged, no commit, branch kept)
    sprint_apply_impl "$PWD" impl || { echo "  UNIT FAIL: apply happy path returned fallback"; exit 1; }
    git diff --cached --name-only | grep -qx "file.txt" || { echo "  UNIT FAIL: change not staged"; exit 1; }
    [ "$(git rev-parse HEAD)" = "$(git rev-parse main 2>/dev/null || git rev-parse master)" ] || true
    [ "$(git log --oneline | wc -l | tr -d ' ')" = "1" ] || { echo "  UNIT FAIL: apply must not commit"; exit 1; }
    git show-ref --verify --quiet refs/heads/impl || { echo "  UNIT FAIL: branch must be kept"; exit 1; }
    echo "  ok:  apply happy path → staged, no commit, branch kept"
    git reset -q && git checkout -q -- file.txt
    # 2) dirty overlap → fallback naming the file, nothing staged
    echo local-edit >> file.txt
    if OUT="$(sprint_apply_impl "$PWD" impl)"; then echo "  UNIT FAIL: overlap must fall back"; exit 1; fi
    printf '%s' "$OUT" | grep -q "file.txt" || { echo "  UNIT FAIL: overlap reason misses file"; exit 1; }
    [ -z "$(git diff --cached --name-only)" ] || { echo "  UNIT FAIL: overlap fallback staged something"; exit 1; }
    git checkout -q -- file.txt
    echo "  ok:  dirty overlap → fallback with reason, nothing staged"
    # 3) non-overlapping dirty file → still applies
    echo local >> other_untouched.txt
    sprint_apply_impl "$PWD" impl || { echo "  UNIT FAIL: non-overlap dirty must still apply"; exit 1; }
    git diff --cached --name-only | grep -qx "file.txt" || { echo "  UNIT FAIL: non-overlap apply not staged"; exit 1; }
    git reset -q && git checkout -q -- file.txt && rm -f other_untouched.txt
    echo "  ok:  unrelated dirty file does not block apply"
    # 4) HEAD moved during the run → fallback
    echo more > extra.txt && git add extra.txt && git commit -qm "user commit"
    if OUT="$(sprint_apply_impl "$PWD" impl)"; then echo "  UNIT FAIL: HEAD-moved must fall back"; exit 1; fi
    printf '%s' "$OUT" | grep -qi "HEAD moved" || { echo "  UNIT FAIL: HEAD-moved reason wrong: $OUT"; exit 1; }
    echo "  ok:  HEAD moved → fallback"
  ) || exit 1

  # --- plan-stage idle guard: no active checkbox item → grep gate fails ---
  IDLE_RE='^[[:space:]]*([-*][[:space:]]+)?\[ \]'
  NOACT="$(printf '# TODO\n\n## Backlog\n(alles erledigt)\n- plain bullet without checkbox\n')"
  if printf '%s\n' "$NOACT" | grep -qE "$IDLE_RE"; then
    echo "  UNIT FAIL: idle guard matched without active items"; exit 1
  fi
  printf -- '- [ ] do something\n' | grep -qE "$IDLE_RE" \
    || { echo "  UNIT FAIL: idle guard misses a dashed item"; exit 1; }
  printf -- '[ ] bare checkbox item\n' | grep -qE "$IDLE_RE" \
    || { echo "  UNIT FAIL: idle guard misses a bare-checkbox item"; exit 1; }
  echo "  ok:  plan idle-guard pattern (dashed + bare checkbox)"

  # --- traffic-light counting: only LINE-LEADING markers are findings ---
  SURF_REPO="$TMPDIR/surface-unit"
  git init -q "$SURF_REPO" && (
    cd "$SURF_REPO"
    git config user.email t@t && git config user.name t
    printf '# TODO\n\n- [ ] item\n' > TODO.md
    # Prose mention of ❌ ("no ❌ findings") must NOT raise the 🔎 pointer …
    printf '> Review of x\n✅ aspect ok\nVerdict: no ❌ findings, one cosmetic note.\n' > TODO.review.md
    ROOT="$PWD" SHA=test sprint_surface_review >/dev/null
    grep -q '🔎 Review-Findings' TODO.md \
      && { echo "  UNIT FAIL: prose ❌ raised a false 🔎 pointer"; exit 1; }
    # … while a line-leading ❌ MUST raise it.
    printf '> Review of x\n❌ broken: real finding\n' > TODO.review.md
    ROOT="$PWD" SHA=test sprint_surface_review >/dev/null
    grep -q '🔎 Review-Findings' TODO.md \
      || { echo "  UNIT FAIL: line-leading ❌ did not raise the 🔎 pointer"; exit 1; }
    echo "  ok:  traffic light counts line-leading markers only"
  ) || exit 1

  # --- live stream trace: NDJSON → terse activity lines; off/no-jq → passthrough ---
  SPRINT_STREAM="auto"; sprint_stream_setup
  [ -n "$SPRINT_STREAM_ACTIVE" ] && [ "${SPRINT_STREAM_FLAGS[0]:-}" = "--output-format" ] \
    || { echo "  UNIT FAIL: stream setup (auto + jq) inactive"; exit 1; }
  TRACE_OUT="$(printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"app/x.py"}}]}}' \
    'plain stderr noise' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"thinking aloud"}]}}' \
    '{"type":"result","num_turns":7,"result":"done all"}' \
    | SPRINT_TRACE_ROLE=implementer sprint_stream_trace)"
  printf '%s\n' "$TRACE_OUT" | grep -q "⚙ implementer → Edit: app/x.py" \
    || { echo "  UNIT FAIL: tool_use not traced"; exit 1; }
  printf '%s\n' "$TRACE_OUT" | grep -q "plain stderr noise" \
    || { echo "  UNIT FAIL: non-JSON stderr line lost"; exit 1; }
  printf '%s\n' "$TRACE_OUT" | grep -q "✔ implementer done — 7 turns" \
    || { echo "  UNIT FAIL: result line missing"; exit 1; }
  ! printf '%s\n' "$TRACE_OUT" | grep -q "thinking aloud" \
    || { echo "  UNIT FAIL: text event must be dropped"; exit 1; }
  SPRINT_STREAM="off"; sprint_stream_setup
  [ -z "$SPRINT_STREAM_ACTIVE" ] && [ "${#SPRINT_STREAM_FLAGS[@]}" -eq 0 ] \
    || { echo "  UNIT FAIL: stream setup off still active"; exit 1; }
  [ "$(printf 'raw passthrough\n' | sprint_stream_trace)" = "raw passthrough" ] \
    || { echo "  UNIT FAIL: inactive trace must pass through"; exit 1; }
  SPRINT_STREAM="auto"
  echo "  ok:  live stream trace (events rendered, noise kept, off=passthrough)"
  echo "  model-resolution unit tests passed"
) || { echo "SMOKE FAIL: model resolution unit tests"; exit 1; }

cd "$TMPDIR"

# --- Setup: create a throwaway git repo ---
git init
git config user.email "test@sprint.local"
git config user.name "Sprint Test"

cp "$PLUGIN_DIR/templates/AGENTS.md" .

cat > TODO.md <<'EOF'
## Backlog
- [ ] test: add a simple hello-world script
EOF
git add -A && git commit -m "init"

# --- Bootstrap the chain ---
echo ""
echo "--- Bootstrapping Sprint into throwaway repo ---"
claude -p --plugin-dir "$PLUGIN_DIR" "/sprint:bootstrap" || {
  echo "SMOKE FAIL: bootstrap did not complete"
  exit 1
}

# --- Add a task and commit to trigger the chain ---
cat > TODO.md <<'EOF'
## Backlog
- [ ] feat: create hello.sh that prints "hello world"
EOF
git add TODO.md && git commit -m "task: add hello script"

# --- Run the chain in foreground ---
echo ""
echo "--- Running implement chain (foreground) ---"
SPRINT_FOREGROUND=1 .githooks/post-commit

# --- Verify ---
echo ""
if [ -f TODO.run.log ]; then
  echo "SMOKE PASS: TODO.run.log created"
else
  echo "SMOKE FAIL: No TODO.run.log"
  exit 1
fi

echo "All smoke tests passed."
