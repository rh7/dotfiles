#!/usr/bin/env bash
# Audit a device's current state — non-destructive inventory collection.
# Sends results to the config service for cross-device comparison.
#
# Usage:
#   ./scripts/audit-device.sh              # audit and report
#   ./scripts/audit-device.sh --local      # audit only, print JSON (no upload)
#   ./scripts/audit-device.sh --save       # audit and save to ~/dotfiles-backups/audit/

set -euo pipefail

HOSTNAME="$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/\.local$//')"
OS="$(uname -s)"
ARCH="$(uname -m)"
MODE="${1:-report}"

# ── Find config service ─────────────────────────────────────────────────
find_config_service() {
  for host in localhost rouvens-mac-studio-1 rouvens-mac-studio 100.100.241.110; do
    if curl -sf "http://${host}:3456/api/health" --max-time 2 &>/dev/null; then
      echo "http://${host}:3456"; return
    fi
  done
  echo ""
}

# ══════════════════════════════════════════════════════════════════════════
# Collectors — each outputs a JSON fragment
# ══════════════════════════════════════════════════════════════════════════

collect_system() {
  local hw_model="" hw_chip="" hw_memory="" hw_serial=""
  if [[ "$OS" == "Darwin" ]]; then
    hw_model=$(sysctl -n hw.model 2>/dev/null || echo "")
    hw_chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "")
    # Apple Silicon: get chip name from system_profiler
    if [[ -z "$hw_chip" ]] || [[ "$hw_chip" == *"Apple"* ]]; then
      hw_chip=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Chip:" | sed 's/.*Chip: //' || echo "$hw_chip")
    fi
    hw_memory=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}' || echo "")
    hw_serial=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Serial Number" | sed 's/.*: //' || echo "")
  elif [[ "$OS" == "Linux" ]]; then
    hw_model=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "")
    hw_chip=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "")
    hw_memory=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1048576}' || echo "")
    hw_serial=$(cat /sys/devices/virtual/dmi/id/product_serial 2>/dev/null || echo "")
  fi

  cat <<JSON
{
  "hostname": "$HOSTNAME",
  "os": "$OS",
  "arch": "$ARCH",
  "macos_version": "$(sw_vers -productVersion 2>/dev/null || echo '')",
  "kernel": "$(uname -r)",
  "uptime": "$(uptime | sed 's/.*up //' | sed 's/,.*//')",
  "shell": "$SHELL",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hardware": {
    "model": "$hw_model",
    "chip": "$hw_chip",
    "memory_gb": $([[ -n "$hw_memory" ]] && echo "$hw_memory" || echo "0"),
    "serial": "$hw_serial"
  }
}
JSON
}

collect_homebrew() {
  if ! command -v brew &>/dev/null; then echo '{"installed": false}'; return; fi

  local formulas casks taps
  formulas=$(brew list --formula -1 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split('\n')))")
  casks=$(brew list --cask -1 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split('\n')))")
  taps=$(brew tap 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split('\n')))")

  cat <<JSON
{
  "installed": true,
  "formulas": $formulas,
  "casks": $casks,
  "taps": $taps,
  "formula_count": $(brew list --formula -1 2>/dev/null | wc -l | tr -d ' '),
  "cask_count": $(brew list --cask -1 2>/dev/null | wc -l | tr -d ' ')
}
JSON
}

