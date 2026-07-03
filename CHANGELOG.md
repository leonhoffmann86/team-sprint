# Changelog

All notable changes to Sprint will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-07-03

### Added
- **Scan trigger (`SPRINT_TRIGGER=scan`)** for repos whose `TODO.md` is deliberately
  untracked: `scripts/sprint-scan.sh` + launchd/systemd poll templates
  (`templates/trigger/`). Poll-don't-watch architecture: a 30s timer runs a
  scan-reconcile pickup (active-item content hash vs. `.git/sprint-scan.hash`,
  atomic `mkdir` claim) — no file watchers, no commit required. Commit trigger
  unchanged and can run alongside; both share the `.git/autoplan.disabled` kill switch.
- **`scripts/sprint-standup.sh`**: live terminal view of the running chain —
  lock-based running/idle status, current phase banner, streaming tool-call trace.

[1.1.0]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v1.1.0

## [1.0.0] — 2026-07-03

### Changed
- **Renamed: LHTask → Sprint.** The plugin now models what it always was — every
  TODO item runs through a full mini-sprint (plan → implement → review → done).
  Breaking renames, no functional changes:
  - Plugin `lhtask` → `sprint`; marketplace `lhtask-marketplace` → `team-sprint`;
    repo `lhtask-plugin` → `team-sprint` (GitHub redirects the old URL)
  - Skills: `/lhtask:lh-task` → `/sprint:ticket`, `/lhtask:bootstrap` →
    `/sprint:bootstrap`, `/lhtask:update` → `/sprint:update`
  - Agents: `lhtask:planner` etc. → `sprint:planner` etc.
  - Vendored files: `lhtask.conf` → `sprint.conf`, `scripts/lhtask-*.sh` →
    `scripts/sprint-*.sh`, env/config vars `LHTASK_*` → `SPRINT_*`
- **Migration for bootstrapped repos:** re-run `/sprint:bootstrap` (or rename the
  vendored files/vars as above); the old registry path `~/.config/lhtask/registry`
  moves to `~/.config/sprint/registry`.

[1.0.0]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v1.0.0

## [0.9.0] — 2026-06-11

### Added
- **Live activity trace**: every headless phase (plan, all loop roles, standalone
  review) streams its tool calls into `TODO.run.log` as terse lines
  (`⚙ implementer → Edit: app/x.py`, `✔ implementer done — 23 turns: …`) via
  `claude -p --output-format stream-json` + a jq renderer — `tail -f TODO.run.log`
  is now a real-time status view instead of staying silent for whole phases
  ("hung or working?"). Non-JSON stderr lines (real errors) stay visible verbatim.
  `SPRINT_STREAM="auto"` (default; requires jq — without jq or with `off` the
  behaviour is exactly as before), verified end-to-end against the live CLI

[0.9.0]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.9.0

## [0.8.2] — 2026-06-11

### Fixed
- Traffic-light counting in `sprint_surface_review` only counts **line-leading**
  ✅/⚠️/❌ markers: a review report mentioning "no ❌ findings" in prose was counted
  as a finding, raising a false `## 🔎` pointer whose `AGENT_LOG.md` append then
  dirtied the working tree and needlessly tripped the next apply-delivery overlap
  fallback (observed live in a consumer run)

[0.8.2]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.8.2

## [0.8.1] — 2026-06-11

### Fixed
- Plan-stage idle guard now also accepts bare `[ ]` checkbox items (without a
  leading `-`/`*` bullet): a consumer repo with that TODO style got a false
  "no active TODO items — nothing to plan" and the chain silently skipped real
  work. A false "nothing to do" is worse than one idle run, so the guard is
  deliberately tolerant

[0.8.1]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.8.1

## [0.8.0] — 2026-06-11

### Added
- `SPRINT_DELIVERY="apply"` (default stays `"branch"`): FULLY converged autonomous
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
  repo (`../.sprint-worktree-<repo>`): the agent permission layer auto-denies every
  write under a `.git/` path, so the implementer could never edit a file in its
  worktree — every autonomous run ended `impl-error` after zero edits. Discovered
  and verified during a consumer-repo run (re-trigger converged after the move)

