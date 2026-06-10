# Changelog

All notable changes to LHTask will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
