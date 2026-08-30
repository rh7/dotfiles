# Rouven's Dotfiles

Declarative multi-device setup using **nix-darwin** + **Home Manager** + **NixOS** + **Flakes**.

Role-based module composition — each machine is a thin config that selects a role and optional extras.

## Machines

| Config | Machine | Role | Extras |
|--------|---------|------|--------|
| `m5-air` | MacBook Air M5 | workstation | — |
| `rouven-air-m3` | MacBook Air M3 | workstation | — |
| `rouven-pro-m4` | MacBook Pro M4 | workstation | — |
| `rouvens-mac-mini` | Mac Mini M4 | workstation | smart-home |
| `rouvens-mac-studio` | Mac Studio M3 Ultra | workstation | ai-inference |
| `nixos-vm` | UTM VM | workstation (linux) | — |
| `thinkpad` | ThinkPad x86 | workstation (linux) | — |
| `linux` | OrbStack VM | standalone Home Manager | — |

## Quick Start (new Mac)

```bash
# 1. Install Nix (Determinate)
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install

# 2. Clone this repo
git clone https://github.com/rh7/dotfiles.git ~/dotfiles

# 3. Apply (replace MACHINE with your config name)
cd ~/dotfiles
sudo darwin-rebuild switch --flake .#MACHINE
```

Or use the bootstrap script: `bash bootstrap.sh`

## Making Changes

This repo drives a fleet of Macs, so changes go through review rather than
straight to `main`:

```
branch → commit → PR → external review → squash-merge → ./scripts/rebuild.sh
```

**Every non-trivial change gets an external code review before merging** — a
second model reading the diff, asked for a merge verdict. A blocking verdict
blocks the merge; fix and re-review until it approves. Several rounds on one PR
is normal.

This is not ceremony. In the session that produced
[Software Updates](docs/software-updates.md), review blocked the merge eight
times across four PRs and every finding was real — including bugs introduced
while fixing earlier bugs, a security claim overstated from a single
observation, and a flag that silently invalidated the premise a whole design
rested on.

Two rules that make it work:

- **Verify findings against the code rather than accepting them.** Some are
  wrong. A finding that contradicts a deliberate repo convention should be
  recorded as an accepted risk, not silently "fixed".
- **Don't trust your own "verified" either** — check what the evidence actually
  covers. One App Store app upgrading without a sudo prompt does not prove
  `mas` cannot escalate; the binary embeds `/usr/bin/sudo`.

Prefer empirical proof over description: fault-inject (a fake `nix`, `brew` or
`mas` on `PATH` that fails one specific query) and assert exit codes, rather
than asserting a failure path works. `scripts/tests/` holds the fixtures.

Skip review only for genuinely trivial edits — a typo, a comment, one line in a
package list — and say so.

## Daily Usage

```bash
nrs                               # rebuild: pull → audit drift → build → preview diff → confirm → switch
nrs-raw                           # escape hatch: sudo darwin-rebuild switch --flake ~/dotfiles#$(hostname)
./scripts/rebuild.sh --plan-only  # what's pending? no build, no activation, no root
nup                               # update flake inputs
dots                              # open dotfiles in Zed
```

`nrs` is `./scripts/rebuild.sh` (`nrsg` still works as an older name for it).
It pulls latest, runs the drift audit (advisory; only prompts when risky `+`
drift is detected), shows an `nvd` diff of the package closure, and asks for
confirmation before activation. It also holds a single sudo authentication open
for the whole run, so `brew bundle`'s root-requiring casks reuse it rather than
re-prompting once per cask — see `modules/darwin/sudo-rebuild.nix`.

**`nrs-raw` skips all of that** and switches directly. Reach for it only when
`rebuild.sh` is itself the thing that is broken.

Every `rebuild.sh` run is mirrored to a logfile at
`~/.local/state/dotfiles/rebuild/<host>-<timestamp>.log` (last 20 per host
retained; override the directory with `REBUILD_LOG_DIR`). Useful when
`brew bundle` or activation fails deep in the output — `less -R <log>` or
`grep -i fail <log>` to find what broke. The path is printed at the end of
every run.

A rebuild asks for **one** Touch ID, after showing what it will upgrade. A
weekly LaunchAgent keeps declared Homebrew formulae current on its own. Neither
covers macOS system updates or `flake.lock` — those stay manual, on purpose.
See **[Software Updates](docs/software-updates.md)** for the full model, the
sudo tradeoff it rests on, and the app-naming traps that have bitten this repo
(there are two unrelated apps called Session, and two different TripMode
builds).

