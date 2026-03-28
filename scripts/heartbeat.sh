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

HOSTNAME="$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/\.local$//')"
OS="$(uname -s)"
ARCH="$(uname -m)"

# ── Find config service ─────────────────────────────────────────────────
CONFIG_URL=""
for host in localhost rouvens-mac-studio-1 rouvens-mac-studio 100.100.241.110; do
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
    \"nix_generation\": \"$NIX_GEN\"
  }" --max-time 5 >/dev/null 2>&1
