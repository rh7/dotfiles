# Device Management Guide

How to onboard, audit, and manage devices — from a brand new Mac to an existing machine with years of manual setup.

## Overview

There are two paths depending on whether the machine already has stuff on it:

```
New device (blank)              Existing device (apps installed)
  │                                │
  └─ ./scripts/device setup       └─ ./scripts/device audit     ← discover first
     (backup → rebuild →              │
      secrets → register)            Review gaps & compare
                                      │
                                     ./scripts/device setup      ← then deploy
                                     (backup → rebuild →
                                      secrets → register)
```

**Rule: always audit existing machines before deploying.** This lets you review what's installed, decide what to keep, and add anything missing to the dotfiles before nix-darwin takes over.

---

## Path A: Brand New Device (blank Mac or Linux)

### Prerequisites
- The device has internet access
- You can open a browser (for Tailscale auth)

### Step 1: Bootstrap

```bash
# Clone dotfiles
git clone https://github.com/rh7/dotfiles.git ~/dotfiles
cd ~/dotfiles

# Full setup: installs Nix, rebuilds system, sets up secrets, registers with config service
./scripts/device setup
```

That's it. The setup script handles everything:
1. Backs up current system state (even on a blank machine, for reference)
2. Pulls latest dotfiles
3. Updates flake inputs
4. Rebuilds with nix-darwin (macOS) or nixos-rebuild (Linux)
5. Runs `setup-secrets.sh` (generates age key, encrypts secrets)
6. Registers with the config service (if reachable)

### Step 2: Post-setup

```bash
# Install the heartbeat cron (reports to config service every 5 min)
./scripts/device heartbeat --install

# Open a NEW terminal to get the full shell config
```

### Step 3: Verify

```bash
nrs                    # should rebuild without errors
type nrs               # should show: sudo darwin-rebuild switch --flake ~/dotfiles#$(hostname)
./scripts/device status # should show device info + fleet overview
```

---

## Path B: Existing Device (already has apps, settings, manual config)

### Why audit first?

When you run `nrs` for the first time on an existing machine, nix-darwin will:
- **Install** everything in the dotfiles that's missing
- **Keep** everything that's not in the dotfiles (unless `cleanup = "zap"`)
- **Overwrite** macOS defaults (dock layout, finder settings, keyboard repeat rate)

The audit lets you see what you have, compare it to what the dotfiles manage, and add anything missing before you deploy.

### Step 1: Clone dotfiles (don't rebuild yet!)

```bash
git clone https://github.com/rh7/dotfiles.git ~/dotfiles
cd ~/dotfiles
```

### Step 2: Audit the device

```bash
# Collect full inventory and upload to config service
./scripts/device audit

# Or just print locally (no config service needed)
./scripts/device audit --local | python3 -m json.tool

# Or save to a file for reference
./scripts/device audit --save
```

The audit collects:
| Category | What's captured |
|----------|----------------|
| **Homebrew** | All formulas, casks, taps |
| **Mac App Store** | All installed apps with IDs |
| **Applications** | Everything in /Applications |
| **macOS defaults** | Dock, Finder, keyboard, trackpad, security |
| **Dock apps** | Current dock order and apps |
| **CLI tools** | Which tools are in PATH (git, node, docker, etc.) |
| **Node globals** | Globally installed npm packages |
| **Services** | Homebrew services + launchd agents |
| **Git config** | Global git configuration |
| **SSH keys** | Key names (not the keys themselves) |
| **Fonts** | Installed font families |

### Step 3: Review gaps

If the config service is running (on the Mac Studio), check what's installed but not managed:

```bash
# What's on this device but not in dotfiles?
curl -s http://rouvens-mac-studio-1:3456/api/audit/gaps/$(hostname) | python3 -m json.tool
```

This shows:
- **Unmanaged casks**: installed via Homebrew but not in any dotfiles profile
- **Unmanaged formulas**: same for CLI tools
- **Missing from device**: in dotfiles but not installed yet

### Step 4: Compare with another device

```bash
# What's different between this device and the Mac Air?
curl -s http://rouvens-mac-studio-1:3456/api/audit/compare/$(hostname)/m5-air | python3 -m json.tool
```

Shows side-by-side differences in:
- Homebrew casks and formulas
- Applications
- CLI tools
- macOS defaults (which settings differ)
- Dock app order

### Step 5: Update dotfiles (if needed)

Based on the gap analysis, add any apps you want to keep to the appropriate profile:

