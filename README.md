# Rouven's Dotfiles

Declarative multi-device setup using **nix-darwin** + **Home Manager** + **NixOS** + **Flakes**.

Role-based module composition — each machine is a thin config that selects a role and optional extras.

## Machines

`flake.nix` is the source of truth; this table mirrors it. Every `mkMac` host
gets sops-nix secrets (`needsSecrets = true`) unless marked otherwise.

| Config | Machine | Role | Extras |
|--------|---------|------|--------|
| `m5-air` | MacBook Air M5 | workstation | `macbook.nix` |
| `rouven-m5-pro` | MacBook Pro M5 (user `rouven`) | workstation | `macbook.nix`, `weekly-update.nix` (staged) |
| `rouven-air-m2` | MacBook Air M2 | workstation | `macbook.nix` |
| `rouven-air-m3` | MacBook Air M3 | workstation | `macbook.nix` |
| `rouven-pro-m4` | MacBook Pro M4 | workstation | `macbook.nix` |
| `rouvens-mac-mini` → `rouvens-mac-mini-m4` | Mac mini M4 (office) | workstation | `mac-mini-office.nix`, smart-home |
| `rouvens-mac-studio` | Mac Studio | fleet-member (nix owns toolchain, secrets, audit schedule, macOS `defaults.nix`, Lima; Homebrew, apps and Dock layout are imperative) | `mac-studio.nix`, `fleet-audit.nix` |
| `Kassie-M5-Air13` | MacBook Air M5 (user `kassie`) | personal | `macbook.nix`; `needsSecrets = false` |
| `nixos-vm` | UTM VM (aarch64) | workstation-linux (NixOS) | `vm.nix` |
| `thinkpad` | ThinkPad (x86_64) | workstation-linux (NixOS) | `thinkpad.nix`, `home-assistant.nix` |
| `linux`, `linux-rouven`, `linux-x86` | OrbStack VM / servers | standalone Home Manager | — |
| `omarchy` | Omarchy 4 guest (Arch ARM in UTM) | standalone Home Manager (CLI only) | `omarchy.nix` |

The Mac mini's attr and hostname become `rouvens-mac-mini-m4` (the live
machine's name) with `chore/326-315-flake-hygiene`; until that merges the flake
attr is `rouvens-mac-mini`. The same PR imports `fleet-audit.nix` for every
`mkMac` host — on `main` today only the Studio imports it.

## Quick Start (new Mac)

The fleet standard is the **official Nix installer**
(`sh <(curl -L https://nixos.org/nix/install) --daemon`), not Determinate.
`scripts/setup.sh` installs it for you. On macOS it must run from a **GUI
session** (Terminal.app locally or via Screen Sharing — not SSH): headless-only
Macs block the `/etc/fstab` write the Nix APFS volume needs.

```bash
# Interactive: Xcode CLI → hostname → official Nix → dotfiles build →
# 1Password → gh auth → Tailscale → fleet registration → daily audit schedule
curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/setup.sh | bash

# or, from a clone
git clone https://github.com/rh7/dotfiles.git ~/dotfiles && ~/dotfiles/scripts/setup.sh
```

