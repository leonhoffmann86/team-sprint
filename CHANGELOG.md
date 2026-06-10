# Changelog

All notable changes to LHTask will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.0]: https://github.com/leonhoffmann/lhtask-plugin/releases/tag/v0.2.0
