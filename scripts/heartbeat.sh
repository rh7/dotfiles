#!/usr/bin/env bash
# Send a heartbeat to the config service with current device stats.
# Run via cron every 5 minutes for live fleet monitoring.
#
# Install: add to crontab or use the device script:
#   ./scripts/device heartbeat          # run once
#   ./scripts/device heartbeat --install # install cron job
#
# The heartbeat reports: hostname, OS, uptime, disk, memory usage,
# nix generation, running agents, and Tailscale IP.

set -euo pipefail

# Resolve a trustworthy device identity (#33 / rh-device-management#150).
# `$(hostname)` alone is fragile: on a minimal Linux box the binary may be
# absent (→ empty), or the box may carry a placeholder name ("hostname",
# "localhost"), or a paste/CRLF artifact may sneak in — any of which used to
# register a PHANTOM device + workloads under a bogus identity. Try several
# sources (uname -n and /etc/hostname work even without the `hostname` binary),
# validate, and skip the heartbeat rather than send junk. Mirrors the server's
# isValidDeviceIdentity() guard so both ends agree on what a valid name is.
resolve_hostname() {
  local cand raw=""
  for cand in "$(hostname 2>/dev/null || true)" "$(uname -n 2>/dev/null || true)" \
              "$(cat /etc/hostname 2>/dev/null || true)" "${HOSTNAME:-}"; do
    cand="$(printf '%s' "$cand" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    cand="${cand%.local}"
    if [[ -n "$cand" ]]; then raw="$cand"; break; fi
  done
  local lc; lc="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    ""|hostname|localhost|localhost.localdomain) return 1 ;;
  esac
  if [[ "$raw" =~ [[:space:]] || "$raw" == *'$('* || "$raw" == *'`'* || "$raw" == *'/'* ]]; then
    return 1
  fi
  printf '%s' "$raw"
}

# Cron job (every 5 min): skip quietly on an invalid identity instead of failing
# loud — the server would 400 it anyway, and exit 1 here would spam cron mail.
HOSTNAME="$(resolve_hostname)" || {
  echo "[heartbeat] no valid hostname (empty/placeholder); skipping heartbeat" >&2
  exit 0
}
HOSTNAME="$(printf '%s' "$HOSTNAME" | tr '[:upper:]' '[:lower:]')"
OS="$(uname -s)"
ARCH="$(uname -m)"

# ── Find config service ─────────────────────────────────────────────────
CONFIG_URL=""
for host in localhost Rouvens-Mac-Studio.local rouvens-mac-studio-1 rouvens-mac-studio 100.100.241.110; do
  if curl -sf "http://${host}:3456/api/health" --max-time 2 &>/dev/null; then
    CONFIG_URL="http://${host}:3456"
    break
  fi
done

if [[ -z "$CONFIG_URL" ]]; then
  exit 0  # silently skip if config service is unreachable
fi

# ── Collect system stats ────────────────────────────────────────────────
UPTIME=$(uptime | sed 's/.*up //' | sed 's/,.*//')
TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
NIX_VER=$(nix --version 2>/dev/null || echo "")

# Disk usage
if [[ "$OS" == "Darwin" ]]; then
  DISK_USED=$(df -h / | tail -1 | awk '{print $5}')
  MEM_TOTAL=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}')
  # Memory pressure on macOS
  MEM_PRESSURE=$(memory_pressure 2>/dev/null | grep "System-wide" | awk '{print $NF}' || echo "unknown")
else
  DISK_USED=$(df -h / | tail -1 | awk '{print $5}')
  MEM_TOTAL=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1048576}')
  MEM_USED=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%.0f", $3/$2*100}' || echo "0")
  MEM_PRESSURE="${MEM_USED}%"
fi

# Nix generation
if [[ "$OS" == "Darwin" ]]; then
  NIX_GEN=$(darwin-rebuild --list-generations 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
else
  NIX_GEN=$(nixos-rebuild list-generations 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
fi

# ── Keys ───────────────────────────────────────────────────────────────
SSH_PUB=""
for keyfile in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  if [[ -f "$keyfile" ]]; then
    SSH_PUB=$(cat "$keyfile")
    break
  fi
done

AGE_PUB=""
AGE_KEY="$HOME/.config/sops/age/keys.txt"
if [[ -f "$AGE_KEY" ]]; then
  AGE_PUB=$(age-keygen -y "$AGE_KEY" 2>/dev/null || echo "")
fi

# ── Send heartbeat ──────────────────────────────────────────────────────
curl -sf -X POST "${CONFIG_URL}/api/devices/register" \
  -H "Content-Type: application/json" \
  -d "{
    \"hostname\": \"$HOSTNAME\",
    \"os\": \"$OS\",
    \"arch\": \"$ARCH\",
    \"role\": \"workstation\",
    \"tailscale_ip\": \"$TS_IP\",
    \"nix_version\": \"$NIX_VER\",
    \"nix_generation\": \"$NIX_GEN\",
    \"ssh_public_key\": \"$SSH_PUB\",
    \"age_public_key\": \"$AGE_PUB\"
  }" --max-time 5 >/dev/null 2>&1