[0.8.0]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.8.0

## [0.7.0] — 2026-06-10

### Added
- Tooling visibility now covers EVERY tool the chain touches:
  - Gate checks skipped because their TOOL IS MISSING render as
    `⚠️ gate:<name> — tool 'x' not on PATH (install it or set SPRINT_GATE_<NAME>)` —
    this generically covers all per-stack tools (eslint, tsc, ruff, mypy, pytest,
    phpcs/phpstan/pest, go, cargo, …); "no command configured" stays a neutral note
  - `### Tooling` additionally reports `curl` (only when a cross-vendor model is
    configured — it powers the proxy reachability probe) and the desktop notifier
    (only when `SPRINT_NOTIFY=1` — previously notifications dropped silently)

[0.7.0]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.7.0

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
- `update` no longer self-registers the current repo in `~/.config/sprint/registry`
  (consume-only). Registration is exclusively `bootstrap`'s job and now OPT-IN with
  an explicit ask — internal repos stay out of the registry deliberately

[0.6.0]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.6.0

## [0.5.0] — 2026-06-10

### Added
- Cross-vendor models per role (Phase 2): `SPRINT_MODEL_<ROLE>="openrouter:<vendor>/<model>"`
  runs that role on a non-Claude model through an Anthropic-compatible translating
  proxy (`SPRINT_PROXY_URL`, e.g. LiteLLM `/v1/messages` in front of OpenRouter);
  `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` are injected per role process only.
  Setup guide: `docs/CROSS-VENDOR.md`
- Graceful **and loud** degradation: proxy unconfigured/unreachable → role falls back
  to the Claude chain; a cross-vendor reviewer whose fail-closed verdict JSON is
  missing/unparseable gets ONE Claude retry before the blocker applies. Every
  fallback is recorded and surfaced as ❌ under `### Model fallbacks` in
  `TODO.review.md` → `## 🔎 Review-Findings` pointer + `AGENT_LOG.md` (+ notify) —
  a configured-but-inactive foreign reviewer can never go unnoticed
- Secrets stay out of the repo: machine-local `~/.config/sprint/env` is sourced
  after `sprint.conf` (e.g. `SPRINT_PROXY_TOKEN`)
- Smoke test: cross-vendor unit assertions (prefix parsing, env injection,
  no-proxy/unreachable fallbacks + recording, forced-Claude retry, raw detection)

[0.5.0]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.5.0

## [0.4.0] — 2026-06-10

### Added
- Per-role model configuration for the headless chain (Claude family): new optional
  conf keys `SPRINT_MODEL_PLAN`, `SPRINT_MODEL_PLANNER`, `SPRINT_MODEL_NAVIGATOR`,
  `SPRINT_MODEL_IMPLEMENTER`, `SPRINT_MODEL_REVIEWER_CORRECTNESS`,
  `SPRINT_MODEL_REVIEWER_CONVENTIONS`, `SPRINT_MODEL_REVIEW` — so implementer and
  reviewers can run on different models (no shared blind spots)
- `sprint_model_flags [role]` resolves role-specific → `SPRINT_MODEL` (global) →
  empty (CLI default); role names map via uppercase + `-`→`_`. `run_phase` resolves
  per phase; the plan/review stages pass their stage names
- Smoke test gained a claude-free unit section covering the resolution chain
  (role beats global, fallback, name mapping)

### Unchanged by design
- Backwards compatible: without the new keys behaviour is identical to before.
  Agent frontmatter `model:` stays interactive-only — `sprint.conf` remains the
  single source of truth for headless model choice

[0.4.0]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.4.0

## [0.3.3] — 2026-06-10

