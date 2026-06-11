# Changelog

All notable changes to LHTask will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] — 2026-06-11

### Added
- `LHTASK_DELIVERY="apply"` (default stays `"branch"`): FULLY converged autonomous
  work (gate green + reviews ok) is delivered as **staged, uncommitted changes** in
  the user's working tree (`git merge --squash`) — IDE-native review in the changes
  view, the USER makes the commit (the never-auto-commit/merge invariant holds).
  Applies only when provably conflict-free (impl branch sits exactly on HEAD, no
  overlap with local uncommitted changes); otherwise it falls back to branch mode
  with the reason in the new `### Delivery` section of `TODO.review.md`
  (✅/⚠️ counts into the traffic light). The branch is kept as backup either way
- Plan stage skips cleanly when `TODO.md` has no active `- [ ]` item left (e.g. the
  commit of an applied/merged chain result) — no more idle headless run

### Fixed
- **Implementer worktree moved out of `.git/`** to a sibling directory next to the
  repo (`../.lhtask-worktree-<repo>`): the agent permission layer auto-denies every
  write under a `.git/` path, so the implementer could never edit a file in its
  worktree — every autonomous run ended `impl-error` after zero edits. Discovered
  and verified during a consumer-repo run (re-trigger converged after the move)

[0.8.0]: https://github.com/leonhoffmann86/lhtask-plugin/releases/tag/v0.8.0

## [0.7.0] — 2026-06-10

### Added
- Tooling visibility now covers EVERY tool the chain touches:
  - Gate checks skipped because their TOOL IS MISSING render as
    `⚠️ gate:<name> — tool 'x' not on PATH (install it or set LHTASK_GATE_<NAME>)` —
    this generically covers all per-stack tools (eslint, tsc, ruff, mypy, pytest,
    phpcs/phpstan/pest, go, cargo, …); "no command configured" stays a neutral note
  - `### Tooling` additionally reports `curl` (only when a cross-vendor model is
    configured — it powers the proxy reachability probe) and the desktop notifier
    (only when `LHTASK_NOTIFY=1` — previously notifications dropped silently)

[0.7.0]: https://github.com/leonhoffmann86/lhtask-plugin/releases/tag/v0.7.0

## [0.6.0] — 2026-06-10

### Added
- `### Tooling` section in every `TODO.review.md` (in-loop surface and standalone
  review): ✅/⚠️ status per supporting tool — codegraph (binary + repo index), fallow,
  jq, timeout — with install command and concrete impact when missing. The chain
  still degrades gracefully, but degraded tooling is now REPORTED, never silent
