#!/usr/bin/env bash
# Lightweight device audit — no Xcode, no privacy prompts.
# Just captures installed apps and dock. Safe for non-technical users.
#
# Usage: curl -fsSL config.rh7labs.com/scan | bash

HOST=$(hostname -s)
echo "Scanning $HOST..."

python3 << 'PYEOF'
import os, json, subprocess, plistlib

host = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip()

# Installed apps
apps = sorted([a for a in os.listdir("/Applications") if a.endswith(".app")])

# Dock apps
dock = []
try:
    r = subprocess.run(["defaults", "export", "com.apple.dock", "-"], capture_output=True)
    plist = plistlib.loads(r.stdout)
    dock = [{"label": i.get("tile-data", {}).get("file-label", "")}
            for i in plist.get("persistent-apps", [])
            if i.get("tile-data", {}).get("file-label")]
except:
    pass

data = json.dumps({
    "applications": apps,
    "dock_apps": dock,
    "system": {"hostname": host, "os": "Darwin", "arch": os.uname().machine},
})

# Try to upload
uploaded = False
for server in ["Rouvens-Mac-Studio.local:3456", "rouvens-mac-studio-1:3456", "100.100.241.110:3456"]:
    try:
        import urllib.request
        req = urllib.request.Request(
            f"http://{server}/api/audit/{host}",
            data=data.encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=5)
        print(f"Uploaded to fleet ({server})")
        uploaded = True
        break
    except:
        continue

if not uploaded:
    print("Could not reach config service — printing locally:")

print(f"\nApps ({len(apps)}):")
for a in apps:
    print(f"  {a}")
print(f"\nDock ({len(dock)}):")
for d in dock:
    print(f"  {d['label']}")
PYEOF
