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
type nrs               # should show: ~/dotfiles/scripts/rebuild.sh
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

> **Tip:** `./scripts/rebuild.sh` runs `audit-config-drift.sh` automatically as
> Step 2 and prompts before activating when **risky drift** (manual changes
> not in the flake) is detected. So you can use it both for first-time
> onboarding and for daily updates without worrying about silently losing
> manual customisations. The fleet-wide audit (`./scripts/device audit`)
> below is still recommended for the broader inventory + config-service flow.

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
| **npm config** | Global prefix/root health, including accidental `/nix/store` targets |
| **Services** | Homebrew services + launchd agents |
| **Git config** | Global git configuration |
| **SSH keys** | Key names (not the keys themselves) |
| **Fonts** | Installed font families |

> **Nix + mutable CLIs:** Node itself is provided by Nix/Home Manager. Mutable
> npm CLIs such as Codex use `~/.npm-global`; native user installers such as
> Claude Code use `~/.local/bin`. The development profile keeps both directories
> on `PATH`. Keep npm's prefix outside `/nix/store`; the audit's
> `npm_config.prefix_in_nix_store` and `global_root_in_nix_store` fields should
> stay `false`.

### Claude Code command is missing

Claude Code's native installer creates `~/.local/bin/claude`. If that executable
works by absolute path but `claude` is not found, verify that the development
profile still includes `~/.local/bin` in `home.sessionPath`, rebuild, and start a
fresh application or login shell. Long-running applications can inherit Home
Manager's session marker and retain the previous `PATH` in nested shells until
the application is restarted. The command is `claude`.

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

## Mac Studio Lima prerequisite

The `rouvens-mac-studio` nix-darwin configuration installs Lima from `nixpkgs`.
Its exact version is therefore pinned by the committed `flake.lock`, reviewed
with the rest of a dotfiles change, and included in the normal nix-darwin
generation rollback path. Lima is not managed through Homebrew.

Dotfiles owns only the native prerequisite:

- Lima runs on macOS and uses Apple Virtualization.framework when a workload
  selects the `vz` VM type.
- Dropbox sync, MLX/Ollama inference, and Tailscale remain native host services.
- Workload repositories own VM definitions, guest packages, startup policy,
  networks, credentials, and lifecycle.
- This repository must not introduce implicit host-directory mounts, SSH-agent
  forwarding, guest-to-host control credentials, or automatically started VMs.

### Version review and activation

Before activating a lock-file update on the Mac Studio:

1. Evaluate
   `.#darwinConfigurations.rouvens-mac-studio.pkgs.lima.version` before and
   after the update and record the version change in the PR.
2. Ensure every Darwin configuration evaluates and review the normal
   `rebuild.sh` package-closure diff.
3. Obtain owner approval because activation changes the live host.
4. After activation, verify `limactl --version`. Starting or modifying a VM is
   a separate workload-repository rollout.

The standard fleet audit reports only
`virtualization_prerequisites.lima.installed` and `.version`. It does not
enumerate VM names, source paths, mounts, credentials, or guest contents.

### Rollback and uninstall

- Roll back the package with the previous nix-darwin system generation
  (`sudo darwin-rebuild --rollback`). This does not change or delete guest data.
- To stop managing Lima, remove `pkgs.lima` from the Mac Studio configuration,
  review the diff, and rebuild. The executable leaves the managed system
  closure, while existing `~/.lima` state remains untouched.
- VM deletion is intentionally not part of dotfiles uninstall. The owning
  workload must first stop the VM, verify backup/recovery requirements, and
  explicitly remove its guest state.

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
A: No. The current config sets `cleanup = "none"` in `modules/darwin/homebrew.nix`, so brew bundle never auto-uninstalls anything — manually installed apps stay, and casks removed from the flake also stay on disk until you uninstall them yourself. `audit-config-drift.sh` flags any installed-but-not-declared casks so you can decide what to do.

**Q: Why is `cleanup = "none"` instead of `"uninstall"`?**
A: Workaround for a Homebrew change (2026-06): `brew bundle install --cleanup` now refuses to run without `--force` / `--force-cleanup` / `$HOMEBREW_ASK`. nix-darwin's activate script hardcodes the `--cleanup` flag and runs brew under `sudo --preserve-env=PATH ... env brew bundle`, which strips any env var we'd set. The upstream nix-darwin fix bumps the required nixpkgs from 26.05 → 26.11 (newer nix-darwin enforces version matching), so disabling cleanup is the smaller change. Revisit when ready for a combined `nixpkgs` + `nix-darwin` input bump.

**Q: What about macOS settings (dock, finder, etc.)?**
A: These *will* be overwritten to match the dotfiles config. `./scripts/rebuild.sh` mitigates this by running `audit-config-drift.sh` as a pre-flight step and prompting when risky drift is detected — so you get a chance to fold manual changes into the flake before they're overwritten. `nrs` runs that gate for you; `nrs-raw` and a direct `darwin-rebuild switch` skip it. You can always restore with `defaults import`.

**Q: Can I run the audit without the config service?**
A: Yes. Use `./scripts/device audit --local` to just print the JSON, or `--save` to write it to a file.

**Q: What if hostname doesn't match the flake?**
A: `nrs` (and `darwin-rebuild` under it) uses `$(hostname)` to pick the flake config. If your hostname is `Rs-MacBook-Air-M5` but the flake expects `m5-air`, the rebuild will fail. Either rename the host (`sudo scutil --set HostName m5-air` on macOS) or add the actual hostname to `flake.nix`.

**Q: How do I add a new machine to the flake?**
A: Add an entry in `flake.nix` under `darwinConfigurations` (Mac) or `nixosConfigurations` (Linux). Use an existing entry as template — pick a role and any extra modules. Then commit, push, and run `./scripts/device setup` on the new machine.

**Q: How do I add an app that has no Homebrew cask and isn't on the App Store?**
A: If the vendor ships a stable direct-download URL, install it from `postActivation` in the relevant profile. See the **Dia browser** installer in `modules/darwin/profiles/core.nix` for the reference pattern: guard on the installed `.app` so the download only runs once per machine, mount the DMG read-only with `hdiutil -nobrowse`, copy the app out with `ditto`, `chown` it to `config.system.primaryUser`, and clear the quarantine xattr. Two gotchas that will bite you: (1) `postActivation` runs under `set -e`, so wrap the whole thing as `install_foo || true` or a single failure aborts the entire `switch`; (2) the nixpkgs **GNU** `mktemp` is on the activation PATH and rejects a bare `-t foo` template — call the system `/usr/bin/mktemp` (and other system tools) by absolute path. For apps that need GUI auth and *can't* be scripted (e.g. ExpressVPN), fall back to a `[ -d /Applications/Foo.app ] || echo "[WARN] …"` reminder instead.