### Fixed
- Removed the `commands/*.md` wrapper shims: they registered the same names as the
  skills (`sprint:update` etc.) and **shadowed them** — invoking the skill returned the
  instruction-less wrapper body, so `/sprint:update` ran without its actual steps.
  The skills in `skills/` register the namespaced slash commands themselves; per
  current plugin guidance `commands/` is legacy and `skills/` is canonical

[0.3.3]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.3.3

## [0.3.2] — 2026-06-10

### Changed
- Hardened template resolution in the `bootstrap` and `update` skills: when
  `CLAUDE_PLUGIN_ROOT` is unset (skill executed manually), they now resolve the
  **installed** plugin from the marketplace cache (most recently installed version);
  if no install exists they stop with the GitHub install instruction. Searching the
  filesystem for a plugin source tree or using a development checkout as the template
  source is explicitly forbidden (enforces `docs/DISTRIBUTION.md`)

[0.3.2]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.3.2

## [0.3.1] — 2026-06-10

### Fixed
- Moved `marketplace.json` to `.claude-plugin/marketplace.json` — the CLI resolves
  exactly that path, so `claude plugin marketplace add leonhoffmann86/team-sprint`
  (GitHub install) now works; CI manifest checks updated accordingly

### Added
- `docs/DISTRIBUTION.md` — binding distribution & separation model: GitHub is the only
  install channel (also for maintainers; `--plugin-dir` is test-only), data flows
  one-way plugin → consumer, the vendored chain is self-contained, updates are
  pull-based (`/sprint:update` inside the consumer repo), the registry is opt-in and
  must not list internal repos when strict separation is required

[0.3.1]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.3.1

## [0.3.0] — 2026-06-10

### Added
- Fallow static analysis (<https://docs.fallow.tools>) integrated into the review chain:
  - Fifth deterministic gate check: `fallow audit` scoped to the item commit's changeset,
    gated "new-only" (only findings *introduced* by the change fail → loopback to the
    implementer with the JSON report as part of the fix list)
  - Raw report saved as `.sprint-state/fallow.json`; reviewers are instructed to fold
    its findings into their verdict
  - `### Fallow` section in `TODO.review.md` (both the in-loop surface and the
    standalone stage-3 review of human commits)
  - Config: `SPRINT_FALLOW` (`auto` = run if installed on PATH or `./node_modules/.bin`,
    `off` = never) and `SPRINT_FALLOW_CMD` (full command override with `{base}`
    placeholder — e.g. to add the licensed runtime layer via `--coverage`)
  - Graceful no-op throughout: not installed → check skipped; fallow runtime/config
    error (exit 2) → skip, never a hard fail; never `npx`-downloads (gate stays offline)

[0.3.0]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.3.0

## [0.2.0] — 2026-06-10

### Added
- Autonomous plan→implement→review chain triggered by git post-commit hook
- Subagent team: planner, navigator, implementer, reviewer-correctness, reviewer-conventions
- Deterministic gate (lint/typecheck/test/build) between implementer and reviewers
- Fail-closed review parsing (missing or garbled JSON treated as blocker)
- Worktree isolation on never-auto-merged branch (`autoplan/impl`)
- Bounded implement loop (default 3 iterations, configurable via `SPRINT_MAX_ITER`)
- Hard deny rules per role: `git push`, `git reset --hard`, `git rebase`, `rm -rf`, `Task`/`Agent` — denied for all agent roles
- `ticket` skill for idea → structured TODO.md item refinement
- `bootstrap` skill for idempotent repo setup (hooks, config, constitution)
- `update` skill for re-syncing vendored chain after plugin updates
- Doc automation via pre-push hook (regenerates CLAUDE.md, ARCHITECTURE.md, README.md)
- MIT license
- Security: read-only roles for planner/navigator/reviewers; kill switch (`touch .git/autoplan.disabled`)
- Lock-based concurrency control with stale-lock reaping
- GIT_DIR-unsetting to prevent quarantine conflicts
- Configuration via `sprint.conf` and starter `AGENTS.md` constitution

[0.2.0]: https://github.com/leonhoffmann86/team-sprint/releases/tag/v0.2.0
