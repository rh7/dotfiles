#!/usr/bin/env bash
# Backup current system state before a nix-darwin rebuild.
# Captures: installed apps, Homebrew state, macOS defaults, dock, shell config.
#
# Usage:
#   ./scripts/backup-system.sh                # backup to ~/dotfiles-backups/<timestamp>/
#   ./scripts/backup-system.sh /path/to/dir   # backup to custom location
#
# Restore: each file has instructions at the top.

set -euo pipefail

OS="$(uname -s)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${1:-$HOME/dotfiles-backups/$TIMESTAMP}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

mkdir -p "$BACKUP_DIR"
echo ""
echo "=== System Backup: $BACKUP_DIR ==="
echo ""

# ── 1. Homebrew state ───────────────────────────────────────────────────
if command -v brew &>/dev/null; then
  info "Backing up Homebrew..."
  brew bundle dump --file="$BACKUP_DIR/Brewfile" --force 2>/dev/null
  brew list --formula > "$BACKUP_DIR/brew-formulas.txt" 2>/dev/null
  brew list --cask > "$BACKUP_DIR/brew-casks.txt" 2>/dev/null
  ok "Homebrew (Brewfile + formula/cask lists)"
fi

# ── 2. Applications folder ─────────────────────────────────────────────
info "Listing /Applications..."
ls -1 /Applications/ > "$BACKUP_DIR/applications.txt" 2>/dev/null
ls -1 ~/Applications/ >> "$BACKUP_DIR/applications.txt" 2>/dev/null || true
ok "Application list"

# ── 3. macOS defaults ──────────────────────────────────────────────────
if [[ "$OS" == "Darwin" ]]; then
  info "Backing up macOS defaults..."

  # Dock
  defaults export com.apple.dock "$BACKUP_DIR/dock.plist" 2>/dev/null || true

  # Finder
  defaults export com.apple.finder "$BACKUP_DIR/finder.plist" 2>/dev/null || true

  # Global preferences
  defaults export NSGlobalDomain "$BACKUP_DIR/global-domain.plist" 2>/dev/null || true

  # Trackpad
  defaults export com.apple.AppleMultitouchTrackpad "$BACKUP_DIR/trackpad.plist" 2>/dev/null || true

  # Screenshots
  defaults export com.apple.screencapture "$BACKUP_DIR/screencapture.plist" 2>/dev/null || true

  ok "macOS defaults (dock, finder, global, trackpad, screenshots)"
fi

# ── 4. Shell configuration ─────────────────────────────────────────────
info "Backing up shell config..."
for f in .zshrc .zprofile .zshenv .bashrc .bash_profile .profile; do
  [[ -f "$HOME/$f" ]] && cp "$HOME/$f" "$BACKUP_DIR/$f" 2>/dev/null || true
done
ok "Shell configs"

# ── 5. Git config ──────────────────────────────────────────────────────
info "Backing up git config..."
[[ -f "$HOME/.gitconfig" ]] && cp "$HOME/.gitconfig" "$BACKUP_DIR/gitconfig" 2>/dev/null || true
git config --global --list > "$BACKUP_DIR/git-config-global.txt" 2>/dev/null || true
ok "Git config"

# ── 6. SSH config ──────────────────────────────────────────────────────
info "Backing up SSH config..."
[[ -f "$HOME/.ssh/config" ]] && cp "$HOME/.ssh/config" "$BACKUP_DIR/ssh-config" 2>/dev/null || true
ls -1 "$HOME/.ssh/" > "$BACKUP_DIR/ssh-files.txt" 2>/dev/null || true
ok "SSH config (config file + key listing, not keys themselves)"

# ── 7. Nix state (if exists) ──────────────────────────────────────────
if command -v nix &>/dev/null; then
  info "Backing up Nix state..."
  nix profile list > "$BACKUP_DIR/nix-profile.txt" 2>/dev/null || true
  ok "Nix profile"
fi

if command -v darwin-rebuild &>/dev/null; then
  darwin-rebuild --list-generations > "$BACKUP_DIR/darwin-generations.txt" 2>/dev/null || true
  ok "Darwin generations"
fi

# ── 8. Launchd user agents ────────────────────────────────────────────
if [[ "$OS" == "Darwin" ]]; then
  info "Backing up launchd agents..."
  launchctl list > "$BACKUP_DIR/launchd-agents.txt" 2>/dev/null || true
  ls -1 ~/Library/LaunchAgents/ > "$BACKUP_DIR/launchd-agent-files.txt" 2>/dev/null || true
  ok "Launchd agents"
fi

# ── 9. Mac App Store apps ─────────────────────────────────────────────
if command -v mas &>/dev/null; then
  info "Backing up Mac App Store apps..."
  mas list > "$BACKUP_DIR/mas-apps.txt" 2>/dev/null || true
  ok "Mac App Store apps"
fi

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "=== Backup Complete ==="
echo ""
echo "  Location: $BACKUP_DIR"
echo "  Files:"
ls -1 "$BACKUP_DIR" | sed 's/^/    /'
echo ""
echo "  To restore Homebrew: brew bundle install --file=$BACKUP_DIR/Brewfile"
echo "  To restore dock:     defaults import com.apple.dock $BACKUP_DIR/dock.plist && killall Dock"
echo "  To restore finder:   defaults import com.apple.finder $BACKUP_DIR/finder.plist && killall Finder"
echo ""
