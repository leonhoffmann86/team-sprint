#!/usr/bin/env bash
#
# docs-refresh.sh — regenerate this repo's source-of-truth docs from the current code.
# Updates CLAUDE.md, ARCHITECTURE.md (Mermaid) and README.md (kept extremely short) so they
# never drift from skills/ and templates/. Run manually any time, or let .githooks/pre-push
# call it when a push changes the doc sources.
#
# Graceful no-op if the `claude` CLI is absent. Reads/writes only the three docs; never commits.
#
set -euo pipefail

# If invoked from inside a git hook, git may have injected these — clear them so our git
# calls resolve against the working dir, not the hook's quarantined index.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_QUARANTINE_PATH 2>/dev/null || true

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
LOG="$ROOT/.git/docs-refresh.log"

command -v claude >/dev/null 2>&1 || { echo "docs-refresh: claude CLI not found, skipping." >&2; exit 0; }

read -r -d '' PROMPT <<'EOF' || true
You are refreshing this repository's documentation so it matches the current code. This repo is
the SOURCE of the `sprint` Claude Code plugin (two skills + bash templates that the bootstrap
skill copies into target repos, where they run as a git post-commit chain).

FIRST, survey ALL source files so nothing is missed — do not rely on a fixed list. Run
`git ls-files` and read every tracked file that is NOT a generated doc and NOT noise, i.e.
EXCLUDE only: CLAUDE.md, ARCHITECTURE.md, README.md, .gitignore, .vscode/*, .claude/*, *.DS_Store.
Everything else is a source you must account for — today that includes (but is not limited to):
- skills/ticket/SKILL.md, skills/bootstrap/SKILL.md
- templates/githooks/post-commit, templates/githooks/README.md, templates/scripts/sprint-*.sh,
  templates/sprint.conf, templates/AGENTS.md, templates/{TODO,DONE,AGENT_LOG}.md
- .claude-plugin/plugin.json, .claude-plugin/marketplace.json
- the doc-automation itself: .githooks/pre-push, scripts/docs-refresh.sh, Makefile
If a source file exists that the docs don't yet mention, that is exactly the kind of gap to fix.

Then update EXACTLY these three files to reflect the current state. Change nothing else. Commit nothing.

1) CLAUDE.md — guidance for future Claude Code instances (the /init style). This is the agent-native
   source of truth. Keep: the plugin-repo-vs-target-repo mental model; the plan -> implement -> review
   chain; and the load-bearing invariants — AUTOPLAN_AGENT=1 loop guard, the GIT_DIR/GIT_WORK_TREE/...
   unset at the top of every stage, the skip convention (HTML comments, "## 🚧" Deferred, "## 🔎"
   Review-Findings), mkdir-based locking with stale-lock reaping, detached-by-default execution with
   SPRINT_FOREGROUND=1 as the sync lever, graceful no-op when claude/codegraph is missing, and the
   config defaults duplicated across sprint.conf + sprint_load_config + the inline defaults in
   post-commit (must stay in sync). Concise and high-signal; no generic filler.

2) ARCHITECTURE.md — the visual deep-dive in Mermaid (renders on GitHub). Keep the existing section
   structure and language; update every diagram and note so it matches the current scripts and config.
   If any stage, file name, env var, default, or config key changed, fix it in every diagram.

3) README.md — keep it EXTREMELY SHORT. Only: a 1–2 sentence description of what the plugin does, the
   install/usage snippet, a "Mehr" links section pointing to ARCHITECTURE.md, CLAUDE.md and the key
   files (the two skills, templates/sprint.conf, templates/AGENTS.md, templates/githooks/README.md) each
   with a one-line description, and the short "Doc automation" section. Do NOT expand it into a full
   manual — the depth lives in ARCHITECTURE.md and CLAUDE.md.

Make the smallest edits that bring each doc back in sync with the code. Preserve each file's existing
voice and language. Do not commit, do not push, do not touch any other file.
EOF

echo "docs-refresh: regenerating CLAUDE.md / ARCHITECTURE.md / README.md (headless claude) …"
{ claude -p "$PROMPT" \
    --permission-mode acceptEdits \
    --allowed-tools Read Write Edit Glob Grep 2>&1 || true; } | tee "$LOG"

exit 0