- `bootstrap` and `update` skills gained a mandatory tooling-check step with the
  same install hints (codegraph: <https://github.com/colbymchenry/codegraph>,
  fallow: <https://docs.fallow.tools>)

### Fixed
- `update` no longer self-registers the current repo in `~/.config/lhtask/registry`
  (consume-only). Registration is exclusively `bootstrap`'s job and now OPT-IN with
  an explicit ask — internal repos stay out of the registry deliberately

[0.6.0]: https://github.com/leonhoffmann86/lhtask-plugin/releases/tag/v0.6.0

## [0.5.0] — 2026-06-10

### Added
- Cross-vendor models per role (Phase 2): `LHTASK_MODEL_<ROLE>="openrouter:<vendor>/<model>"`
  runs that role on a non-Claude model through an Anthropic-compatible translating
  proxy (`LHTASK_PROXY_URL`, e.g. LiteLLM `/v1/messages` in front of OpenRouter);
  `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` are injected per role process only.
  Setup guide: `docs/CROSS-VENDOR.md`
- Graceful **and loud** degradation: proxy unconfigured/unreachable → role falls back
  to the Claude chain; a cross-vendor reviewer whose fail-closed verdict JSON is
  missing/unparseable gets ONE Claude retry before the blocker applies. Every
  fallback is recorded and surfaced as ❌ under `### Model fallbacks` in
  `TODO.review.md` → `## 🔎 Review-Findings` pointer + `AGENT_LOG.md` (+ notify) —
  a configured-but-inactive foreign reviewer can never go unnoticed
- Secrets stay out of the repo: machine-local `~/.config/lhtask/env` is sourced
  after `lhtask.conf` (e.g. `LHTASK_PROXY_TOKEN`)
- Smoke test: cross-vendor unit assertions (prefix parsing, env injection,
  no-proxy/unreachable fallbacks + recording, forced-Claude retry, raw detection)

[0.5.0]: https://github.com/leonhoffmann86/lhtask-plugin/releases/tag/v0.5.0

## [0.4.0] — 2026-06-10

### Added
- Per-role model configuration for the headless chain (Claude family): new optional
  conf keys `LHTASK_MODEL_PLAN`, `LHTASK_MODEL_PLANNER`, `LHTASK_MODEL_NAVIGATOR`,
  `LHTASK_MODEL_IMPLEMENTER`, `LHTASK_MODEL_REVIEWER_CORRECTNESS`,
  `LHTASK_MODEL_REVIEWER_CONVENTIONS`, `LHTASK_MODEL_REVIEW` — so implementer and
  reviewers can run on different models (no shared blind spots)
- `lhtask_model_flags [role]` resolves role-specific → `LHTASK_MODEL` (global) →
  empty (CLI default); role names map via uppercase + `-`→`_`. `run_phase` resolves
  per phase; the plan/review stages pass their stage names
- Smoke test gained a claude-free unit section covering the resolution chain
  (role beats global, fallback, name mapping)

### Unchanged by design
- Backwards compatible: without the new keys behaviour is identical to before.
  Agent frontmatter `model:` stays interactive-only — `lhtask.conf` remains the
  single source of truth for headless model choice

[0.4.0]: https://github.com/leonhoffmann86/lhtask-plugin/releases/tag/v0.4.0

## [0.3.3] — 2026-06-10

### Fixed
- Removed the `commands/*.md` wrapper shims: they registered the same names as the
  skills (`lhtask:update` etc.) and **shadowed them** — invoking the skill returned the
  instruction-less wrapper body, so `/lhtask:update` ran without its actual steps.
  The skills in `skills/` register the namespaced slash commands themselves; per
  current plugin guidance `commands/` is legacy and `skills/` is canonical

[0.3.3]: https://github.com/leonhoffmann86/lhtask-plugin/releases/tag/v0.3.3

## [0.3.2] — 2026-06-10

### Changed
- Hardened template resolution in the `bootstrap` and `update` skills: when
  `CLAUDE_PLUGIN_ROOT` is unset (skill executed manually), they now resolve the
  **installed** plugin from the marketplace cache (most recently installed version);
  if no install exists they stop with the GitHub install instruction. Searching the
  filesystem for a plugin source tree or using a development checkout as the template
  source is explicitly forbidden (enforces `docs/DISTRIBUTION.md`)

[0.3.2]: https://github.com/leonhoffmann86/lhtask-plugin/releases/tag/v0.3.2

## [0.3.1] — 2026-06-10

### Fixed
- Moved `marketplace.json` to `.claude-plugin/marketplace.json` — the CLI resolves
  exactly that path, so `claude plugin marketplace add leonhoffmann86/lhtask-plugin`
  (GitHub install) now works; CI manifest checks updated accordingly

### Added
- `docs/DISTRIBUTION.md` — binding distribution & separation model: GitHub is the only
  install channel (also for maintainers; `--plugin-dir` is test-only), data flows
  one-way plugin → consumer, the vendored chain is self-contained, updates are
  pull-based (`/lhtask:update` inside the consumer repo), the registry is opt-in and
  must not list internal repos when strict separation is required

[0.3.1]: https://github.com/leonhoffmann86/lhtask-plugin/releases/tag/v0.3.1

## [0.3.0] — 2026-06-10

### Added
- Fallow static analysis (<https://docs.fallow.tools>) integrated into the review chain:
  - Fifth deterministic gate check: `fallow audit` scoped to the item commit's changeset,
    gated "new-only" (only findings *introduced* by the change fail → loopback to the
    implementer with the JSON report as part of the fix list)
  - Raw report saved as `.lhtask-state/fallow.json`; reviewers are instructed to fold
    its findings into their verdict
  - `### Fallow` section in `TODO.review.md` (both the in-loop surface and the
    standalone stage-3 review of human commits)
  - Config: `LHTASK_FALLOW` (`auto` = run if installed on PATH or `./node_modules/.bin`,
    `off` = never) and `LHTASK_FALLOW_CMD` (full command override with `{base}`
    placeholder — e.g. to add the licensed runtime layer via `--coverage`)
  - Graceful no-op throughout: not installed → check skipped; fallow runtime/config
    error (exit 2) → skip, never a hard fail; never `npx`-downloads (gate stays offline)

[0.3.0]: https://github.com/leonhoffmann86/lhtask-plugin/releases/tag/v0.3.0

## [0.2.0] — 2026-06-10

### Added
- Autonomous plan→implement→review chain triggered by git post-commit hook
- Subagent team: planner, navigator, implementer, reviewer-correctness, reviewer-conventions
- Deterministic gate (lint/typecheck/test/build) between implementer and reviewers
- Fail-closed review parsing (missing or garbled JSON treated as blocker)
- Worktree isolation on never-auto-merged branch (`autoplan/impl`)
- Bounded implement loop (default 3 iterations, configurable via `LHTASK_MAX_ITER`)
- Hard deny rules per role: `git push`, `git reset --hard`, `git rebase`, `rm -rf`, `Task`/`Agent` — denied for all agent roles
- `lh-task` skill for idea → structured TODO.md item refinement
- `bootstrap` skill for idempotent repo setup (hooks, config, constitution)
- `update` skill for re-syncing vendored chain after plugin updates
- Doc automation via pre-push hook (regenerates CLAUDE.md, ARCHITECTURE.md, README.md)
- MIT license
- Security: read-only roles for planner/navigator/reviewers; kill switch (`touch .git/autoplan.disabled`)
- Lock-based concurrency control with stale-lock reaping
- GIT_DIR-unsetting to prevent quarantine conflicts
- Configuration via `lhtask.conf` and starter `AGENTS.md` constitution

[0.2.0]: https://github.com/leonhoffmann86/lhtask-plugin/releases/tag/v0.2.0
