#!/usr/bin/env bash
#
# sprint-scan.sh — poll trigger (SPRINT_TRIGGER=scan) for repos whose TODO.md is
# deliberately untracked: the commit trigger can never fire there, so a launchd/
# systemd timer runs this scan every ~30s instead.
#
# Scan-reconcile pickup (trigger and pickup are separated on purpose — the timer
# is just an unreliable doorbell; correctness lives here):
#   1. read the ACTIVE unchecked items from TODO.md (skip convention honoured)
#   2. hash them; compare against the last-started state (.git/sprint-scan.hash)
#   3. changed → atomic mkdir claim → chain sprint-plan.sh with the diff-guard off
# Editing an item's text changes the hash → it counts as a new task (deliberate).
# The hash is written BEFORE the run: a failed run is surfaced by the chain's own
# review/log machinery, not by blind re-triggering every 30s.
#
# Install (macOS):  see templates/trigger/README.md (launchd StartInterval=30)
# Kill switch: touch .git/autoplan.disabled   (same as the commit trigger)
set -euo pipefail

# --seed: record the current active-item hash WITHOUT running the chain (used by
# bootstrap before activating the poll, so pre-existing open items don't fire).
# Keeping seed and compare in ONE implementation avoids newline-mismatch footguns.
SEED_ONLY=0
ARGS=()
for a in "$@"; do
  [ "$a" = "--seed" ] && SEED_ONLY=1 || ARGS+=("$a")
done
ROOT="${ARGS[0]:-$(git rev-parse --show-toplevel)}"
cd "$ROOT"
# shellcheck source=/dev/null
. "$ROOT/scripts/sprint-lib.sh"
sprint_load_config

[ -f "$ROOT/.git/autoplan.disabled" ] && exit 0
command -v claude >/dev/null 2>&1 || exit 0
[ -f "$ROOT/TODO.md" ] || exit 0

OPEN="$(sprint_strip_skipped "$ROOT/TODO.md" | grep -E '^[[:space:]]*-[[:space:]]*\[ \]' || true)"
[ -n "$OPEN" ] || exit 0
HASH="$(printf '%s' "$OPEN" | shasum -a 256 | cut -c1-16)"
SEEN="$ROOT/.git/sprint-scan.hash"
if [ "$SEED_ONLY" = 1 ]; then printf '%s' "$HASH" > "$SEEN"; echo "sprint-scan: seeded $HASH"; exit 0; fi
[ -f "$SEEN" ] && [ "$(cat "$SEEN")" = "$HASH" ] && exit 0

# Atomic claim (mkdir is POSIX-atomic): overlapping scans can't double-fire.
# A running plan/implement stage holds its own lock downstream as second guard.
mkdir "$ROOT/.git/sprint-scan.lock" 2>/dev/null || exit 0
trap 'rmdir "$ROOT/.git/sprint-scan.lock" 2>/dev/null || true' EXIT

printf '%s' "$HASH" > "$SEEN"
SPRINT_TRIGGER=scan "$ROOT/scripts/sprint-plan.sh"