## Structure

```
flake.nix                              # Device registry — all machines defined here
bootstrap.sh                           # Interactive new-Mac setup

modules/
  common.nix                           # CLI tools + git (Home Manager, all platforms)
  shell/zsh.nix                        # Zsh, starship, aliases, mackup

  darwin/
    defaults.nix                       # macOS system defaults (dock, finder, keyboard)
    homebrew.nix                       # Homebrew scaffold (behavior config only)
    profiles/                          # Composable app sets (Homebrew casks/brews)
      core.nix                         #   1password, chrome, arc, raycast, tailscale
      dev-apps.nix                     #   cursor, ghostty, zed, orbstack, wezterm
      communication.nix                #   telegram, signal, discord, whatsapp, proton-mail, canary mail
      productivity.nix                 #   notion, linear, superhuman, granola
      ai-tools.nix                     #   claude, chatgpt, ollama, superwhisper
      media.nix                        #   spotify, pocketcasts, vlc
      security.nix                     #   expressvpn, PIA, tripmode

  home/profiles/                       # Cross-platform Home Manager profiles
    development.nix                    #   nodejs, python, rust, git-lfs, pre-commit
    editor.nix                         #   Zed editor config (shared across all machines)
    docker.nix                         #   docker-compose (Linux only)

  nixos/
    system.nix                         # NixOS system base (boot, networking, users, cron)
    desktop.nix                        # GNOME desktop, fonts, core apps
    profiles/                          # NixOS app profiles
      communication.nix                #   telegram, slack, signal, discord, zoom
      dev-apps.nix                     #   wezterm, ghostty, zed
      media.nix                        #   spotify, vlc
      productivity.nix                 #   obsidian, notion

  roles/                               # Composable role bundles
    workstation-mac.nix                #   imports all darwin profiles
    workstation-linux.nix              #   imports desktop + all nixos profiles
    ai-inference.nix                   #   lm-studio (Mac Studio)
    smart-home.nix                     #   sensibo, sonos, homey (Mac Mini)
    personal-mac.nix                   #   lighter setup for non-developers

configurations/
  macos/
    home.nix                           # macOS user config (imports dev + editor profiles)
    macbook.nix                        # MacBook-specific overrides
    mac-mini-office.nix                # Mac Mini overrides
    mac-studio.nix                     # Mac Studio overrides
  nixos/
    home.nix                           # NixOS user config (imports dev + editor + docker + Search Light)
    vm.nix                             # UTM VM hardware
    thinkpad.nix                       # ThinkPad hardware + power mgmt
  linux/
    home.nix                           # Standalone Home Manager (OrbStack/servers)

mackup/
  .mackup.cfg                          # Settings sync config (iCloud)
```

## Adding Software

