#!/usr/bin/env bash
set -euo pipefail

echo "=== Rouven's Mac Bootstrap ==="

# 1. Xcode CLI tools
if ! xcode-select -p &>/dev/null; then
  echo "Installing Xcode CLI tools..."
  xcode-select --install
  echo "Press Enter after Xcode CLI tools finish installing..."
  read -r
fi

# 2. Homebrew
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# 3. Nix (Determinate)
if ! command -v nix &>/dev/null; then
  echo "Installing Nix..."
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

# 4. Clone dotfiles (if not already there)
if [ ! -d ~/dotfiles ]; then
  echo "Cloning dotfiles..."
  git clone https://github.com/rh7/dotfiles.git ~/dotfiles
fi

# 5. Determine machine config
echo ""
echo "Available configs:"
echo "  m5-air              MacBook Air M5"
echo "  rouven-air-m3       MacBook Air M3"
echo "  rouven-pro-m4       MacBook Pro M4"
echo "  rouvens-mac-mini    Mac Mini (office)"
echo "  rouvens-mac-studio  Mac Studio (AI lab)"
echo ""
read -rp "Which config? " MACHINE

# 6. Build
echo "Building $MACHINE..."
cd ~/dotfiles
sudo darwin-rebuild switch --flake ".#$MACHINE"

# 7. mackup
echo ""
echo "=== Settings Sync ==="
if command -v mackup &>/dev/null; then
  echo "Run 'mackup restore' to pull settings from iCloud"
else
  echo "mackup will be available after opening a new shell"
fi

echo ""
echo "=== Done! Open a new terminal to get your full shell config ==="
