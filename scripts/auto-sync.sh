#!/usr/bin/env bash
# Auto-sync: pull latest dotfiles, re-run audit, send heartbeat.
# Designed to run via cron every 30 minutes.
#
# Install:   ./scripts/device sync --install
# Uninstall: ./scripts/device sync --uninstall
# Run once:  ./scripts/device sync

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOSTNAME="$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/\.local$//')"
LOG_FILE="$HOME/.local/share/device-sync/sync.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG_FILE"; }

# Track results for summary
RESULTS=()
ok_count=0
fail_count=0

step() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    RESULTS+=("+ $name")
    ((ok_count++))
    log "$name: ok"
  else
    RESULTS+=("x $name")
    ((fail_count++))
    log "$name: failed"
  fi
}

log "=== sync start ($HOSTNAME) ==="

# 1. Pull latest dotfiles
cd "$DOTFILES_DIR"
if command -v gh &>/dev/null; then
  step "dotfiles pull" gh repo sync
else
  step "dotfiles pull" git pull --ff-only
fi

# 2. Re-run audit (uploads to config service)
step "audit upload" bash "$DOTFILES_DIR/scripts/audit-device.sh"

# 3. Send heartbeat
step "heartbeat" bash "$DOTFILES_DIR/scripts/heartbeat.sh"

# 4. Trim log (keep last 500 lines)
if [[ -f "$LOG_FILE" ]] && [[ $(wc -l < "$LOG_FILE") -gt 500 ]]; then
  tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

log "=== sync complete ($ok_count ok, $fail_count failed) ==="

# Print summary to stdout (visible when run interactively)
echo "Sync $HOSTNAME: $ok_count/$((ok_count + fail_count)) steps succeeded"
for r in "${RESULTS[@]}"; do
  case "$r" in
    "+  "*) echo "  $r" ;;
    "x "*) echo "  $r" ;;
  esac
done