| What | Where |
|------|-------|
| CLI tool (all machines) | `modules/common.nix` |
| macOS GUI app (all Macs) | Add to the appropriate `modules/darwin/profiles/*.nix` |
| macOS GUI app (Mac App Store only) | Find the ID with `mas search "Name"`, then add `mas_install <ID> "Name"` to the matching profile's `system.activationScripts.postActivation.text` (helper defined in `modules/darwin/mas.nix`) |
| macOS GUI app (one machine) | Add to that machine's `configurations/macos/*.nix` |
| NixOS GUI app | Add to `modules/nixos/profiles/*.nix` |
| Dev tool (all platforms) | `modules/home/profiles/development.nix` |
| New role bundle | Create `modules/roles/your-role.nix`, import profiles |
| New machine | Add entry in `flake.nix` with hostname, role, and extras |
| PWA / web app (all Macs) | Add to [`pwas.txt`](pwas.txt), then `scripts/pwa-apps.sh build --pin` (see [Web Apps](#web-apps-pwas)) |

Nix provides the shared Node runtime via Home Manager. Mutable npm-installed
CLIs use the user-owned `~/.npm-global` prefix rather than `/nix/store`. Native
user installers, including Claude Code, place commands in `~/.local/bin`.
The development profile adds both directories to `PATH`; keep both entries when
changing shell or Home Manager configuration.

## Web Apps (PWAs)

PWAs are declared once in [`pwas.txt`](pwas.txt) and regenerated as real `.app`
launchers on any Mac by [`scripts/pwa-apps.sh`](scripts/pwa-apps.sh) — the
reproducible alternative to Safari's GUI-only *Add to Dock*, whose OS-registered
web apps don't survive Migration Assistant (that's what leaves `?` placeholders in
the Dock on a new machine).

```bash
# pwas.txt — one PWA per line:  Name | https://url | optional/icon.icns
scripts/pwa-apps.sh build --pin          # build every declared PWA + pin to the Dock
scripts/pwa-apps.sh build --engine stub  # zero-toolchain variant (see below)
scripts/pwa-apps.sh list                 # show declared PWAs
scripts/pwa-apps.sh doctor               # check toolchain (pake / rust / dockutil)
```

Two engines, both reproducible from the same manifest:

| Engine | What you get | Cost |
|--------|--------------|------|
| **pake** (default) | native Tauri app — own process, native notifications; fresh login per app | needs Rust + `pake-cli`; slow first build (~min) |
| **stub** | `.app` that opens the URL in a browser `--app` window; reuses your logged-in profile | zero toolchain, instant |

**Fresh Mac:** run `rustup default stable` once (Rust toolchain), then
`scripts/pwa-apps.sh build --pin`. The script auto-installs `pake-cli` into
`~/.npm-global` — self-healing the Nix read-only-npm-prefix `EACCES` — and builds
every PWA. `brew install dockutil` is only needed for `--pin` (Dock pinning);
without it the apps still build, just unpinned. First launch asks you to sign in
once per app (each native app has its own cookie jar).

## Device Management

See **[docs/device-guide.md](docs/device-guide.md)** for the full guide, including:
- Setting up a **brand new** device (one command)
- Onboarding an **existing** device (audit first, then deploy)
- Comparing devices and finding gaps
- Config service API reference

### Quick Reference

```bash
./scripts/device setup             # new device: backup → rebuild → secrets → register
./scripts/device audit             # existing device: collect inventory first
./scripts/device update            # daily: pull → rebuild
./scripts/device status            # fleet overview
./scripts/device heartbeat --install  # install 5-min monitoring cron
```

### Config drift audit

`scripts/audit-config-drift.sh` compares actual machine state to the declared
nix-darwin config — catches manually-installed apps, dock changes, MAS apps,
and macOS defaults that have drifted from the flake.

**Runs automatically** as Step 2 of `./scripts/rebuild.sh`, so you don't
normally need to invoke it directly. Standalone usage:

```bash
./scripts/audit-config-drift.sh              # audit current host vs declared config
./scripts/audit-config-drift.sh Kassie-M5-Air13  # audit a specific host
./scripts/audit-config-drift.sh --snapshot   # save baseline of all defaults
./scripts/audit-config-drift.sh --diff       # diff current state vs baseline
```

The audit distinguishes two kinds of drift:

- **`+` (risky)** — present locally but not declared. `switch` will overwrite
  these (manual dock pins, brew-installed-but-not-declared apps, MAS apps the
  flake doesn't know about). Fold them into the flake first if you want them
  to survive future rebuilds.
- **`-` (benign)** — declared but not yet present locally. `switch` will just
  apply them — no manual changes at risk.

`rebuild.sh` only prompts when risky drift is detected; benign drift proceeds
silently.

One drift entry is **expected and permanent**: the `tripmode` cask shows as
installed-but-not-declared on `rouven-m5-pro`. Declaring it would hang
activation on every other Mac — see
[Software Updates → Traps](docs/software-updates.md#traps). Homebrew formulae
installed as *dependencies* (e.g. `bash` for `direnv`) are not reported as
drift; they are not yours to declare.

The `--snapshot` / `--diff` pair captures things the audit can't enumerate up
front (mouse speed, custom keyboard shortcuts, hidden defaults). Useful when
handing a device to someone else: snapshot before, diff after to fold their
changes back into the flake.

## Settings Sync

**mackup** syncs app preferences via iCloud.

```bash
mackup backup    # on source machine
mackup restore   # on new machine
```

## Related

- [`rh7/rh-device-management`](https://github.com/rh7/rh-device-management) — Private config service, agent registry, fleet orchestration
- [`rhclaw/catalog-agent`](https://github.com/rhclaw/catalog-agent) — Lightweight service discovery agent
- [Device Management Guide](docs/device-guide.md) — Full onboarding and audit workflow
