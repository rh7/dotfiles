# Software Updates

How software gets updated on these Macs, what each mechanism does and does not
cover, and the traps that are easy to re-introduce.

## What updates what

| Mechanism | Covers | Runs |
|---|---|---|
| `rebuild.sh` | Nix closure, declared Homebrew formulae + casks, declared App Store apps | When you run it |
| Weekly LaunchAgent (`com.rh7.weekly-update`) | Declared Homebrew **formulae** only | Mondays 10:00 |
| Nothing | **macOS system updates**, **`flake.lock`**, undeclared packages | — |

The last row matters: **the weekly job is not full coverage.** macOS updates and
flake input bumps are deliberately left to a human, and undeclared software is
never touched by design.

## Commands

```bash
./scripts/rebuild.sh                       # build → plan → one auth → activate
./scripts/rebuild.sh --plan-only           # what would change; no build, no root
./scripts/rebuild.sh --build-only          # validate the config compiles
./scripts/rebuild.sh --yes                 # skip the confirm prompt
./scripts/rebuild.sh --yes --upgrade-mas   # ...and still do App Store upgrades
./scripts/weekly-update.sh --dry-run       # what the Monday job would do
nup                                        # update flake inputs (own PR + review)
```

`--plan-only` is the fast "what's pending?" check. It needs no root and upgrades
nothing, but it is **not read-only** — it runs `brew update`, which touches the
network and Homebrew's local metadata.

## One authentication per rebuild

`rebuild.sh` used to trigger a Touch ID prompt for every root-requiring cask,
each with no indication of what it was for. Those prompts came from *inside*
`darwin-rebuild switch`: nix-darwin drops root back to the primary user to run
`brew bundle` (brew refuses to run as root), so every cask needing root
re-invoked `sudo` as the user, and macOS's default tty-scoped sudo timestamps
meant each one authenticated separately.

`modules/darwin/sudo-rebuild.nix` sets `timestamp_type=global` scoped to the
primary user, so one authentication covers brew's children too. `rebuild.sh`
authenticates once **after** printing the plan, refreshes the timestamp for the
duration of the run, and revokes it with `sudo -k` on exit.

**The tradeoff, stated plainly:** while that window is open, any process running
as you can call `sudo` without a prompt — including third-party formula and cask
install scripts the rebuild downloads and executes. Weighed against the previous
behaviour, those scripts already received root via prompts too unattributable to
evaluate, so they were approved reflexively. This trades many unattributable taps
for one tap shown after an explicit plan. It is scoped to the primary user and to
the `workstation-mac` role; `personal-mac` hosts are unaffected.

`Defaults` and `timestamp_timeout` are left at macOS's 5-minute default — the
keep-alive refreshes inside it, so a longer timeout would only widen exposure
after the run ends.

## Why each thing lives where it does

The placement of every update step follows one rule: **anything that can invoke
`sudo` must not run unattended.**

- **Formulae → weekly agent.** They install under the user-owned Homebrew
  prefix. This removes the expected privileged path. It is a risk reduction, not
  a hard boundary: formula post-install code still runs as you and could invoke
  sudo. A real boundary would need a separate non-admin identity.
- **Casks → `rebuild.sh` only.** Cask installers routinely need root. Unattended,
  overlapping a rebuild's open sudo window, one could escalate silently. The
  weekly job *reports and prefetches* outdated casks instead, so the interactive
  run that installs them is quick.
- **App Store apps → `rebuild.sh`, after activation.** `mas_install` in
  postActivation only installs apps that are **missing** — it never upgrades —
  so declared App Store apps were installed once and never updated again. The
  obvious fix (adding `mas upgrade` to the weekly agent) is wrong: mas 7.0.0
  spawns `/usr/bin/sudo` internally for update operations. Both `/usr/bin/sudo`
  and `Requires root privileges to install apps` are embedded in the installed
  binary. One app upgrading without a prompt does not disprove the capability.
- **`--yes` skips App Store upgrades** unless `--upgrade-mas` is passed. `--yes`
  exists to remove the human, and "a human is present" is the entire
  justification for doing MAS upgrades there — so the script enforces it rather
  than asserting it in a comment.

## Declared vs installed

`brew outdated` lists everything installed. `brew bundle` only manages what the
Brewfile **declares**. Conflating the two made the rebuild preview promise
upgrades that activation never performed.

Both scripts now intersect against the flake's declared set
(`scripts/lib/declared-packages.sh`) and report the remainder as drift.

Two refinements worth keeping:

- **Dependencies are not drift.** `bash` exists only because the declared
  `direnv` depends on it. Declaring a transitive dependency is wrong, so
  reporting it was a warning that could never be acted on. Drift is narrowed via
  `brew list --installed-on-request` — *not* `brew leaves`, which means "nothing
  depends on it" and would silently drop a formula you asked for that later
  became someone's dependency.
- **Homebrew still resolves dependencies.** Only the *selection* of upgrade
  targets is restricted; upgrading a declared formula may still upgrade an
  undeclared one it requires.

### Errors are not emptiness

The recurring bug in this code has been encoding failure as an empty result: a
failed `nix eval` or `brew outdated` returning nothing, which callers read as
"nothing is declared" or "nothing is outdated" — then skip real work and exit 0
looking successful.

Every inventory and evaluation step is therefore status-checked independently,
and a failure to determine state is reported as its own outcome rather than
folded into "nothing to do". Where a filter cannot be computed, drift is reported
**unfiltered** — over-reporting is the safe direction.

`scripts/tests/declared-packages.test.sh` guards this contract, including the
case where `jq -e` would report a host with no casks as a failure.

## Expected drift

`audit-config-drift.sh` reports the **`tripmode` cask** as installed-but-not-
declared on `rouven-m5-pro`. This is expected and must not be "fixed" by
declaring it — see the trap below.

## Traps

**Two unrelated apps named Session.** The `session` Homebrew cask is an
onion-routing messenger (`com.loki-project.messenger-desktop`). The Session that
is wanted is *Session Pomodoro Focus Timer* (MAS `1521432881`,
`com.philipyoungg.session`), declared in `productivity.nix`. Different vendors;
they install to different paths and coexist. The messenger has been removed and
recorded in `archive.nix`.

**TripMode ships as two different builds.** They coexist because the bundle ids
and paths differ:

```
cask  ch.tripmode.TripMode     /Applications/TripMode.app
MAS   com.alix-sarl.TripMode   /Applications/TripMode.localized/TripMode.app
```

The cask **must not be declared**: its installer raises a system-extension
approval dialog that `brew bundle` cannot answer under sudo, so activation hangs
on any host that does not already have it. TripMode is provisioned from the App
Store instead. On `rouven-m5-pro` the manually-installed cask is the build
actually in use — it owns the activated network `FilterExtension` — which is why
the drift entry above is permanent and correct.

**`mas list` shows locally installed, receipt-bearing apps**, not everything the
account owns. If it lists an app whose bundle has no `_MASReceipt`, look for a
second copy before concluding anything.

## Coverage limits

- The weekly LaunchAgent runs only while you are logged in. Asleep at 10:00 → it
  runs on wake; the Mac off all Monday → that week is skipped.
  `StartCalendarInterval` does not backfill.
- Exit codes: `0` fine · `1` could not determine state · `2` an upgrade failed.
  Logs: `~/.local/state/dotfiles/weekly-update/` (last 12 retained).
- The agent runs the script from the mutable `~/dotfiles` checkout — the same
  convention `fleet-audit.nix` documents — so a dirty or ahead-of-activation
  checkout can select a different set than the running system declares. Accepted
  architectural risk, not an oversight.