collect_mas() {
  if ! command -v mas &>/dev/null; then echo '{"installed": false}'; return; fi

  local apps
  apps=$(mas list 2>/dev/null | python3 -c "
import sys, json
apps = []
for line in sys.stdin:
    parts = line.strip().split(' ', 1)
    if len(parts) == 2:
        app_id = parts[0]
        name = parts[1].rsplit('(', 1)[0].strip()
        apps.append({'id': app_id, 'name': name})
print(json.dumps(apps))
" 2>/dev/null || echo '[]')

  echo "{\"installed\": true, \"apps\": $apps}"
}

collect_applications() {
  python3 -c "
import os, json
apps = []
for d in ['/Applications', os.path.expanduser('~/Applications')]:
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            if f.endswith('.app'):
                apps.append(f.replace('.app', ''))
print(json.dumps(apps))
" 2>/dev/null || echo '[]'
}

collect_macos_defaults() {
  if [[ "$OS" != "Darwin" ]]; then echo '{}'; return; fi

  python3 -c "
import subprocess, json

def read_default(domain, key):
    try:
        r = subprocess.run(['defaults', 'read', domain, key], capture_output=True, text=True, timeout=2)
        v = r.stdout.strip()
        if v.isdigit(): return int(v)
        if v in ('true', '1'): return True
        if v in ('false', '0'): return False
        return v
    except: return None

defaults = {
    'dock': {
        'autohide': read_default('com.apple.dock', 'autohide'),
        'tilesize': read_default('com.apple.dock', 'tilesize'),
        'show-recents': read_default('com.apple.dock', 'show-recents'),
        'orientation': read_default('com.apple.dock', 'orientation'),
        'mru-spaces': read_default('com.apple.dock', 'mru-spaces'),
    },
    'finder': {
        'AppleShowAllExtensions': read_default('com.apple.finder', 'AppleShowAllExtensions'),
        'AppleShowAllFiles': read_default('com.apple.finder', 'AppleShowAllFiles'),
        'ShowPathbar': read_default('com.apple.finder', 'ShowPathbar'),
        'ShowStatusBar': read_default('com.apple.finder', 'ShowStatusBar'),
        'FXPreferredViewStyle': read_default('com.apple.finder', 'FXPreferredViewStyle'),
    },
    'keyboard': {
        'InitialKeyRepeat': read_default('NSGlobalDomain', 'InitialKeyRepeat'),
        'KeyRepeat': read_default('NSGlobalDomain', 'KeyRepeat'),
        'NSAutomaticCapitalizationEnabled': read_default('NSGlobalDomain', 'NSAutomaticCapitalizationEnabled'),
        'NSAutomaticSpellingCorrectionEnabled': read_default('NSGlobalDomain', 'NSAutomaticSpellingCorrectionEnabled'),
    },
    'trackpad': {
        'Clicking': read_default('com.apple.AppleMultitouchTrackpad', 'Clicking'),
        'TrackpadThreeFingerDrag': read_default('com.apple.AppleMultitouchTrackpad', 'TrackpadThreeFingerDrag'),
    },
    'security': {
        'GuestEnabled': read_default('com.apple.loginwindow', 'GuestEnabled'),
    },
}
print(json.dumps(defaults))
"
}

collect_dock_apps() {
  if [[ "$OS" != "Darwin" ]]; then echo '[]'; return; fi

  python3 -c "
import subprocess, json, plistlib
try:
    r = subprocess.run(['defaults', 'export', 'com.apple.dock', '-'], capture_output=True, timeout=5)
    plist = plistlib.loads(r.stdout)
    apps = []
    for item in plist.get('persistent-apps', []):
        tile = item.get('tile-data', {})
        label = tile.get('file-label', '')
        path = tile.get('file-data', {}).get('_CFURLString', '')
        if label: apps.append({'label': label, 'path': path})
    print(json.dumps(apps))
except: print('[]')
"
}

collect_cli_tools() {
  python3 -c "
import shutil, json
tools = [
    'git', 'node', 'python3', 'rustup', 'go', 'ruby',
    'docker', 'kubectl', 'terraform', 'aws', 'gcloud',
    'brew', 'nix', 'direnv', 'gh', 'jq', 'yq', 'rg', 'fd', 'bat', 'eza',
    'fzf', 'zoxide', 'htop', 'btm', 'tldr', 'tree', 'nmap', 'curl', 'wget',
    'ollama', 'claude', 'code', 'cursor', 'zed',
    'tailscale', 'age', 'sops',
    'supabase', 'railway', 'vercel',
]
found = {}
for t in tools:
    path = shutil.which(t)
    if path:
        found[t] = path
print(json.dumps(found))
"
}

collect_node_globals() {
  if ! command -v npm &>/dev/null; then echo '[]'; return; fi
  npm list -g --depth=0 --json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    deps = d.get('dependencies', {})
    print(json.dumps([{'name': k, 'version': v.get('version', '')} for k, v in deps.items()]))
except: print('[]')
" 2>/dev/null || echo '[]'
}

collect_services() {
  if [[ "$OS" != "Darwin" ]]; then echo '{}'; return; fi

  local brew_services launchd
  brew_services=$(brew services list 2>/dev/null | tail -n +2 | awk '{print $1, $2}' | python3 -c "
import sys, json
svcs = []
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) >= 2:
        svcs.append({'name': parts[0], 'status': parts[1]})
print(json.dumps(svcs))
" 2>/dev/null || echo '[]')

  launchd=$(launchctl list 2>/dev/null | grep -v 'com.apple' | grep -v '^-.*0.*$' | tail -n +2 | python3 -c "
import sys, json
svcs = []
for line in sys.stdin:
    parts = line.strip().split('\t')
    if len(parts) >= 3:
        svcs.append({'pid': parts[0], 'label': parts[2]})
print(json.dumps(svcs))
" 2>/dev/null || echo '[]')

  echo "{\"brew_services\": $brew_services, \"launchd\": $launchd}"
}

collect_git_config() {
  python3 -c "
import subprocess, json
try:
    r = subprocess.run(['git', 'config', '--global', '--list'], capture_output=True, text=True, timeout=5)
    config = {}
    for line in r.stdout.strip().split('\n'):
        if '=' in line:
            k, v = line.split('=', 1)
            config[k] = v
    print(json.dumps(config))
except: print('{}')
"
}

collect_ssh_keys() {
  python3 -c "
import os, json
ssh_dir = os.path.expanduser('~/.ssh')
keys = []
if os.path.isdir(ssh_dir):
    for f in sorted(os.listdir(ssh_dir)):
        if f.endswith('.pub'):
            keys.append(f.replace('.pub', ''))
print(json.dumps(keys))
"
}

collect_docker() {
  if ! command -v docker &>/dev/null; then echo '{"installed": false}'; return; fi

  python3 -c "
import subprocess, json

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

# Containers (all)
containers = []
out = run(\"docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.State}}'\")
for line in out.split('\n'):
    if not line.strip(): continue
    parts = line.split('\t')
    if len(parts) >= 6:
        c = {'id': parts[0], 'name': parts[1], 'image': parts[2], 'status': parts[3], 'ports': parts[4], 'state': parts[5]}
        # Get restart policy
        rp = run(f\"docker inspect {parts[0]} --format '{{{{.HostConfig.RestartPolicy.Name}}}}'\")
        if rp: c['restart_policy'] = rp
        containers.append(c)

# Images
images = []
out = run(\"docker images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}'\")
for line in out.split('\n'):
    if not line.strip(): continue
    parts = line.split('\t')
    if len(parts) >= 4:
        images.append({'repository': parts[0], 'tag': parts[1], 'id': parts[2], 'size': parts[3]})

# Volumes
volumes = []
out = run(\"docker volume ls --format '{{.Name}}\t{{.Driver}}'\")
for line in out.split('\n'):
    if not line.strip(): continue
    parts = line.split('\t')
    if len(parts) >= 2:
        volumes.append({'name': parts[0], 'driver': parts[1]})

# Networks (non-default)
networks = []
out = run(\"docker network ls --format '{{.Name}}\t{{.Driver}}\t{{.Scope}}'\")
for line in out.split('\n'):
    if not line.strip(): continue
    parts = line.split('\t')
    if len(parts) >= 3 and parts[0] not in ('bridge', 'host', 'none'):
        networks.append({'name': parts[0], 'driver': parts[1], 'scope': parts[2]})

# Compose projects
compose_projects = []
out = run('docker compose ls --format table 2>/dev/null')
for line in out.split('\n')[1:]:
    if not line.strip(): continue
    parts = line.split()
    if len(parts) >= 2:
        compose_projects.append({'name': parts[0], 'status': parts[1]})

print(json.dumps({
    'installed': True,
    'containers': containers,
    'container_count': len(containers),
    'images': images,
    'image_count': len(images),
    'volumes': volumes,
    'networks': networks,
    'compose_projects': compose_projects,
}))
" 2>/dev/null || echo '{"installed": true, "error": "collection failed"}'
}

collect_nix_state() {
  if ! command -v nix &>/dev/null; then echo '{"installed": false}'; return; fi

  python3 -c "
import subprocess, json, os

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        return r.stdout.strip()
    except: return ''

result = {'installed': True}

# Nix version
result['version'] = run('nix --version').replace('nix (Nix) ', '')

# Current system generation (NixOS or nix-darwin)
gen = run('darwin-rebuild --list-generations 2>/dev/null | tail -1') or run('nixos-rebuild list-generations 2>/dev/null | tail -1')
if gen: result['current_generation'] = gen.strip()

# Home-manager generation
hm_gen = run('home-manager generations 2>/dev/null | head -1')
if hm_gen: result['home_manager_generation'] = hm_gen.strip()

# Nix channels or flake inputs
channels = run('nix-channel --list 2>/dev/null')
if channels:
    result['channels'] = [{'name': l.split()[0], 'url': l.split()[1]} for l in channels.split('\n') if len(l.split()) >= 2]

# Flake lock info (if flake.nix exists in dotfiles)
for flake_dir in [os.path.expanduser('~/dotfiles'), os.path.expanduser('~/.config/nix-darwin')]:
    lock = os.path.join(flake_dir, 'flake.lock')
    if os.path.isfile(lock):
        try:
            with open(lock) as f:
                lock_data = json.load(f)
            nodes = lock_data.get('nodes', {})
            inputs = {}
            for name, node in nodes.items():
                if name == 'root': continue
                locked = node.get('locked', {})
                if locked:
                    inputs[name] = {
                        'type': locked.get('type', ''),
                        'rev': locked.get('rev', '')[:12],
                        'last_modified': locked.get('lastModified', ''),
                    }
            if inputs:
                result['flake_inputs'] = inputs
                result['flake_dir'] = flake_dir
        except: pass
        break

# Nix store size
store_size = run('du -sh /nix/store 2>/dev/null | cut -f1')
if store_size: result['store_size'] = store_size.strip()

# Nix profile packages
profile_pkgs = run('nix profile list 2>/dev/null')
if profile_pkgs:
    pkgs = []
    for line in profile_pkgs.split('\n'):
        if line.strip():
            parts = line.split()
            if len(parts) >= 2:
                pkgs.append(parts[-1].split('#')[-1] if '#' in parts[-1] else parts[-1])
    if pkgs: result['profile_packages'] = pkgs

print(json.dumps(result))
" 2>/dev/null || echo '{"installed": true, "error": "collection failed"}'
}

collect_ai_infrastructure() {
  python3 -c "
import subprocess, json, re

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

# Ollama models
ollama_out = run('ollama list 2>/dev/null')
if ollama_out:
    models = []
    for line in ollama_out.split('\n')[1:]:
        if not line.strip(): continue
        parts = line.split()
        if len(parts) >= 3:
            models.append({'name': parts[0], 'id': parts[1], 'size': parts[2]})
    result['ollama'] = {'running': True, 'models': models, 'model_count': len(models)}

    # Running models
    ps_out = run('ollama ps 2>/dev/null')
    if ps_out:
        running = []
        for line in ps_out.split('\n')[1:]:
            if not line.strip(): continue
            parts = line.split()
            if parts: running.append(parts[0])
        result['ollama']['running_models'] = running

# LM Studio models
import os
lm_dir = os.path.expanduser('~/.cache/lm-studio/models')
if os.path.isdir(lm_dir):
    models = []
    for root, dirs, files in os.walk(lm_dir):
        for f in files:
            if f.endswith('.gguf'):
                path = os.path.join(root, f)
                size_gb = round(os.path.getsize(path) / (1024**3), 1)
                models.append({'name': f, 'size_gb': size_gb})
    result['lm_studio'] = {'models': models, 'model_count': len(models)}

# llama-server / llama.cpp instances
llama_procs = run(\"ps aux | grep -E 'llama[_-]server|llama\\.cpp' | grep -v grep\")
if llama_procs:
    instances = []
    for line in llama_procs.split('\n'):
        if not line.strip(): continue
        parts = line.split()
        pid = parts[1]
        cmd = ' '.join(parts[10:])
        # Extract port if present
        port_match = re.search(r'--port\s+(\d+)', cmd) or re.search(r'-p\s+(\d+)', cmd)
        port = port_match.group(1) if port_match else None
        # Extract model if present
        model_match = re.search(r'(?:-m|--model)\s+(\S+)', cmd)
        model = os.path.basename(model_match.group(1)) if model_match else None
        instances.append({'pid': pid, 'port': port, 'model': model})
    result['llama_server'] = {'instances': instances}

# GPU info (macOS Metal / NVIDIA)
import platform
if platform.system() == 'Darwin':
    gpu = run('system_profiler SPDisplaysDataType 2>/dev/null | grep -E \"Chipset|VRAM|Metal\"')
    if gpu:
        result['gpu'] = {'info': [l.strip() for l in gpu.split('\n') if l.strip()]}
    # Unified memory available
    mem = run('sysctl -n hw.memsize 2>/dev/null')
    if mem:
        result['gpu_memory_gb'] = round(int(mem) / (1024**3))
else:
    nvidia = run('nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null')
    if nvidia:
        gpus = []
        for line in nvidia.split('\n'):
            if not line.strip(): continue
            parts = [p.strip() for p in line.split(',')]
            if len(parts) >= 4:
                gpus.append({'name': parts[0], 'memory_total_mb': int(parts[1]), 'memory_used_mb': int(parts[2]), 'utilization_pct': int(parts[3])})
        result['gpu'] = {'nvidia': gpus}
    # Jetson-specific
    jetson = run('cat /proc/device-tree/model 2>/dev/null')
    if 'jetson' in jetson.lower():
        result['gpu']['jetson_model'] = jetson

if not result:
    print('{}')
else:
    print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_security_posture() {
  python3 -c "
import subprocess, json, os, platform

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

if platform.system() == 'Darwin':
    # FileVault (disk encryption)
    fv = run('fdesetup status 2>/dev/null')
    result['filevault'] = 'On' in fv if fv else None

    # Firewall
    fw = run('/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null')
    result['firewall'] = 'enabled' in fw.lower() if fw else None

    # SIP (System Integrity Protection)
    sip = run('csrutil status 2>/dev/null')
    result['sip_enabled'] = 'enabled' in sip.lower() if sip else None

    # Gatekeeper
    gk = run('spctl --status 2>/dev/null')
    result['gatekeeper'] = 'enabled' in (gk or '').lower()

    # Auto-login disabled
    autologin = run('defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null')
    result['auto_login_disabled'] = autologin == ''

    # Remote login (SSH)
    ssh_status = run('systemsetup -getremotelogin 2>/dev/null')
    result['remote_login'] = 'On' in ssh_status if ssh_status else None

else:
    # Linux: UFW or iptables
    ufw = run('ufw status 2>/dev/null')
    if ufw:
        result['ufw'] = 'active' in ufw.lower()
    else:
        iptables_rules = run('iptables -L -n 2>/dev/null | wc -l')
        result['iptables_rules'] = int(iptables_rules) if iptables_rules.isdigit() else 0

    # Disk encryption (LUKS)
    luks = run('lsblk -o NAME,FSTYPE 2>/dev/null | grep crypto_LUKS')
    result['disk_encryption'] = bool(luks)

    # SELinux / AppArmor
    selinux = run('getenforce 2>/dev/null')
    if selinux: result['selinux'] = selinux
    apparmor = run('aa-status --enabled 2>/dev/null')
    if 'Yes' in (apparmor or ''): result['apparmor'] = True

    # SSH config
    sshd = run('systemctl is-active sshd 2>/dev/null')
    result['sshd_active'] = sshd == 'active'

# Age key presence
age_key = os.path.expanduser('~/.config/sops/age/keys.txt')
result['age_key_present'] = os.path.isfile(age_key)
if os.path.isfile(age_key):
    pub = run(f'grep -o \"age1[a-z0-9]*\" {age_key} | head -1')
    if pub: result['age_public_key'] = pub

# SOPS config
for sops_path in ['.sops.yaml', os.path.expanduser('~/dotfiles/.sops.yaml')]:
    if os.path.isfile(sops_path):
        result['sops_config_present'] = True
        break
else:
    result['sops_config_present'] = False

# SSH authorized_keys count
auth_keys = os.path.expanduser('~/.ssh/authorized_keys')
if os.path.isfile(auth_keys):
    with open(auth_keys) as f:
        result['authorized_keys_count'] = len([l for l in f if l.strip() and not l.startswith('#')])

print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_tailscale() {
  if ! command -v tailscale &>/dev/null; then echo '{"installed": false}'; return; fi

  python3 -c "
import subprocess, json

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {'installed': True}

# Version
result['version'] = run('tailscale version 2>/dev/null').split('\n')[0]

# IP
result['ip'] = run('tailscale ip -4 2>/dev/null')

# Self status
status_json = run('tailscale status --self --json 2>/dev/null')
if status_json:
    try:
        st = json.loads(status_json)
        self_node = st.get('Self', {})
        result['hostname'] = self_node.get('HostName', '')
        result['dns_name'] = self_node.get('DNSName', '').rstrip('.')
        result['os'] = self_node.get('OS', '')
        result['online'] = self_node.get('Online', False)
        result['tags'] = self_node.get('Tags', [])
        result['key_expiry'] = self_node.get('KeyExpiry', '')
        result['created'] = self_node.get('Created', '')
        result['is_exit_node'] = self_node.get('ExitNode', False)
        result['advertised_routes'] = self_node.get('AllowedIPs', [])

        # Tailnet info
        result['magic_dns_suffix'] = st.get('MagicDNSSuffix', '')
        result['current_tailnet'] = st.get('CurrentTailnet', {}).get('Name', '')
    except: pass

# Exit node in use
exit_node = run('tailscale exit-node status 2>/dev/null')
if exit_node and 'not using' not in exit_node.lower():
    result['using_exit_node'] = exit_node

print(json.dumps(result))
" 2>/dev/null || echo '{"installed": true, "error": "collection failed"}'
}

collect_crontabs() {
  python3 -c "
import subprocess, json, os

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except: return ''

result = {}

# User crontab
crontab = run('crontab -l 2>/dev/null')
if crontab:
    entries = [l.strip() for l in crontab.split('\n') if l.strip() and not l.startswith('#')]
    result['user_crontab'] = entries
    result['user_crontab_count'] = len(entries)
else:
    result['user_crontab'] = []
    result['user_crontab_count'] = 0

# System crontab entries (non-comment)
sys_crontab = run('cat /etc/crontab 2>/dev/null')
if sys_crontab:
    entries = [l.strip() for l in sys_crontab.split('\n') if l.strip() and not l.startswith('#')]
    result['system_crontab'] = entries

# Cron.d entries
cron_d = '/etc/cron.d'
if os.path.isdir(cron_d):
    result['cron_d_files'] = [f for f in os.listdir(cron_d) if not f.startswith('.')]

# Systemd timers (Linux)
timers = run('systemctl list-timers --no-pager --no-legend 2>/dev/null')
if timers:
    result['systemd_timers'] = []
    for line in timers.split('\n'):
        parts = line.split()
        if len(parts) >= 2:
            result['systemd_timers'].append(parts[-1])  # unit name is last

# launchd user agents with schedule (macOS)
import platform
if platform.system() == 'Darwin':
    agent_dir = os.path.expanduser('~/Library/LaunchAgents')
    if os.path.isdir(agent_dir):
        agents = []
        for f in os.listdir(agent_dir):
            if f.endswith('.plist'):
                content = run(f'defaults read {os.path.join(agent_dir, f)} 2>/dev/null')
                if 'StartInterval' in content or 'StartCalendarInterval' in content:
                    agents.append(f.replace('.plist', ''))
        if agents: result['launchd_scheduled_agents'] = agents

print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_resource_usage() {
  python3 -c "
import subprocess, json, os, platform

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

# Load average
load = run('sysctl -n vm.loadavg 2>/dev/null') or run('cat /proc/loadavg 2>/dev/null')
if load:
    parts = load.replace('{', '').replace('}', '').split()
    if len(parts) >= 3:
        result['load_average'] = {'1m': float(parts[0]), '5m': float(parts[1]), '15m': float(parts[2])}

# Memory
if platform.system() == 'Darwin':
    mem_total = int(run('sysctl -n hw.memsize') or '0')
    # vm_stat for memory pressure
    vm_stat = run('vm_stat')
    page_size = 16384  # Apple Silicon
    if vm_stat:
        import re
        free = re.search(r'Pages free:\s+(\d+)', vm_stat)
        active = re.search(r'Pages active:\s+(\d+)', vm_stat)
        inactive = re.search(r'Pages inactive:\s+(\d+)', vm_stat)
        wired = re.search(r'Pages wired down:\s+(\d+)', vm_stat)
        compressed = re.search(r'Pages occupied by compressor:\s+(\d+)', vm_stat)
        result['memory'] = {
            'total_gb': round(mem_total / (1024**3), 1),
            'free_pages': int(free.group(1)) if free else 0,
            'active_pages': int(active.group(1)) if active else 0,
            'wired_pages': int(wired.group(1)) if wired else 0,
            'compressed_pages': int(compressed.group(1)) if compressed else 0,
        }
else:
    meminfo = run('cat /proc/meminfo')
    if meminfo:
        mem = {}
        for line in meminfo.split('\n'):
            parts = line.split(':')
            if len(parts) == 2:
                key = parts[0].strip()
                val = parts[1].strip().split()[0]
                if key in ('MemTotal', 'MemFree', 'MemAvailable', 'SwapTotal', 'SwapFree'):
                    mem[key] = round(int(val) / (1024*1024), 1)  # GB
        result['memory'] = mem

# Swap
swap = run('sysctl -n vm.swapusage 2>/dev/null')
if swap:
    import re
    total = re.search(r'total\s*=\s*([\d.]+)M', swap)
    used = re.search(r'used\s*=\s*([\d.]+)M', swap)
    if total and used:
        result['swap'] = {'total_mb': float(total.group(1)), 'used_mb': float(used.group(1))}

# Disk usage by key directories
dirs_to_check = {
    '/nix/store': '/nix/store',
    'home': os.path.expanduser('~'),
    'docker': '/var/lib/docker',
}
# Add common cache dirs
cache_dir = os.path.expanduser('~/.cache')
if os.path.isdir(cache_dir):
    dirs_to_check['cache'] = cache_dir

disk_usage = {}
for label, path in dirs_to_check.items():
    if os.path.isdir(path):
        size = run(f'du -sh {path} 2>/dev/null | cut -f1')
        if size: disk_usage[label] = size.strip()
result['disk_by_directory'] = disk_usage

# Root disk
df = run('df -h / | tail -1')
if df:
    parts = df.split()
    if len(parts) >= 5:
        result['root_disk'] = {'total': parts[1], 'used': parts[2], 'available': parts[3], 'percent_used': parts[4]}

print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_shell_env() {
  python3 -c "
import subprocess, json, os, platform

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except: return ''

result = {}

# Shell
result['shell'] = os.environ.get('SHELL', '')

# PATH entries (deduplicated, in order)
path_entries = []
seen = set()
for p in os.environ.get('PATH', '').split(':'):
    if p and p not in seen:
        path_entries.append(p)
        seen.add(p)
result['path_entries'] = path_entries

# Zsh plugins (oh-my-zsh or zinit/zplug)
zshrc = os.path.expanduser('~/.zshrc')
if os.path.isfile(zshrc):
    with open(zshrc) as f:
        content = f.read()
    import re
    # oh-my-zsh plugins
    match = re.search(r'plugins=\(([^)]+)\)', content)
    if match:
        result['zsh_plugins'] = match.group(1).split()
    # zinit/zplug
    zinit = re.findall(r'zinit\s+(?:light|load)\s+(\S+)', content)
    if zinit: result['zinit_plugins'] = zinit
    zplug = re.findall(r'zplug\s+[\"\\'](\S+)[\"\\']', content)
    if zplug: result['zplug_plugins'] = zplug

# Starship config exists
if os.path.isfile(os.path.expanduser('~/.config/starship.toml')):
    result['starship'] = True

# Custom aliases count
aliases = run('alias 2>/dev/null')
if aliases:
    result['alias_count'] = len(aliases.split('\n'))

# Tmux config
if os.path.isfile(os.path.expanduser('~/.tmux.conf')):
    result['tmux_config'] = True

# Direnv
if os.path.isfile(os.path.expanduser('~/.direnvrc')) or os.path.isfile(os.path.expanduser('~/.config/direnv/direnvrc')):
    result['direnv_config'] = True

print(json.dumps(result))
" 2>/dev/null || echo '{}'
}

collect_editor_extensions() {
  python3 -c "
import subprocess, json, os

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

# VS Code extensions
vscode = run('code --list-extensions 2>/dev/null')
if vscode:
    result['vscode'] = sorted(vscode.split('\n'))
    result['vscode_count'] = len(result['vscode'])

# Cursor extensions
cursor = run('cursor --list-extensions 2>/dev/null')
if cursor:
    result['cursor'] = sorted(cursor.split('\n'))
    result['cursor_count'] = len(result['cursor'])

# Zed extensions
zed_ext_dir = os.path.expanduser('~/.config/zed/extensions')
if os.path.isdir(zed_ext_dir):
    exts = [d for d in os.listdir(zed_ext_dir) if os.path.isdir(os.path.join(zed_ext_dir, d)) and not d.startswith('.')]
    if exts:
        result['zed'] = sorted(exts)
        result['zed_count'] = len(exts)

print(json.dumps(result) if result else '{}')
" 2>/dev/null || echo '{}'
}

collect_toolchains() {
  python3 -c "
import subprocess, json, os, shutil

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

# Python: pip global packages
if shutil.which('pip3'):
    pip_out = run('pip3 list --format=json 2>/dev/null')
    if pip_out:
        try:
            pkgs = json.loads(pip_out)
            result['python_packages'] = [{'name': p['name'], 'version': p['version']} for p in pkgs]
            result['python_package_count'] = len(pkgs)
        except: pass
    result['python_version'] = run('python3 --version 2>/dev/null').replace('Python ', '')

# Rust: cargo-installed binaries
cargo_bin = os.path.expanduser('~/.cargo/bin')
if os.path.isdir(cargo_bin):
    bins = [f for f in os.listdir(cargo_bin) if os.path.isfile(os.path.join(cargo_bin, f)) and not f.startswith('.')]
    result['cargo_binaries'] = sorted(bins)
    result['cargo_binary_count'] = len(bins)
    result['rust_version'] = run('rustc --version 2>/dev/null').replace('rustc ', '')

# Go: installed binaries
go_bin = os.path.expanduser('~/go/bin')
if os.path.isdir(go_bin):
    bins = [f for f in os.listdir(go_bin) if os.path.isfile(os.path.join(go_bin, f))]
    result['go_binaries'] = sorted(bins)
    result['go_binary_count'] = len(bins)
    result['go_version'] = run('go version 2>/dev/null').split()[-2] if shutil.which('go') else ''

# Ruby: gem list
if shutil.which('gem'):
    gems = run('gem list --no-versions 2>/dev/null')
    if gems:
        result['ruby_gems'] = sorted(gems.split('\n'))
        result['ruby_gem_count'] = len(result['ruby_gems'])

print(json.dumps(result) if result else '{}')
" 2>/dev/null || echo '{}'
}

collect_certificates() {
  python3 -c "
import subprocess, json, os, platform

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {}

if platform.system() == 'Darwin':
    # Custom certs in system keychain
    certs = run('security find-certificate -a /Library/Keychains/System.keychain 2>/dev/null | grep -c \"labl\"')
    if certs and certs.isdigit(): result['system_keychain_certs'] = int(certs)

    # User-added trust overrides
    custom = run('security dump-trust-settings 2>/dev/null | grep -c \"Cert\"')
    if custom and custom.isdigit(): result['custom_trust_settings'] = int(custom)
else:
    # Linux CA bundle
    ca_dir = '/etc/ssl/certs'
    if os.path.isdir(ca_dir):
        result['ca_cert_count'] = len([f for f in os.listdir(ca_dir) if f.endswith('.pem') or f.endswith('.crt')])

    # Custom certs in /usr/local/share/ca-certificates
    custom_dir = '/usr/local/share/ca-certificates'
    if os.path.isdir(custom_dir):
        custom = [f for f in os.listdir(custom_dir) if f.endswith('.crt')]
        if custom:
            result['custom_certs'] = custom
            result['custom_cert_count'] = len(custom)

# Check for mkcert
import shutil
if shutil.which('mkcert'):
    result['mkcert_installed'] = True
    caroot = run('mkcert -CAROOT 2>/dev/null')
    if caroot and os.path.isdir(caroot):
        result['mkcert_ca_exists'] = True

print(json.dumps(result) if result else '{}')
" 2>/dev/null || echo '{}'
}

collect_orbstack() {
  if ! command -v orb &>/dev/null; then echo '{"installed": false}'; return; fi

  python3 -c "
import subprocess, json

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ''

result = {'installed': True}

# VM list with details
orb_json = run('orb list --format json 2>/dev/null')
if orb_json:
    try:
        vms = json.loads(orb_json)
        result['machines'] = []
        for vm in vms:
            machine = {
                'name': vm.get('name', ''),
                'state': vm.get('state', ''),
                'os': vm.get('os', ''),
                'arch': vm.get('arch', ''),
                'image': vm.get('image', ''),
            }
            # CPU and memory if available
            if 'cpu' in vm: machine['cpu'] = vm['cpu']
            if 'memory' in vm: machine['memory'] = vm['memory']
            if 'disk' in vm: machine['disk'] = vm['disk']
            result['machines'].append(machine)
        result['machine_count'] = len(result['machines'])
    except:
        orb_text = run('orb list 2>/dev/null')
        if orb_text: result['raw'] = orb_text

print(json.dumps(result))
" 2>/dev/null || echo '{"installed": true, "error": "collection failed"}'
}

collect_fonts() {
  if [[ "$OS" != "Darwin" ]]; then echo '[]'; return; fi
  python3 -c "
import os, json
font_dirs = [
    os.path.expanduser('~/Library/Fonts'),
    '/Library/Fonts',
    '/Library/Fonts/Nix Fonts',
]
fonts = set()
for d in font_dirs:
    if os.path.isdir(d):
        for f in os.listdir(d):
            if any(f.endswith(e) for e in ['.ttf', '.otf', '.ttc', '.dfont']):
                fonts.add(f.rsplit('.', 1)[0])
print(json.dumps(sorted(fonts)))
"
}

# Note: collect_docker, collect_orbstack, collect_ollama are defined above
# (comprehensive versions in the main collector section)

# ══════════════════════════════════════════════════════════════════════════
# Assemble full audit
# ══════════════════════════════════════════════════════════════════════════

echo "Auditing $HOSTNAME ($OS/$ARCH)..." >&2

AUDIT=$(python3 -c "
import json, sys

sections = {}
for line in sys.stdin:
    line = line.strip()
    if line.startswith('---SECTION:'):
        current = line.replace('---SECTION:', '').strip()
        sections[current] = ''
    elif 'current' in dir():
        sections[current] += line + '\n'

result = {}
for name, data in sections.items():
    try:
        result[name] = json.loads(data.strip())
    except:
        result[name] = data.strip()

print(json.dumps(result, indent=2))
" <<AUDIT_DATA
---SECTION: system
$(collect_system)
---SECTION: homebrew
$(collect_homebrew)
---SECTION: mas_apps
$(collect_mas)
---SECTION: applications
$(collect_applications)
---SECTION: macos_defaults
$(collect_macos_defaults)
---SECTION: dock_apps
$(collect_dock_apps)
---SECTION: cli_tools
$(collect_cli_tools)
---SECTION: node_globals
$(collect_node_globals)
---SECTION: services
$(collect_services)
---SECTION: git_config
$(collect_git_config)
---SECTION: ssh_keys
$(collect_ssh_keys)
---SECTION: fonts
$(collect_fonts)
---SECTION: docker
$(collect_docker)
---SECTION: orbstack
$(collect_orbstack)
---SECTION: nix
$(collect_nix_state)
---SECTION: ai_infrastructure
$(collect_ai_infrastructure)
---SECTION: security
$(collect_security_posture)
---SECTION: tailscale
$(collect_tailscale)
---SECTION: crontabs
$(collect_crontabs)
---SECTION: resource_usage
$(collect_resource_usage)
---SECTION: shell_env
$(collect_shell_env)
---SECTION: editor_extensions
$(collect_editor_extensions)
---SECTION: toolchains
$(collect_toolchains)
---SECTION: certificates
$(collect_certificates)
AUDIT_DATA
)

# ── Output based on mode ────────────────────────────────────────────────
case "$MODE" in
  --local)
    echo "$AUDIT"
    ;;
  --save)
    SAVE_DIR="$HOME/dotfiles-backups/audit"
    mkdir -p "$SAVE_DIR"
    echo "$AUDIT" > "$SAVE_DIR/${HOSTNAME}-$(date +%Y%m%d).json"
    echo "Saved to $SAVE_DIR/${HOSTNAME}-$(date +%Y%m%d).json" >&2
    ;;
  *)
    # Upload to config service
    CONFIG_URL=$(find_config_service)
    if [[ -n "$CONFIG_URL" ]]; then
      curl -sf -X POST "${CONFIG_URL}/api/audit/${HOSTNAME}" \
        -H "Content-Type: application/json" \
        -d "$AUDIT" --max-time 10 >/dev/null 2>&1 \
        && echo "Audit uploaded to config service" >&2 \
        || echo "Upload failed — printing locally" >&2
    else
      echo "Config service not reachable — printing audit" >&2
    fi
    echo "$AUDIT"
    ;;
esac