Pick the hostname that matches a `flake.nix` attr — the rebuild selects the
configuration by hostname. **Secrets hosts** (`needsSecrets = true`, every Mac
except `Kassie-M5-Air13`) cannot decrypt on first activation until the new age
key is a recipient. Until `fix/310-sops-onboarding` merges, `setup.sh` does not
stop for this: it activates anyway, treats the failure as non-fatal and still
prints *Setup Complete* — do the manual recipient step in
[Secrets](docs/device-guide.md#secrets-sops-nix) and rebuild before trusting
the machine. Migrating a Mac that already has apps and settings? Read
[Before migrating an existing Mac](docs/device-guide.md#before-migrating-an-existing-mac)
first.

The repo-root `bootstrap.sh` is legacy: it still installs **Determinate** Nix.
Don't use it for fleet Macs.

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
nrs                               # rebuild: sync checkout → audit drift → build → preview diff → confirm → switch
nrs-raw                           # escape hatch: sudo darwin-rebuild switch --flake ~/dotfiles#$(hostname)
./scripts/rebuild.sh --plan-only  # what's pending? no build, no activation, no root
nix flake update --flake ~/dotfiles   # update flake inputs (the `nup` alias omits --flake and is a no-op on current Nix)
dots                              # open dotfiles in Zed
```

### Lean OMP coordinator

`omp-coordinator` starts the coordinator role in `~/repo-management` with the
normal OMP profile, auth, model roles, Mnemopi backend, tools, rules, and skills.
Its one process-only overlay replaces `workspace.additionalDirectories` with an
empty list; it does not edit `~/.omp/agent`, select an isolated OMP profile, or
disable skill discovery. Home Manager installs the tracked launcher and overlay.

```bash
omp-coordinator                                  # repo-management only
omp-coordinator --add-dir "$HOME/server-platform" # add the active sibling at launch

# Or add it after launch, before reading or writing that repository:
/add-dir ~/server-platform
```

If repo-management is cloned elsewhere, set `OMP_COORDINATOR_ROOT` to its
absolute path. All other OMP arguments pass through unchanged.

Startup A/B on 2026-09-01 used OMP 18.0.11,
`openai-codex/gpt-5.6-sol:high`, and its 272,000-token window:

| Launch | First-turn input | Window |
|--------|-----------------:|-------:|
| Normal coordinator with seven global sibling roots | 72,450 | 26.64% |
| Lean coordinator, fresh `--no-session` process | 38,682 | 14.22% |

A separate fresh process with `--add-dir "$HOME/server-platform"` read that
sibling's Linux-server scope boundary before any tool call.

The lean probe resolved `workspace.additionalDirectories` to `[]`, retained the
`Portfolio agent guide` repo-management instructions and Mnemopi, and used this
worktree-local invocation (no install or live config mutation):

```bash
OMP_COORDINATOR_CONFIG="$PWD/modules/home/profiles/omp-coordinator.yml" \
OMP_COORDINATOR_ROOT="$HOME/repo-management" \
./scripts/omp-coordinator -p --no-session --mode json --max-time 3m \
  'Do not use tools. From startup instructions only, output exactly: REPO_HEADING=<the H1 heading of the current repository instructions>; ROOTS=<comma-separated additional workspace roots, or none>.'
```

`nrs` is `./scripts/rebuild.sh` (`nrsg` still works as an older name for it).
It runs the drift audit (advisory; only prompts when risky `+` drift is
detected), shows an `nvd` diff of the package closure, and asks for
confirmation before activation. It also holds a single sudo authentication open
for the whole run, so `brew bundle`'s root-requiring casks reuse it rather than
re-prompting once per cask — see `modules/darwin/sudo-rebuild.nix`.

**Only merged config gets activated.** With `fix/312-rebuild-merged-only`,
`rebuild.sh` fetches and refuses to activate unless `~/dotfiles` is on `main`,
has a clean tracked tree, and `HEAD == origin/main` — so a machine can no longer
be built from a stale or half-edited checkout while every audit reports it
compliant. To test a branch on one machine deliberately, pass
`--allow-unmerged` (it warns loudly). Before that PR merges, `rebuild.sh` only
runs `git pull --ff-only` on a clean tree and builds whatever is checked out.

**`nrs-raw` skips all of that** and switches directly. Reach for it only when
`rebuild.sh` is itself the thing that is broken.

Every `rebuild.sh` run is mirrored to a logfile at
`~/.local/state/dotfiles/rebuild/<host>-<timestamp>.log` (last 20 per host
retained; override the directory with `REBUILD_LOG_DIR`). Useful when
`brew bundle` or activation fails deep in the output — `less -R <log>` or
`grep -i fail <log>` to find what broke. The path is printed at the end of
every run.

A rebuild asks for **one** Touch ID, after showing what it will upgrade — by
default only a curated critical list (browsers, passwords, VPN, messengers);
`--upgrade=all` for everything, `--no-upgrade` for nothing. On
`rouven-m5-pro` only (staged in `flake.nix`), a weekly LaunchAgent
(`weekly-update.nix`) keeps declared Homebrew formulae current on its own.
Neither covers macOS system updates or `flake.lock` — those stay manual, on
purpose.
See **[Software Updates](docs/software-updates.md)** for the full model, the
sudo tradeoff it rests on, and the app-naming traps that have bitten this repo
(there are two unrelated apps called Session, and two different TripMode
builds).

## Structure

```
flake.nix                              # Device registry — all machines defined here
bootstrap.sh                           # Legacy new-Mac setup (installs Determinate Nix) — use scripts/setup.sh

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
    fleet-audit.nix                    #   daily collector-runner schedule (launchd / systemd timer)

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
    fleet-member-mac.nix               #   Mac Studio: toolchain + secrets + audit (+ defaults.nix via mkMac); Homebrew disabled
    ai-inference.nix                   #   lm-studio (not imported by any host today)
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
- Setting up a **brand new** device (`scripts/setup.sh`)
- **Before migrating an existing Mac** — the checklist
- Onboarding an **existing** device (audit first, then rebuild)
- Secrets onboarding (age key → `sops-add-host.sh` on an existing recipient)
- Config service API reference

### Quick Reference

```bash
./scripts/device audit             # interactive audit menu; --local / --save / --run
./scripts/device status            # this device + fleet overview
./scripts/rebuild.sh               # rebuild (= nrs)
./scripts/device secrets           # setup-secrets.sh — only after fix/310-sops-onboarding merges
./scripts/collector-runner.sh --install   # daily audit on any host without com.rh7.collector-runner
curl -fsSL https://config.rh7labs.com/enroll | bash   # enrol a device without a dotfiles clone
```

Connectivity comes from the **daily audit**, not a heartbeat. Hosts that import
`fleet-audit.nix` get it declaratively (LaunchAgent `com.rh7.collector-runner`,
the integrity-gated pull runner) — on `main` only the Studio; with
`chore/326-315-flake-hygiene` every `mkMac` host. Everything else (other Macs
until then, NixOS, standalone Home Manager) needs `collector-runner.sh
--install` once. The `enroll` short link runs a first audit and installs a
direct daily audit (`com.rh7.audit` LaunchAgent / cron) for devices without a
clone.

One legacy heartbeat path survives: the `device sync --install` cron runs
`heartbeat.sh` every 30 minutes, which posts role `workstation`. Remove it with
`./scripts/device sync --uninstall` wherever it is installed (`crontab -l |
grep auto-sync`).

### Config drift audit

`scripts/audit-config-drift.sh` compares actual machine state to the declared
nix-darwin config — catches manually-installed casks/apps, dock changes, MAS
apps, and macOS defaults that have drifted from the flake. It does **not** check
Homebrew formulae yet (dotfiles#11), which is why `homebrew.onActivation.cleanup`
stays `"none"` until it does.

**Runs automatically** as Step 2 of `./scripts/rebuild.sh`, so you don't
normally need to invoke it directly. Standalone usage:

```bash
./scripts/audit-config-drift.sh              # audit current host vs declared config
./scripts/audit-config-drift.sh Kassie-M5-Air13  # audit a specific host
./scripts/audit-config-drift.sh --snapshot   # save baseline of all defaults
./scripts/audit-config-drift.sh --diff       # diff current state vs baseline
```

The audit distinguishes three kinds of drift:

- **`+` (risky)** — local state `switch` will overwrite (e.g. manual Dock pins,
  changed defaults). Fold it into the flake first if you want it to survive
  future rebuilds.
- **`-` (benign)** — declared but not yet present locally. `switch` will just
  apply them — no manual changes at risk.
- **`·` (informational)** — installed but not declared (casks, MAS apps,
  unmanaged `/Applications` entries). With `cleanup = "none"` activation keeps
  them; review them when adopting apps into the flake.

`rebuild.sh` only prompts when risky drift is detected; benign and
informational drift proceed silently.

One drift entry is **expected and permanent**: the `tripmode` cask shows as
installed-but-not-declared on `rouven-m5-pro`. Declaring it would hang
activation on every other Mac — see
[Software Updates → Traps](docs/software-updates.md#traps).

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
