---
name: update
description: Updates the vendored LHTask chain in bootstrapped repos from the plugin source. Refreshes scripts, subagents, MCP config, and git hooks. Use --all to update every registered repo. Leaves configuration and lifecycle files untouched.
argument-hint: "[--all]   (no arg = current repo; --all = every registered repo)"
---

You are updating the **vendored** LHTask chain in already-bootstrapped repos from the
freshly-installed plugin templates. The plugin ships the canonical `agents/` + `.mcp.json`
(those auto-update with the plugin); this command refreshes the **vendored copies** that the
headless git-hook path depends on, plus the stage scripts and hooks.

**Only refresh logic. Never touch the user's config or content:** leave `lhtask.conf`,
`TODO.md`, `DONE.md`, `AGENT_LOG.md`, `AGENTS.md`, `CLAUDE.md` and `.gitignore` alone.

## 0. Locate templates + the target repo(s)
Templates come from the plugin **as installed** — never from a development checkout:
```bash
TPL="${CLAUDE_PLUGIN_ROOT:-}/templates"
# Fallback when CLAUDE_PLUGIN_ROOT is unset (e.g. skill executed manually): resolve the
# INSTALLED plugin from the marketplace cache — most recently installed version wins.
[ -d "$TPL" ] || TPL="$(ls -dt "$HOME"/.claude/plugins/cache/*/lhtask/*/templates 2>/dev/null | head -1)"
[ -d "${TPL:-}" ] || { echo "lhtask is not installed. Run:
  claude plugin marketplace add leonhoffmann86/lhtask-plugin
  claude plugin install lhtask@lhtask-marketplace"; }
REG="${XDG_CONFIG_HOME:-$HOME/.config}/lhtask/registry"   # one repo path per line
```
If neither resolves, **stop** with that install instruction. Do NOT search the filesystem
for a plugin source tree and do NOT accept a git checkout of the plugin repo as `$TPL` —
only the installed (versioned) copy is a valid template source (see `docs/DISTRIBUTION.md`).
- No argument → operate on the current repo only: `ROOT="$(git rev-parse --show-toplevel)"`.
- `--all` → read `$REG` (if present) and operate on each listed path that is still a git repo
  with a `scripts/lhtask-lib.sh` (i.e. actually bootstrapped). Report missing/!bootstrapped
  entries and skip them. If `$REG` is absent, tell the user no repos are registered and that
  `/lhtask:bootstrap` records repos there (see step 4).

## 1. Refresh the logic files (overwrite — these are NOT user-owned)
For each target `ROOT`, copy over (overwrite) ONLY:
```bash
cp "$TPL/scripts/lhtask-lib.sh"       "$ROOT/scripts/lhtask-lib.sh"
cp "$TPL/scripts/lhtask-plan.sh"      "$ROOT/scripts/lhtask-plan.sh"
cp "$TPL/scripts/lhtask-implement.sh" "$ROOT/scripts/lhtask-implement.sh"
cp "$TPL/scripts/lhtask-review.sh"    "$ROOT/scripts/lhtask-review.sh"
cp "$TPL/scripts/lhtask-gate.sh"      "$ROOT/scripts/lhtask-gate.sh"
cp "$TPL/githooks/post-commit"        "$ROOT/.githooks/post-commit"
cp "$TPL/githooks/README.md"          "$ROOT/.githooks/README.md"
mkdir -p "$ROOT/.claude/agents"
cp "$TPL"/.claude/agents/*.md         "$ROOT/.claude/agents/"
chmod +x "$ROOT/.githooks/post-commit" "$ROOT"/scripts/lhtask-*.sh
```
For `.mcp.json`: if the repo's file is identical to a prior template version, overwrite it; if the
user has customized it (extra servers), **merge** the `codegraph` server in rather than clobbering —
show the diff and confirm. Before overwriting any file that the user may have hand-edited, show a
diff and ask.

## 2. Surface config drift (don't auto-edit `lhtask.conf`)
Compare the keys defined in `$TPL/lhtask.conf` against the repo's `lhtask.conf`. For any key present
in the template but **missing** in the repo (e.g. a newly added `LHTASK_*`), print it with its
default and a one-line description, and tell the user to add it if they want the new behavior.
Never rewrite their `lhtask.conf` automatically.

## 3. Sanity-check
Run `bash -n` on each refreshed script; report any failure. Remind the user that the chain still
no-ops gracefully without `claude`/`codegraph`.

## 4. Registry (for `--all`)
Maintain a newline-delimited registry at `$REG`. When `/lhtask:bootstrap` runs it should append the
repo's absolute path (deduped); this command consumes it for `--all`. If a registry entry no longer
exists or isn't bootstrapped, drop it and note the cleanup. Keep it a plain path list — no other
state.

## 5. Summarize
Print, per repo: which files were refreshed/skipped, any `.mcp.json` merge, the config-drift keys to
consider, and the reminder that `lhtask.conf` + lifecycle files were intentionally left untouched.
