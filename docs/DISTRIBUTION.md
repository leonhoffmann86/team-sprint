# Distribution & repo separation

This document defines **how the sprint plugin is distributed** and **how the public
plugin repo stays strictly separated from the repos that consume it**. It is binding
for plugin development; the generated docs (`CLAUDE.md`, `ARCHITECTURE.md`, `README.md`)
summarize it.

## Canonical channel: GitHub — never a local clone

The **only** supported way to install and run the plugin is the public GitHub
marketplace. This applies to maintainers too — the development clone is for
*developing* the plugin, not for *using* it:

```bash
# one-time, user scope (available in every repo):
claude plugin marketplace add leonhoffmann86/team-sprint
claude plugin install sprint@team-sprint

# pick up a new release later:
claude plugin marketplace update team-sprint
claude plugin update sprint
```

`--plugin-dir <dev-clone>` is reserved for testing the plugin itself (e.g.
`tests/smoke-test.sh`); it must never be the standing way a working repo loads sprint.
The `bootstrap`/`update` skills enforce this: with `CLAUDE_PLUGIN_ROOT` unset they fall
back to the installed marketplace-cache copy and otherwise stop with the install
instruction — a development checkout is never accepted as a template source.
The marketplace manifest lives at `.claude-plugin/marketplace.json` (the CLI resolves
exactly that path — keep it there), the plugin manifest at `.claude-plugin/plugin.json`;
versions in both plus `CHANGELOG.md` stay in sync per release.

## The separation model

Consumer repos may be **internal and security-relevant**; this plugin repo is
**public**. The boundary between them is one-way by design:

- **Data flows only plugin → consumer.** `bootstrap`/`update` copy generic template
  files into the consumer. Nothing consumer-specific is ever read into, referenced by,
  or committed to this repo — no paths, no names, no configuration.
- **The vendored chain is self-contained.** After bootstrap, the consumer's
  `scripts/sprint-*.sh`, `.githooks/`, `.claude/agents/` and `sprint.conf` run with zero
  reference to the plugin (everything resolves relative to the consumer repo). A
  consumer never needs the dev clone on disk, and removing the plugin does not break
  the installed chain.
- **Updates are pull-based.** `/sprint:update` is run *inside the consumer repo, by its
  user*, against the GitHub-installed plugin version. Plugin-side sessions never reach
  into consumer repos. The registry (`~/.config/sprint/registry`, consumed by
  `/sprint:update --all`) is a machine-local, opt-in convenience — keep internal repos
  out of it when strict separation is required.
- **Fixes flow the same one way.** Sessions running in a consumer repo must NOT write
  into the plugin dev repo — not even for a correct fix to the vendored chain. Fix the
  vendored copy locally if the chain is blocked, and *report* the finding so the change
  is reviewed and released plugin-side; an unreviewed cross-repo edit can silently ride
  into a release on the next broad commit.

## External tools follow the same rule

The chain's optional tool integrations are consumed **as installed binaries from their
upstream**, never vendored and never path-coupled to a local clone:

- **codegraph** (<https://github.com/colbymchenry/codegraph>) — `.mcp.json` invokes the
  `codegraph` binary from `PATH`; absent → graceful skip.
- **fallow** (<https://docs.fallow.tools>) — the gate runs an already-installed `fallow`
  binary (`PATH` or `./node_modules/.bin`); absent → check skipped, never `npx`-downloaded.

## Release checklist

1. Bump the version in `.claude-plugin/plugin.json` **and**
   `.claude-plugin/marketplace.json`, add a `CHANGELOG.md` entry.
2. Push (the `pre-push` hook regenerates the three generated docs from sources).
3. Consumers: `claude plugin marketplace update team-sprint && claude plugin
   update sprint`, then `/sprint:update` inside each repo when convenient.
