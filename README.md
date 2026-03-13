# dotfiles

Declarative Mac + Linux configuration using [Nix flakes](https://wiki.nixos.org/wiki/Flakes), [nix-darwin](https://github.com/LnL7/nix-darwin), and [home-manager](https://github.com/nix-community/home-manager).

## Machines

| Hostname | Machine | Role |
|---|---|---|
| `m5-air` | MacBook Air M5 | Daily driver |
| `rouven-air-m3` | MacBook Air M3 | Mobile |
| `rouven-pro-m4` | MacBook Pro M4 | Mobile |
| `rouvens-mac-mini` | Mac Mini M4 | Office desktop |
| `rouvens-mac-studio` | Mac Studio M3 Ultra | AI inference lab |
| `linux` | OrbStack NixOS VM | Dev services |
| `jetson` | Jetson AGX Orin | Edge inference |
| `contabo` | Contabo VPS | Server |

## Fresh Mac Setup

```bash
# One command — works on any machine listed above
bash <(curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/bootstrap.sh)

# After iCloud syncs
mackup restore
```

## Apply Config Changes

```bash
darwin-rebuild switch --flake ~/dotfiles   # full form
nrs                                         # alias (after first setup)
```

## Settings Sync Strategy

| What | How |
|---|---|
| macOS defaults, dock, keyboard | nix-darwin (`nrs`) |
| CLI tools, dev toolchains | Nix / Home Manager (`nrs`) |
| Shell, git, SSH config | Home Manager (`nrs`) |
| App preferences (Cursor, Zed, Slack...) | mackup → iCloud |
| SSH keys | 1Password SSH Agent |
| Cursor settings | Cursor built-in sync (GitHub) |
| Obsidian vault | iCloud / Dropbox |
| Arc bookmarks/spaces | Arc account sync |
| Secrets / env vars | 1Password CLI (`op run`) |

## Structure

```
.
├── bootstrap.sh                    # Fresh Mac setup script
├── flake.nix                       # Entry point: all machines defined here
├── flake.lock                      # Pinned dependency versions
├── configurations/
│   ├── macos/
│   │   ├── home.nix                # Shared macOS user config + toolchains
│   │   ├── macbook.nix             # MacBook-specific apps
│   │   ├── mac-mini-office.nix     # Office Mac Mini (smart home, Office)
│   │   └── mac-studio.nix         # AI lab (Ollama native service)
│   └── linux/
│       └── home.nix                # Linux user config (OrbStack / Jetson / VPS)
└── modules/
    ├── common.nix                  # CLI tools + git (all machines)
    ├── shell/
    │   └── zsh.nix                 # zsh, starship, aliases, SSH, mackup
    ├── darwin/
    │   ├── defaults.nix            # macOS system defaults
    │   └── homebrew.nix            # Declarative cask management
    ├── editors/
    │   └── vim.nix                 # Neovim
    └── dev-tools/
        └── docker.nix              # Docker tools (Linux)
```

## Adding a New App

```nix
# modules/darwin/homebrew.nix  → all machines
casks = [ ... "new-app" ];

# configurations/macos/macbook.nix  → MacBooks only
homebrew.casks = [ ... "new-app" ];
```

Then: `nrs`

## Manual Exceptions

These cannot be automated (licensing or no cask available):
- **Adobe Creative Cloud** — license-managed, install manually
- **IBKR Desktop** — download from ibkr.com
- **StarMoney / Finanzguru / Bank X** — German banking apps, no casks
- **Mac App Store apps** — use `mas install <id>` or install manually

## Update Dependencies

```bash
nix flake update ~/dotfiles   # nfu alias
nrs                            # apply updated inputs
```

## Garbage Collection

Auto-runs weekly (Sunday 3am, keeps 30 days of generations).
Manual: `ngc`

## Linux / OrbStack VM

```bash
# Apply on Linux
nix run home-manager -- switch --flake .#linux -b backup
```
