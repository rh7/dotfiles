#!/bin/bash
# bootstrap.sh — Run once on a fresh Mac
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/bootstrap.sh)
set -e

echo "🚀 Starting Mac bootstrap..."

# ── 1. Xcode CLI Tools ────────────────────────────────────────────────────
if ! xcode-select -p &>/dev/null; then
  echo "→ Installing Xcode CLI tools..."
  xcode-select --install
  echo "  Wait for install to complete, then re-run this script."
  exit 0
fi

# ── 2. Nix (Determinate Systems — handles Apple Silicon quirks) ───────────
if ! command -v nix &>/dev/null; then
  echo "→ Installing Nix..."
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

# ── 3. Clone dotfiles ─────────────────────────────────────────────────────
DOTFILES="$HOME/dotfiles"
if [ ! -d "$DOTFILES" ]; then
  echo "→ Cloning dotfiles..."
  git clone https://github.com/rh7/dotfiles.git "$DOTFILES"
else
  echo "→ dotfiles already present, pulling latest..."
  git -C "$DOTFILES" pull
fi

# ── 4. Apply nix-darwin config ────────────────────────────────────────────
HOSTNAME=$(hostname -s)
echo "→ Applying nix-darwin for: $HOSTNAME"
cd "$DOTFILES"

if ! command -v darwin-rebuild &>/dev/null; then
  echo "→ Bootstrapping nix-darwin..."
  nix run nix-darwin -- switch --flake ".#$HOSTNAME"
else
  darwin-rebuild switch --flake ".#$HOSTNAME"
fi

# ── 5. mackup restore (restores app settings from iCloud) ─────────────────
echo ""
echo "✅ Bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. Sign into iCloud and wait for mackup folder to sync"
echo "  2. Run: mackup restore"
echo "  3. Sign into 1Password → enable SSH Agent"
echo "  4. Sign into Arc (browser sync)"
echo "  5. Sign into Cursor (GitHub settings sync)"
echo ""
echo "To apply config changes in future: nrs"
