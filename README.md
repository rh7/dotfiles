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

## Daily Usage

```bash
./scripts/rebuild.sh   # safe rebuild: pull → audit drift → build → preview diff → confirm → switch
nrs                    # raw alias: sudo darwin-rebuild switch --flake ~/dotfiles#$(hostname)
nup                    # update flake inputs
dots                   # open dotfiles in Zed
```

**Prefer `rebuild.sh`** — it pulls latest, runs the drift audit (advisory; only
prompts when risky `+` drift is detected), shows an `nvd` diff of the package
closure, and asks for confirmation before activation. `nrs` skips all of that
and switches directly.

Every `rebuild.sh` run is mirrored to a logfile at
`~/.local/state/dotfiles/rebuild/<host>-<timestamp>.log` (last 20 per host
retained; override the directory with `REBUILD_LOG_DIR`). Useful when
`brew bundle` or activation fails deep in the output — `less -R <log>` or
`grep -i fail <log>` to find what broke. The path is printed at the end of
every run.

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
