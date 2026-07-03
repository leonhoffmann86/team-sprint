# Sprint trigger modes

Sprint starts its plan→implement→review chain in one of two ways:

| Mode | How it fires | When to use |
|---|---|---|
| **commit** (default) | post-commit hook: the commit that changed `TODO.md` starts the chain | `TODO.md` is tracked |
| **scan** (poll) | a 30s timer runs `scripts/sprint-scan.sh`; a content-hash of the ACTIVE unchecked items decides | `TODO.md` is deliberately untracked (e.g. the repo ships as a deploy artifact), or nobody should have to commit to queue work |

Design (poll, don't watch): file watchers are race-prone doorbells — launchd's
own manpage discourages `WatchPaths`, and editor atomic-saves break file-bound
watches. Correctness therefore lives in the *pickup*, not the trigger: the scan
re-reads `TODO.md`, hashes the active items, compares against
`.git/sprint-scan.hash`, and claims the run with an atomic `mkdir`. A missed
tick costs at most one interval of latency, never a lost task.

The kill switch is shared with the commit trigger: `touch .git/autoplan.disabled`.

## macOS (launchd)

1. Copy `sprint-poll.plist.tmpl` to `~/Library/LaunchAgents/net.sprint.<repo-slug>.plist`
   and replace `__REPO__` (absolute repo path) and `__SLUG__` (short name).
2. Load it:

   ```sh
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.sprint.<repo-slug>.plist
   ```

3. Check state / last exit code:

   ```sh
   launchctl print gui/$(id -u)/net.sprint.<repo-slug>
   ```

Unload (off switch): `launchctl bootout gui/$(id -u)/net.sprint.<repo-slug>`

Do not keep the repo under an iCloud-/Dropbox-synced path.

## Linux (systemd user timer)

Copy `sprint@.service` and `sprint@.timer` to `~/.config/systemd/user/`,
adjust the repo base path inside the service, then:

```sh
systemctl --user enable --now 'sprint@<repo-slug>.timer'
```
