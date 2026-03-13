# Rouven's Dotfiles

Declarative multi-Mac setup using **nix-darwin** + **Home Manager** + **Flakes**.

## Machines

| Config | Machine | Role |
|--------|---------|------|
| `m5-air` | MacBook Air M5 | Daily driver |
| `rouven-air-m3` | MacBook Air M3 | Laptop |
| `rouven-pro-m4` | MacBook Pro M4 | Laptop |
| `rouvens-mac-mini` | Mac Mini M4 | Office desktop + smart home |
| `rouvens-mac-studio` | Mac Studio M3 Ultra | AI inference lab |
| `linux` | OrbStack VM | Dev environment |

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

## Daily Usage

```bash
nrs          # alias: rebuild from ~/dotfiles
nup          # alias: update flake inputs
dots         # alias: open dotfiles in Zed
```

## Structure

```
flake.nix                          # Entry point - all machines defined
modules/
  common.nix                       # CLI tools + git (Home Manager)
  shell/zsh.nix                    # Zsh, starship, aliases, mackup
  darwin/
    defaults.nix                   # macOS system defaults
    homebrew.nix                   # Declarative Homebrew casks + brews
configurations/
  macos/
    home.nix                       # Dev toolchains (node, python, rust)
    macbook.nix                    # MacBook-specific apps
    mac-mini-office.nix            # Smart home apps
    mac-studio.nix                 # AI lab (ollama, lm-studio)
  linux/
    home.nix                       # OrbStack VM config
mackup/
  .mackup.cfg                      # Settings sync config (iCloud)
```

## Settings Sync

**mackup** syncs app preferences via iCloud.

```bash
mackup backup    # on source machine
mackup restore   # on new machine
```

## Adding an App

- **CLI tool**: add to `modules/common.nix`
- **GUI app (all machines)**: add to `modules/darwin/homebrew.nix`
- **GUI app (specific machine)**: add to machine config in `configurations/macos/`
- **Dev tool**: add to `configurations/macos/home.nix`
