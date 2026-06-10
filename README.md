# LHTask

Autonomous TODO workflow as a portable Claude Code plugin: refine a rough idea into one
structured `TODO.md` item, then let a git-hook chain **plan → implement → review** it. The
implementer is a **subagent team** (planner → navigator → implementer → deterministic gate →
reviewers, in a bounded loop) working in an isolated worktree on a branch that is **never
auto-merged**; high-risk work is deferred to a human. Language-agnostic and config-driven,
so it drops into any repo.

## Install & use

```bash
claude --plugin-dir /path/to/lhtask-plugin     # or: /plugin marketplace add <git-url>

# inside any repo you want to enable:
/lhtask:bootstrap                               # writes hooks + lhtask.conf + starters
/lhtask:lh-task "your idea"                     # capture the first task
git add TODO.md && git commit -m "task: ..."    # starts the chain
```

Kill switch: `touch .git/autoplan.disabled` · live trace: `tail -f TODO.run.log`.

## Mehr

The deep documentation is the source of truth and stays current automatically (see *Doc
automation* below) — start here:

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — full visual deep-dive (Mermaid diagrams of the chain, routing, worktree isolation, skip convention, loop-safety).
- **[CLAUDE.md](CLAUDE.md)** — agent-native source of truth: the mental model and the load-bearing invariants for anyone editing the chain.
- **[skills/lh-task/SKILL.md](skills/lh-task/SKILL.md)** — the idea → one structured TODO item refinement workflow.
- **[skills/bootstrap/SKILL.md](skills/bootstrap/SKILL.md)** — the idempotent installer that scaffolds the chain into a repo.
- **[skills/update/SKILL.md](skills/update/SKILL.md)** — re-syncs the vendored chain in bootstrapped repos after a plugin update.
- **[templates/lhtask.conf](templates/lhtask.conf)** — the single config (review dirs, gate commands, impl branch, max iterations, model, …).
- **[templates/AGENTS.md](templates/AGENTS.md)** — the starter *constitution* whose risk tiers the autonomous implementer obeys.
- **[templates/githooks/README.md](templates/githooks/README.md)** — what the installed `post-commit` chain does, stage by stage.

## Doc automation

`ARCHITECTURE.md`, `CLAUDE.md` and this README stay in sync with the code via a `pre-push` hook:
when a push changes any **source** file (everything tracked except the generated docs and editor
noise — so new files can't be forgotten), it regenerates the docs (headless `claude`), commits
them, and pushes that commit along — one `git push`, fresh docs included.

```bash
make setup            # one-time per clone: activate the hook + make scripts executable
make docs             # regenerate the docs on demand
make check            # syntax-check the shell scripts
make                  # list all commands

LHTASK_DOCS_SKIP=1 git push           # skip the refresh for one push
touch .git/docs-refresh.disabled      # disable it entirely (rm to re-enable)
```
