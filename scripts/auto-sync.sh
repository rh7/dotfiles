#!/usr/bin/env bash
# Auto-sync: pull latest dotfiles, re-run audit, send heartbeat.
# Designed to run via cron every 30 minutes.
#
# Install:   ./scripts/device sync --install
# Uninstall: ./scripts/device sync --uninstall
# Run once:  ./scripts/device sync

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$HOME/.local/share/device-sync/sync.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG_FILE"; }

log "=== sync start ==="

# 1. Pull latest dotfiles
cd "$DOTFILES_DIR"
if command -v gh &>/dev/null; then
  gh repo sync 2>/dev/null && log "dotfiles synced" || log "dotfiles sync failed"
else
  git pull --ff-only 2>/dev/null && log "dotfiles pulled" || log "dotfiles pull failed"
fi

# 2. Re-run audit (uploads to config service)
bash "$DOTFILES_DIR/scripts/audit-device.sh" >/dev/null 2>&1 && log "audit uploaded" || log "audit failed"

# 3. Send heartbeat
bash "$DOTFILES_DIR/scripts/heartbeat.sh" 2>/dev/null && log "heartbeat sent" || log "heartbeat failed"

# 4. Trim log (keep last 500 lines)
if [[ -f "$LOG_FILE" ]] && [[ $(wc -l < "$LOG_FILE") -gt 500 ]]; then
  tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

log "=== sync complete ==="
