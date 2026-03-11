# dotfiles

Declarative home configuration using [Nix flakes](https://wiki.nixos.org/wiki/Flakes) and [home-manager](https://github.com/nix-community/home-manager).

## What's included

| Module | Description |
|---|---|
| `modules/common.nix` | Core CLI tools (curl, jq, git, ripgrep, fd, tree, htop), git config, bash aliases |
| `modules/editors/vim.nix` | Neovim with sensible defaults (line numbers, smart tabs, case-insensitive search) |
| `modules/dev-tools/docker.nix` | docker-compose, lazydocker (Linux only) |

## Configurations

| Name | System | Usage |
|---|---|---|
| `linux` | aarch64-linux | OrbStack VM or Docker container |
| `mac` | aarch64-darwin | macOS Apple Silicon |

## Usage

### Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled
- Add to `/etc/nix/nix.conf`: `experimental-features = nix-command flakes`

### Apply configuration

```bash
# Clone
git clone https://github.com/rh7/dotfiles.git
cd dotfiles

# Linux
nix run home-manager -- switch --flake .#linux -b backup

# macOS (Apple Silicon)
nix run home-manager -- switch --flake .#mac -b backup
```

### Use the dev shell

```bash
cd dotfiles
nix develop    # drops into a shell with git, curl, jq
```

### Update dependencies

```bash
nix flake update    # updates flake.lock to latest nixpkgs + home-manager
nix run home-manager -- switch --flake .#linux -b backup   # re-apply
```

## Structure

```
.
├── flake.nix                          # Entry point: inputs, outputs, configurations
├── flake.lock                         # Pinned dependency versions
├── configurations/
│   ├── linux/home.nix                 # Linux-specific: username, home dir
│   └── macos/home.nix                 # macOS-specific: username, home dir
└── modules/
    ├── common.nix                     # Shared packages, git config, bash aliases
    ├── editors/vim.nix                # Neovim configuration
    └── dev-tools/docker.nix           # Docker tooling (Linux only)
```

## Adding packages

Edit `modules/common.nix` to add packages available to all configurations:

```nix
home.packages = with pkgs; [
  curl jq git ripgrep fd tree htop
  # add new packages here
];
```

Or create a new module file and include it in the relevant configuration in `flake.nix`.
