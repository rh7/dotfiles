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
nrs          # rebuild from ~/dotfiles using $(hostname)
nup          # update flake inputs
dots         # open dotfiles in Zed
```

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
      communication.nix                #   slack, discord, telegram, signal, zoom
      productivity.nix                 #   notion, linear, superhuman, granola
      ai-tools.nix                     #   claude, chatgpt, ollama, superwhisper
      media.nix                        #   spotify, pocketcasts, vlc
      security.nix                     #   expressvpn, PIA, tripmode

  home/profiles/                       # Cross-platform Home Manager profiles
    development.nix                    #   nodejs, python, rust, git-lfs, pre-commit
    editor.nix                         #   Zed editor config (shared across all machines)
    docker.nix                         #   docker-compose (Linux only)

  nixos/
    system.nix                         # NixOS system base (boot, networking, users)
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
    home.nix                           # NixOS user config (imports dev + editor + docker)
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
| macOS GUI app (one machine) | Add to that machine's `configurations/macos/*.nix` |
| NixOS GUI app | Add to `modules/nixos/profiles/*.nix` |
| Dev tool (all platforms) | `modules/home/profiles/development.nix` |
| New role bundle | Create `modules/roles/your-role.nix`, import profiles |
| New machine | Add entry in `flake.nix` with hostname, role, and extras |

## Settings Sync

**mackup** syncs app preferences via iCloud.

```bash
mackup backup    # on source machine
mackup restore   # on new machine
```

## Related

- [`rh7/rh-device-management`](https://github.com/rh7/rh-device-management) — Private config service, agent registry, fleet orchestration
- [`rhclaw/catalog-agent`](https://github.com/rhclaw/catalog-agent) — Lightweight service discovery agent