| App type | Where to add |
|----------|-------------|
| GUI app for all Macs | `modules/darwin/profiles/` (pick the right category) |
| GUI app for one machine | `configurations/macos/<machine>.nix` |
| CLI tool for all machines | `modules/common.nix` |
| Dev tool | `modules/home/profiles/development.nix` |
| NixOS GUI app | `modules/nixos/profiles/` |

Commit and push after adding.

### Step 6: Backup and deploy

```bash
# Backup current state (just in case)
./scripts/device backup

# Now deploy
./scripts/device setup
```

The backup captures everything needed to restore if something goes wrong:
- `~/dotfiles-backups/<timestamp>/Brewfile` → `brew bundle install --file=...`
- `~/dotfiles-backups/<timestamp>/dock.plist` → `defaults import com.apple.dock ... && killall Dock`
- Shell configs, git config, etc.

### Step 7: Post-deploy

```bash
# Install heartbeat
./scripts/device heartbeat --install

# Verify
./scripts/device status
```

---

## Device CLI Reference

All commands are run from `~/dotfiles`:

```bash
./scripts/device <command>
```

| Command | Purpose |
|---------|---------|
| `setup` | First-time: backup → rebuild → secrets → register |
| `update` | Daily: pull → rebuild → heartbeat |
| `update --full` | Weekly: pull → flake update → rebuild → heartbeat |
| `status` | Show device info + fleet overview |
| `audit` | Collect inventory, upload to config service |
| `audit --local` | Audit only, print JSON |
| `audit --save` | Save audit to ~/dotfiles-backups/audit/ |
| `backup` | Backup current system state |
| `backup /path` | Backup to custom location |
| `register` | Register/heartbeat with config service |
| `heartbeat` | Send one heartbeat |
| `heartbeat --install` | Install 5-minute cron heartbeat |
| `heartbeat --uninstall` | Remove cron heartbeat |
| `secrets` | Setup age key and encrypt secrets |

---

## Config Service API (for reviewing audits)

The config service runs on the Mac Studio (`rouvens-mac-studio-1:3456`).

| Endpoint | Purpose |
|----------|---------|
| `GET /api/audit` | All latest audits |
| `GET /api/audit/:hostname` | Latest audit for one device |
| `GET /api/audit/compare/:a/:b` | Diff two devices |
| `GET /api/audit/gaps/:hostname` | What's installed but not in dotfiles |
| `GET /api/fleet/overview` | Fleet status (online/stale/offline) |
| `GET /api/system/info` | Live Mac Studio system stats |

---

## Typical Workflow for Onboarding an Existing Mac

```bash
# 1. Clone dotfiles
git clone https://github.com/rh7/dotfiles.git ~/dotfiles
cd ~/dotfiles

# 2. Audit (non-destructive, just collects info)
./scripts/device audit

# 3. Check gaps (from any machine with curl)
curl -s http://rouvens-mac-studio-1:3456/api/audit/gaps/$(hostname) | python3 -m json.tool

# 4. Review the unmanaged_casks list
#    → Add any you want to keep to the dotfiles profiles
#    → Commit and push

# 5. Compare with a known-good device
curl -s http://rouvens-mac-studio-1:3456/api/audit/compare/$(hostname)/m5-air | python3 -m json.tool

# 6. When satisfied, deploy
./scripts/device backup    # safety net
./scripts/device setup     # rebuild + secrets + register

# 7. Post-setup
./scripts/device heartbeat --install
```

---

## FAQ

**Q: Will nix-darwin delete my manually installed apps?**
A: No, not with the current config (`cleanup = "uninstall"`). Only apps that were *previously managed by Homebrew through the dotfiles* and then removed from the dotfiles will be uninstalled. Your manually installed apps are untouched.

**Q: What about macOS settings (dock, finder, etc.)?**
A: These *will* be overwritten to match the dotfiles config. That's why we audit and backup first — you can always restore with `defaults import`.

**Q: Can I run the audit without the config service?**
A: Yes. Use `./scripts/device audit --local` to just print the JSON, or `--save` to write it to a file.

**Q: What if hostname doesn't match the flake?**
A: `nrs` uses `$(hostname)` to pick the flake config. If your hostname is `Rs-MacBook-Air-M5` but the flake expects `m5-air`, the rebuild will fail. Either rename the host (`sudo scutil --set HostName m5-air` on macOS) or add the actual hostname to `flake.nix`.

**Q: How do I add a new machine to the flake?**
A: Add an entry in `flake.nix` under `darwinConfigurations` (Mac) or `nixosConfigurations` (Linux). Use an existing entry as template — pick a role and any extra modules. Then commit, push, and run `./scripts/device setup` on the new machine.
