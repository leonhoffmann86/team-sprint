#!/usr/bin/env bash
#
# sprint-standup.sh — live terminal view of the chain: current phase, lock state,
# then the streaming tool-call trace. The Cursor-style "what is the agent doing
# right now" answer, without hunting for a log file.
#
# Usage: scripts/sprint-standup.sh          (from anywhere inside the repo)
#        scripts/sprint-standup.sh -n 40    (more backlog lines)
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
LOG="$ROOT/TODO.run.log"
LINES=20
[ "${1:-}" = "-n" ] && LINES="${2:-20}"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'

running=""
for l in sprint-plan sprint-implement sprint-review sprint-scan; do
  [ -d "$ROOT/.git/$l.lock" ] && running="$running ${l#sprint-}"
done

echo "${bold}── Sprint standup ─ $(basename "$ROOT")${reset}"
if [ -n "$running" ]; then
  echo "${green}● running:${running}${reset}"
else
  echo "${dim}○ idle — no stage holds a lock${reset}"
fi
REVIEW="$ROOT/TODO.review.md"
if [ -z "$running" ] && [ -f "$REVIEW" ] && grep -q '^## 🤝 NEEDS_HUMAN' "$REVIEW"; then
  echo "${bold}${yellow}🤝 NEEDS_HUMAN — a converged result is waiting for you:${reset}"
  awk '/^## 🤝 NEEDS_HUMAN/{f=1} f&&/^### Tooling/{exit} f{print}' "$REVIEW" | sed 's/^/   /'
  echo ""
fi

if [ -f "$LOG" ]; then
  banner="$(grep -E '^=====' "$LOG" | tail -1 || true)"
  [ -n "$banner" ] && echo "${yellow}${banner}${reset}"
  echo "${dim}(live trace — Ctrl-C to leave; run state is untouched)${reset}"
  exec tail -n "$LINES" -f "$LOG"
else
  echo "${dim}no run yet — TODO.run.log appears on the first trigger${reset}"
fi
