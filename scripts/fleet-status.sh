#!/usr/bin/env bash
# Fleet status: check all devices' sync status from the config service.
#
# Usage:
#   ./scripts/fleet-status.sh              # summary view
#   ./scripts/fleet-status.sh --detail     # show hardware + AI infra
#   ./scripts/fleet-status.sh --stale      # only show devices with old audits

set -uo pipefail

MODE="${1:-}"

# Find config service
CONFIG_URL=""
for host in localhost rouvens-mac-studio-1 rouvens-mac-studio 100.100.241.110; do
  if curl -sf "http://${host}:3456/api/health" --max-time 2 &>/dev/null; then
    CONFIG_URL="http://${host}:3456"; break
  fi
done

if [[ -z "$CONFIG_URL" ]]; then
  echo "Config service not reachable"
  exit 1
fi

python3 -c "
import json, urllib.request, sys
from datetime import datetime, timedelta, timezone

config_url = '$CONFIG_URL'
mode = '$MODE'

# Get fleet overview
r = urllib.request.urlopen(f'{config_url}/api/fleet/overview', timeout=10)
fleet = json.loads(r.read())

# Get all devices
r = urllib.request.urlopen(f'{config_url}/api/devices', timeout=10)
devices = json.loads(r.read())

# Get audits for each device
audits = {}
for d in devices:
    h = d['hostname']
    if h in ('hostname', 'localhost', 'test-device'): continue
    try:
        r = urllib.request.urlopen(f'{config_url}/api/audit/{h}', timeout=3)
        a = json.loads(r.read())
        if 'error' not in a:
            audits[h] = a
    except: pass

now = datetime.now(timezone.utc)
stale_threshold = now - timedelta(hours=1)

s = fleet['summary']
print(f'Fleet: {s[\"total_devices\"]} devices | {s[\"online\"]} online | {s[\"stale\"]} stale | {s[\"offline\"]} offline')
print(f'Audits: {len(audits)} devices with audit data')
print()

# Sort audits by recency
sorted_audits = sorted(audits.items(), key=lambda x: x[1].get('audited_at', ''), reverse=True)

if mode == '--stale':
    sorted_audits = [(h, a) for h, a in sorted_audits
                     if a.get('audited_at', '') < stale_threshold.strftime('%Y-%m-%d %H:%M:%S')]
    if not sorted_audits:
        print('All audited devices are fresh (< 1 hour old)')
        sys.exit(0)

# Print device table
hw_header = f'{\"Chip\":<22s} {\"RAM\":>4s}  ' if mode == '--detail' else ''
print(f'{\"Device\":<25s} {hw_header}{\"Apps\":>4s} {\"Casks\":>5s} {\"CLI\":>4s}  {\"Audited\":<20s}  Status')
print('-' * (100 if mode == '--detail' else 75))

for h, a in sorted_audits:
    sys_info = a.get('system', {})
    hw = sys_info.get('hardware', {})
    brew = a.get('homebrew', {})
    apps = a.get('applications', [])
    cli = a.get('cli_tools', {})
    at = a.get('audited_at', '?')

    # Determine freshness
    try:
        audit_time = datetime.strptime(at, '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc)
        age = now - audit_time
        if age < timedelta(minutes=35):
            status = 'fresh'
        elif age < timedelta(hours=1):
            status = 'recent'
        elif age < timedelta(hours=24):
            status = f'{int(age.total_seconds() / 3600)}h ago'
        else:
            status = f'{age.days}d ago'
    except:
        status = '?'

    chip = str(hw.get('chip', ''))[:22] if hw else ''
    mem = str(hw.get('memory_gb', '')) if hw else ''

    hw_col = f'{chip:<22s} {mem:>4s}  ' if mode == '--detail' else ''
    print(f'{h:<25s} {hw_col}{len(apps):>4d} {brew.get(\"cask_count\", 0):>5d} {len(cli):>4d}  {at:<20s}  {status}')

# AI infrastructure summary (detail mode)
if mode == '--detail':
    print()
    print('=== AI Infrastructure ===')
    for h, a in sorted_audits:
        ai = a.get('ai_infrastructure', {})
        if not ai or not isinstance(ai, dict): continue
        parts = []
        ollama = ai.get('ollama', {})
        if ollama and ollama.get('models'):
            parts.append(f'ollama:{len(ollama[\"models\"])} models')
        lm = ai.get('lm_studio', {})
        if lm and lm.get('models'):
            parts.append(f'lmstudio:{len(lm[\"models\"])} models')
        llama = ai.get('llama_server', {})
        if llama and llama.get('instances'):
            parts.append(f'llama.cpp:{len(llama[\"instances\"])} instances')
        gpu = ai.get('gpu', {})
        if gpu:
            info = gpu.get('info', gpu.get('nvidia', []))
            if info:
                parts.append(f'gpu:{info[0] if isinstance(info, list) and info else \"yes\"}')
        if parts:
            print(f'  {h:<25s} {\", \".join(parts)}')
"
