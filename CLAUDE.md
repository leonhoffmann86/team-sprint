# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the **source of the `lhtask` Claude Code plugin** — not an application. There is no
build, lint, or test toolchain. The "code" is:

- three **skills** (`skills/lh-task`, `skills/bootstrap`, `skills/update`) — markdown prompt files
  with frontmatter; the skills register the namespaced `/lhtask:*` slash commands themselves —
  there is deliberately **no `commands/` directory** (wrappers there registered the same names and
  *shadowed* the skills; removed in v0.3.3 — `skills/` is canonical, don't add wrappers back),
- a set of **bash templates** (`templates/`) that `bootstrap` copies into a *target* repo,
- the **subagent team** (`agents/*.md`) — six role definitions (planner, navigator, implementer,
  reviewer-correctness, reviewer-conventions, reviewer-visual) used by the implement loop,
- plugin metadata (`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` — the CLI
  resolves exactly that marketplace path, keep it there — plus `CHANGELOG.md`; keep the version
  in sync across all three when releasing),
- `docs/DISTRIBUTION.md` — the **binding distribution & separation model**: GitHub is the only
  install channel, also for maintainers (`--plugin-dir` is test-only, e.g. the smoke test); data
  flows one-way plugin → consumer; updates are pull-based (`/lhtask:update` run *inside* the
  consumer repo); the registry (`~/.config/lhtask/registry`) is opt-in — `bootstrap` asks before
  registering, `update` is consume-only and never self-registers; never reach into
  consumer repos from plugin-dev sessions, and the reverse holds too: sessions running in a
  consumer repo never write into this plugin repo — fix the vendored copy locally and *report*
  the finding for a reviewed plugin-side release,
- `docs/CROSS-VENDOR.md` — setup guide for running individual roles on **non-Claude models**
  (the `openrouter:` prefix + translating proxy, see the configuration section below).

Critical mental model: the scripts in `templates/scripts/` and `templates/githooks/` **do not run
here**. They are parameterized files that get copied (`cp -n`) into another repo by the `bootstrap`
skill, where they execute as a git `post-commit` chain. So editing a script here changes what every
future bootstrapped repo gets; it has no effect on this repo's own git activity.

**Agents are duplicated on purpose:** `agents/` is the plugin-canonical copy (auto-updates with the
plugin, used by interactive sessions); `templates/.claude/agents/` is the vendored copy that
`bootstrap` installs into the target repo, because the headless hook chain reads the role bodies via
`--append-system-prompt` from `$ROOT/.claude/agents/`. **Keep the two directories identical** —
edit `agents/` and run `make sync-agents` to copy them over, then `/lhtask:update` in target repos.
The same applies to `.mcp.json` (codegraph MCP server config) and `templates/.mcp.json`.

## The plan → implement → review chain (the heart of the plugin)

When bootstrapped into a repo, `templates/githooks/post-commit` routes each commit:

- commit changed `TODO.md` → **`lhtask-plan.sh`** (writes `TODO.autoplan.md`) → chains
  **`lhtask-implement.sh`** in the same detached run. The plan stage exits 0 *without* a claude
  run when no active checkbox item remains after `lhtask_strip_skipped` — the guard is
  deliberately tolerant (`- [ ]`, `* [ ]` and bare `[ ]` all count; a false "nothing to do"
  silently blocks real work, which is worse than one idle run) — e.g. the commit of an
  applied/merged chain result that only removed items.
- commit changed any `LHTASK_REVIEW_DIRS/` → **`lhtask-review.sh`** (writes `TODO.review.md`,
  report-only; for single-commit targets it also runs fallow and appends a `### Fallow` section,
  report at `.git/lhtask-fallow.json`; every report ends with a `### Tooling` section).

`lhtask-implement.sh` is a **shell-driven subagent-team orchestrator** in an **isolated
`git worktree`** on `LHTASK_IMPL_BRANCH` (default `autoplan/impl`). The worktree is a sibling
directory *outside* the repo (`../.lhtask-worktree-<repo>`) — never under `.git/`, because the
agent permission layer auto-denies every write under a `.git/` path (this silently broke
implementer runs). It runs **planner → navigator**
once, then a bounded loop (up to `LHTASK_MAX_ITER`, default 3):

1. **implementer** — smallest change, **one commit per item** (code + `TODO.md`→`DONE.md` +
   `AGENT_LOG.md`),
2. **deterministic gate** (`lhtask-gate.sh`, pure shell, no LLM) — lint/typecheck/test/build per
   `LHTASK_GATE_*`/`LHTASK_STACK` (stack auto-detected from marker files), plus a fifth **fallow**
   check (`fallow audit`: dead code/duplication/complexity, scoped to the item commit's changeset,
   gated "new-only" — only findings the change *introduces* fail; raw report saved as
   `.lhtask-state/fallow.json` for the loopback prompt and the reviewers); red → loop back with the
   failures as the fix list,
3. **reviewers** (correctness + conventions, read-only) — `blocker`/`major` findings → loop back.

Each role is its **own headless `claude -p`** (not Task-delegation) so the shell can run the gate
between phases and bound the loop. Role prompts get the matching `agents/<role>.md` body via
`--append-system-prompt` (frontmatter stripped by `lhtask_agent_body`); roles exchange JSON sidecars
in `.lhtask-state/` inside the worktree (excluded from commits via the worktree's `info/exclude`).
**Only `gate.json` is machine-trusted** (shell-authored); agent JSON is parsed jq-or-grep,
**fail-closed** (missing/garbled review JSON = blocker → loopback, never a silent DONE).

On convergence or exhaustion, `lhtask_findings_surface` publishes `TODO.review.md` (sections:
Gate · Fallow · Model fallbacks · Reviews · Delivery (only when `LHTASK_DELIVERY=apply`) ·
Tooling) and the
`## 🔎` pointer — the in-loop reviewers replace the old terminal `lhtask-review.sh` call (the hook
can't review agent commits because they set `AUTOPLAN_AGENT=1`; `LHTASK_REVIEW_AUTONOMOUS=0` leaves
a gate-only loop). The traffic-light summary (`lhtask_surface_review`) counts only **line-leading**
✅/⚠️/❌ markers — a marker mentioned mid-sentence in review prose ("no ❌ findings") is not a finding
and must not raise a false `## 🔎` pointer (its `AGENT_LOG.md` append would dirty the tree and trip
the next apply-delivery overlap check). The impl branch is **never auto-merged** and **hard-reset (`-B`) each run** — it
can carry several unmerged commits, so target-repo users must merge or discard promptly.
`templates/scripts/lhtask-lib.sh` holds shared helpers sourced by all stages, including the gate.

When changing any stage script, preserve these load-bearing invariants:

- **Loop safety:** agent processes export `AUTOPLAN_AGENT=1`; the hook and scripts skip when it's set.
  Anything that commits from inside an agent run must keep this set or it will recurse infinitely.
- **GIT_DIR unset:** every stage script starts by unsetting `GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  GIT_PREFIX GIT_QUARANTINE_PATH`. Git injects these into post-commit subprocesses; without clearing
  them `git worktree add` resolves against the hook's quarantined index and fails. Don't remove this.
- **Skip convention:** `lhtask_strip_skipped` (in `lhtask-lib.sh`) removes items inside `<!-- … -->`,
  under `## 🚧` (Deferred), and under `## 🔎` (Review-Findings). Plan/implement act only on what's left.
  High-risk items are moved under `## 🚧 Deferred`, never implemented autonomously.
- **Locking:** each stage takes a `mkdir` lock under `.git/lhtask-*.lock`; `lhtask_reap_stale_lock`
  clears locks older than N minutes so a killed run can't permanently block the chain.
- **Detached by default:** stages background themselves so the commit returns immediately. Set
  `LHTASK_FOREGROUND=1` to run synchronously (this is the debugging/testing lever).
- **Graceful no-op:** every stage exits 0 if `claude` (or, for codegraph, `codegraph`) is absent;
  the gate records a check whose command is unconfigured or whose tool is off PATH as `skip`,
  never a hard fail; missing `timeout`/`gtimeout` just means no per-phase timeout. Fallow follows
  the same rule: not installed → skip, runtime/config error (exit 2) → skip, and it is **never
  `npx`-downloaded** (only an already-installed binary runs — the gate stays offline-deterministic).
- **Tooling visibility (graceful, never silent):** degraded tooling must be REPORTED —
  `lhtask_tooling_to_md` writes the `### Tooling` section of every `TODO.review.md` (in-loop via
  `lhtask_findings_surface` and standalone in `lhtask-review.sh`): codegraph (binary **and** repo
  index), fallow, jq, timeout as ✅/⚠️ with install hint and concrete impact, plus two conditional
  lines — `curl` only when a cross-vendor model is configured (`lhtask_any_xvendor`; it powers the
  proxy probe) and the desktop notifier only when `LHTASK_NOTIFY=1`. A deliberate `off`
  config shows as a neutral note, ⚠️ counts into the traffic-light summary. Gate checks skipped
  because their **tool is missing** render as ⚠️ with an install/`LHTASK_GATE_<NAME>` hint
  (fallow: `LHTASK_FALLOW_CMD`) via `lhtask_json_checks_to_md` — this covers all per-stack tools
  generically (eslint, tsc, ruff, pytest, cargo, …); "no command configured" stays a neutral
  note. The `bootstrap` and
  `update` skills run the same check as a mandatory step. Don't let a new tool skip silently.
- **Permission hardening:** `AUTOPLAN_AGENT=1` is set centrally in `run_phase` (never per
  call-site). Every role gets the hard deny rules from `lhtask_deny_settings` via `--settings`
  (`git push`/`git reset --hard`/`git rebase`/`rm -rf`/`Task`/`Agent` — deny is evaluated first
  and can't be re-allowed); reviewers/planner/navigator run read-only (`dontAsk` + allowlist),
  the implementer commit-capable (`acceptEdits`). Don't widen these casually.
- **Fail-closed review parsing:** `lhtask_review_max_severity` treats a missing, empty, or
  unparseable review sidecar as `blocker`. Keep that direction — a garbled report must loop back,
  not pass. (Exception by design: `lhtask_fallow_to_md` is fail-OPEN — a missing `fallow.json`
  just means fallow didn't run; the gate already enforced the verdict where it matters.)
- **Delivery never auto-commits:** with `LHTASK_DELIVERY=apply` (default stays `branch`), FULLY
  converged work (gate green + reviews ok) is staged into the user's working tree via
  `git merge --squash` (`lhtask_apply_impl` in `lhtask-lib.sh`) — IDE-native review, the *user*
  makes the commit. It applies only when provably conflict-free (the impl branch sits exactly on
  the current HEAD, and no branch-changed path overlaps local uncommitted changes) and never
  unstages pre-existing user-staged work on cleanup; anything else falls back to branch mode with
  the reason surfaced under `### Delivery` (⚠️ counts into the traffic light, never silent). The
  branch is kept as backup either way (hard-reset on the next run).
- **Graceful but LOUD model fallback:** a configured cross-vendor model that does not run falls
  back to the Claude chain AND is recorded via `lhtask_model_fallback_note` — surfaced as ❌ under
  `### Model fallbacks` in `TODO.review.md` (→ 🔎 pointer + `AGENT_LOG`). Causes: proxy
  unconfigured/unreachable (pre-flight `curl` probe), or a cross-vendor reviewer's verdict JSON
  missing/unparseable — that one gets ONE forced-Claude retry (`LHTASK_FORCE_CLAUDE=1`, unset
  right after) before fail-closed applies. Degradation is acceptable; *silent* degradation is not.

## Configuration is the single source of truth

`templates/lhtask.conf` defines every tunable (review dirs, test command with `{path}` placeholder,
constitution files, impl branch, delivery mode (`LHTASK_DELIVERY` — `branch` default, `apply` =
squash-stage converged work into the working tree), venv to symlink, codegraph mode, the model block — global
`LHTASK_MODEL` plus the per-role overrides `LHTASK_MODEL_{PLAN,PLANNER,NAVIGATOR,IMPLEMENTER,
REVIEWER_CORRECTNESS,REVIEWER_CONVENTIONS,REVIEW}`, resolved per phase by `lhtask_model_flags [role]`
(role-specific → `LHTASK_MODEL` → CLI default; role names map uppercase with `-`→`_`, e.g.
`reviewer-correctness` → `LHTASK_MODEL_REVIEWER_CORRECTNESS`) so implementer and reviewers can run
on different models. A per-role value of the form `openrouter:<vendor>/<model>` runs that role
**cross-vendor** behind the Anthropic-compatible translating proxy `LHTASK_PROXY_URL` (e.g. LiteLLM
`/v1/messages`; setup: `docs/CROSS-VENDOR.md`) — `lhtask_model_flags` injects
`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` per role *process* only, sibling roles stay on the
native API. `LHTASK_PROXY_TOKEN` and other machine-local secrets belong in `~/.config/lhtask/env`
(never the committed conf), which `lhtask_load_config` sources *after* the repo's `lhtask.conf` so
it wins. The conf further holds the autonomous-review
and notify toggles, plus the subagent/gate block: `LHTASK_STACK`, the four `LHTASK_GATE_*` commands,
the fallow keys `LHTASK_FALLOW` (`auto`/`off`) and `LHTASK_FALLOW_CMD` (full command override,
`{base}` placeholder), `LHTASK_MAX_ITER`, `LHTASK_PHASE_TIMEOUT`, and the stage-2 visual-reviewer keys
`LHTASK_VISUAL_MAX_DIFF_RATIO`/`LHTASK_DEV_URL`). Defaults are duplicated in two places that
**must stay in sync** with the conf: `lhtask_load_config` in `lhtask-lib.sh`, and the inline
defaults at the top of `post-commit` (the hook reads only `LHTASK_REVIEW_DIRS` and
`LHTASK_CODEGRAPH` before scripts source the full lib). Empty `LHTASK_GATE_*` keys fall back to
built-in per-stack defaults in `lhtask_gate_cmd` (test additionally falls back to the legacy
`LHTASK_TEST_CMD`).

## The constitution preamble

`lhtask_preamble` (in `lhtask-lib.sh`) is prepended to every agent prompt and forces the agent to
read the project's constitution files (`LHTASK_CONSTITUTION_FILES`, default `AGENTS.md`) first and
obey their risk tiers. `templates/AGENTS.md` is the starter constitution; its risk-tier lists are
what the autonomous implementer refuses to touch. Behavior is meant to be steered by editing the
*constitution in the target repo*, not by hardcoding rules into the scripts.

## Editing skills

Skills are markdown with YAML frontmatter (`name`, `description`, `argument-hint`). `lh-task` is a
*refinement* workflow (idea → one structured `TODO.md` item; never writes code, never auto-commits).
`bootstrap` is an *idempotent installer* (`cp -n` everywhere; never clobbers an existing file without
asking). `update` *re-syncs the vendored chain* in already-bootstrapped repos (overwrites only logic
files — scripts, hooks, agents; never `lhtask.conf` or lifecycle files; `--all` consumes the registry
at `~/.config/lhtask/registry` — registering is exclusively `bootstrap`'s job, opt-in with an
explicit ask; `update` never self-registers). Both end with a **mandatory tooling check**
(codegraph incl. repo index, fallow, jq, timeout — install command + concrete impact when
missing, mirroring the `### Tooling` report section). Both resolve templates from the plugin **as installed**:
`${CLAUDE_PLUGIN_ROOT}/templates`, falling back to the newest marketplace-cache copy
(`~/.claude/plugins/cache/*/lhtask/*/templates`) when `CLAUDE_PLUGIN_ROOT` is unset — and otherwise
they stop with the GitHub install instruction. Never let them search the filesystem or accept a
development checkout as `$TPL` (enforces `docs/DISTRIBUTION.md`); keep the
`templates/` path relationship intact if you move files. The `description` field is what triggers the skill,
so keep it specific and outcome-oriented. The skills register the `/lhtask:*` slash commands
themselves — never add `commands/*.md` wrappers: they register the same names and **shadow the
skills** (invoking the skill then returns the instruction-less wrapper body; this is exactly what
v0.3.3 removed).

Agent files (`agents/*.md`) carry their own frontmatter (`name`, `description`, `tools`, `model`)
for interactive use; the headless loop strips it — headless model choice comes solely from the
`LHTASK_MODEL*` keys in `lhtask.conf`, never from agent frontmatter. `reviewer-visual` is a
**scaffold** — shipped and vendored, but not yet wired into the implement loop.

## Project commands & doc automation

This repo has no build toolchain, but a small `Makefile` wraps the setup + doc + sync steps:

- `make setup` — one-time per clone: `chmod +x` the hooks/scripts and `git config core.hooksPath
  .githooks` (this is local config, not committed, so every clone must run it).
- `make docs` — run `scripts/docs-refresh.sh`: headless `claude` regenerates the three
  source-of-truth docs (`CLAUDE.md`, `ARCHITECTURE.md`, `README.md`) from the current sources.
- `make check` — `bash -n` (plus `shellcheck` if installed) over every shell script.
- `make sync-agents` — copy `agents/*.md` → `templates/.claude/agents/` (the two must stay identical).

CI (`.github/workflows/ci.yml`) runs on push/PR to `main`: it validates the JSON manifests
(`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`) and runs `shellcheck` +
`bash -n` over the template scripts and this repo's own `scripts/`.

`.githooks/pre-push` keeps those docs in sync: when a push changes a **source** file it regenerates
the docs, commits them, and pushes that commit along (one `git push`, docs included). It is
loop-guarded by `LHTASK_DOCS_PUSH_GUARD` and gated so headless `claude` only runs on real source
changes. Levers: `LHTASK_DOCS_SKIP=1 git push`, kill switch `touch .git/docs-refresh.disabled`.

**Completeness principle (don't break it):** "source" is defined by *exclusion*, not an allowlist —
in both `.githooks/pre-push` (`DOC_EXCLUDE`) and the `docs-refresh.sh` prompt, every tracked file is
a doc source EXCEPT the generated docs (`CLAUDE.md`/`ARCHITECTURE.md`/`README.md`) and noise
(`.gitignore`, `.vscode/`, `.claude/`, `*.DS_Store`). This way a newly added source file can never be
silently forgotten. If you add a real exclusion, change it in *both* places.

## Testing changes to the chain

`tests/smoke-test.sh` is the end-to-end smoke test: it starts with a claude-free unit section
covering the `lhtask_model_flags` resolution chain (role beats global, fallback, name mapping) and
its cross-vendor branch (prefix parsing, env injection, no-proxy/unreachable fallback + recording,
forced-Claude retry, `lhtask_model_is_xvendor`) plus the tooling surface (`lhtask_tooling_to_md`
reports every supporting tool; `off` → neutral note; conditional curl/notifier lines; missing-tool
gate skips rendered as ⚠️ with config hint), the delivery helper (`lhtask_apply_impl`: happy path
stages without committing and keeps the branch; dirty overlap and HEAD-moved fall back with a
reason and stage nothing; unrelated dirty files don't block), the plan idle-guard pattern
(dashed and bare checkbox items both count as active) and the traffic-light counting
(`lhtask_surface_review`: only line-leading ❌ raises the 🔎 pointer, prose mentions don't),
then bootstraps the plugin into a throwaway repo
(`claude -p --plugin-dir … "/lhtask:bootstrap"`), commits a `TODO.md` task, runs the chain with
`LHTASK_FOREGROUND=1`, and asserts `TODO.run.log` was produced. The E2E part needs the `claude`
CLI, so it is not run in CI. To debug a change manually, bootstrap into a throwaway git repo and use:

```bash
LHTASK_FOREGROUND=1 .githooks/post-commit   # run the triggered stage synchronously
tail -f TODO.run.log                        # consolidated human-visible trace (reset each trigger)
cat .git/lhtask-implement.log               # raw per-stage log
touch .git/autoplan.disabled                # kill switch
```

`shellcheck` is the relevant linter for the bash scripts (scripts carry `# shellcheck source=` hints).
