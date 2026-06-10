#!/usr/bin/env bash
set -euo pipefail

# Smoke test: bootstrap LHTask into a throwaway repo and run one cycle.
# Run with: bash tests/smoke-test.sh
# Prerequisites: claude CLI on PATH, LHTask plugin accessible.

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== LHTask Smoke Test ==="
echo "Plugin dir: $PLUGIN_DIR"
echo "Working in:  $TMPDIR"

cd "$TMPDIR"

# --- Setup: create a throwaway git repo ---
git init
git config user.email "test@lhtask.local"
git config user.name "LHTask Test"

cp "$PLUGIN_DIR/templates/AGENTS.md" .

cat > TODO.md <<'EOF'
## Backlog
- [ ] test: add a simple hello-world script
EOF
git add -A && git commit -m "init"

# --- Bootstrap the chain ---
echo ""
echo "--- Bootstrapping LHTask into throwaway repo ---"
claude -p --plugin-dir "$PLUGIN_DIR" "/lhtask:bootstrap" || {
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
LHTASK_FOREGROUND=1 .githooks/post-commit

# --- Verify ---
echo ""
if [ -f TODO.run.log ]; then
  echo "SMOKE PASS: TODO.run.log created"
else
  echo "SMOKE FAIL: No TODO.run.log"
  exit 1
fi

echo "All smoke tests passed."
