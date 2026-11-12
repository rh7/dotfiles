# Device Management Guide

How to onboard, audit, and manage devices — from a brand new Mac to an existing machine with years of manual setup.

## Overview

There are two paths depending on whether the machine already has stuff on it:

```
New device (blank)                 Existing device (apps installed)
  │                                   │
  └─ scripts/setup.sh                 ├─ audit + checklist        ← discover first
     (Xcode CLI → hostname →          │   (Before migrating an existing Mac)
      official Nix → build →          ├─ fold kept apps into the flake (PR → merge)
      1Password → gh → Tailscale →    ├─ secrets recipient (needsSecrets hosts)
      register → daily audit)         └─ ./scripts/rebuild.sh     ← then deploy
```

**Rule: always audit existing machines before deploying.** This lets you review what's installed, decide what to keep, and add anything missing to the dotfiles before nix-darwin takes over.

Throughout, `$CS` is the config service. It runs on the Mac Studio,
`http://rouvens-mac-studio:3456`, reachable only over Tailscale. The scripts do
not hard-code one name: `audit-device.sh` / `collector-runner.sh` resolve it from
`$CONFIG_SERVICE_URL`, then a pin file (`/etc/rh7/config-service`, then
`~/.config/rh7/config-service`), then the fallbacks `rouvens-mac-studio`,
`Rouvens-Mac-Studio.local`, `100.100.241.110`, and check the answer really is
the config service.

```bash
CS=http://rouvens-mac-studio:3456
```

---

## Path A: Brand New Device (blank Mac)

### Prerequisites
- The device has internet access
- You can open a browser (for Tailscale / 1Password / GitHub auth)
- **A GUI session.** `setup.sh` installs Nix with the official installer
  (`sh <(curl -L https://nixos.org/nix/install) --daemon`). On macOS that must
  run from Terminal.app locally or via Screen Sharing — not over SSH; headless
  sessions block the `/etc/fstab` write the Nix APFS volume needs. The fleet does
  **not** use Determinate Nix; `setup.sh` warns if it finds it.
- The hostname you'll pick exists as a `darwinConfigurations` attr in
  `flake.nix` (otherwise setup skips the Nix build and tells you what to add).

### Step 1: Run setup

```bash
curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/setup.sh | bash
# or: git clone https://github.com/rh7/dotfiles.git ~/dotfiles && ~/dotfiles/scripts/setup.sh
```

`setup.sh` (8 steps): Xcode CLI tools → hostname (matched against the known
flake profiles) → official Nix (+ flakes and the macOS SSL cert in
`/etc/nix/nix.conf`) → clone `~/dotfiles`, generate the age key
(`~/.config/sops/age/keys.txt`) and SSH key, install Homebrew if missing, build
and activate the host's config → 1Password → `gh auth` → Tailscale → register
with the config service → install the daily audit schedule
(`collector-runner.sh --install`).

**Registration needs the tailnet at start.** `setup.sh` looks for the config
service once, before the Tailscale step. On a Mac that only joins the tailnet
during setup it prints *Config service not discovered — skipping registration*,
and the installed runner won't audit until the next day. Once Tailscale is up,
register immediately from the clone:

```bash
~/dotfiles/scripts/audit-device.sh --run   # audit + upload + register now
```

An audit from a device the registry doesn't know yet creates it with role
`unknown`, and later audits preserve that. So set the intended role for
**every** device registered this way (`workstation`, `personal`, …) —
`PATCH /api/devices/<hostname>` is admin-gated, so do it from an admin tailnet
identity:

```bash
curl -s -X PATCH -H 'content-type: application/json' \
  -d '{"role":"workstation"}' $CS/api/devices/<hostname>
```

**Secrets hosts:** a host with `needsSecrets = true` (the `mkMac` default)
cannot complete its first activation until its age key is a recipient of
`secrets/secrets.yaml`. With `fix/310-sops-onboarding`, `setup.sh` stops before
activation on such a host and prints the device's public key plus the exact
`sops-add-host.sh` command to run on an existing recipient — follow
[Secrets](#secrets-sops-nix), then re-run `setup.sh`. **Until that PR merges,
`setup.sh` does not stop:** it activates, treats the decryption failure as
non-fatal and still prints *Setup Complete*. Take the `Age key` it prints at
the end through the manual recipient step in [Secrets](#secrets-sops-nix),
then `~/dotfiles/scripts/rebuild.sh`. `Kassie-M5-Air13` (`needsSecrets = false`,
personal role) skips this.

### Step 2: Verify

Open a **new** terminal to get the full shell config, then:

```bash
type nrs                     # ~/dotfiles/scripts/rebuild.sh
~/dotfiles/scripts/device status   # device info, age key, config service + fleet overview
launchctl list | grep com.rh7.collector-runner   # daily audit scheduled
```

---

## Secrets (sops-nix)

Each host has its own age key at `~/.config/sops/age/keys.txt`;
`secrets/secrets.yaml` is encrypted to every recipient listed in `.sops.yaml`.
A new host can only be added by someone who can already decrypt — any current
recipient in `.sops.yaml`: `m5-air` (admin), the Mac Studio, `rouven-m5-pro` or
`thinkpad`. This flow arrives with **`fix/310-sops-onboarding`**
(`scripts/sops-add-host.sh` does not exist on `main` before that PR merges).

1. **On the device:** `~/dotfiles/scripts/setup-secrets.sh` (or `~/dotfiles/scripts/device secrets`).
   It generates the age key if missing, registers its public key with the
   config service, and verifies the device can decrypt `secrets/secrets.yaml`.
   If it cannot yet, it exits **non-zero** and prints the public key and the
   command to run next. It does not edit `.sops.yaml` itself.
2. **On an existing recipient** (any host listed above), in a branch/worktree
   of the dotfiles repo:

   ```bash
   ./scripts/sops-add-host.sh <hostname> <age1…public key printed by the device>
   ```

   It adds the key to `.sops.yaml` under the flake hostname, runs
   `sops updatekeys` on `secrets/secrets.yaml`, verifies the result, commits on
   a branch and opens a PR. If you omit the key it reads `age_public_key` from
   the config service registry and asks you to confirm it matches what the
   device printed (registration is unauthenticated, so never skip that check);
   non-interactive runs must pass the key.
3. **Merge** the PR.
4. **On the device:** `git -C ~/dotfiles pull --ff-only` (the merged
   re-encryption isn't in the local checkout yet), re-run
   `~/dotfiles/scripts/setup-secrets.sh` (it should now decrypt), then
   `~/dotfiles/scripts/rebuild.sh` (or re-run `setup.sh` on a fresh Mac).

**Until `fix/310-sops-onboarding` merges, don't run `setup-secrets.sh` /
`device secrets`.** On `main` it never runs `sops updatekeys`, reports success
regardless, and if it does manage to edit `.sops.yaml` it commits and pushes
that straight to `main` (rh-device-management#310). Do the recipient step by
hand on an existing recipient, in a branch/worktree:

1. On the device, make sure it has a key and print the public half (`setup.sh`
   generates one; on a Mac you haven't run it on, create it here):

   ```bash
   mkdir -p ~/.config/sops/age
   [ -f ~/.config/sops/age/keys.txt ] || \
     nix shell nixpkgs#age -c age-keygen -o ~/.config/sops/age/keys.txt
   chmod 600 ~/.config/sops/age/keys.txt
   nix shell nixpkgs#age -c age-keygen -y ~/.config/sops/age/keys.txt
   ```
2. In `.sops.yaml`, add `- &<hostname> <age1…>` under `keys:` and `*<hostname>`
   to the `age: [ … ]` list of the `secrets/secrets.yaml` creation rule.
3. `export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt` then
   `sops updatekeys secrets/secrets.yaml` — editing `.sops.yaml` alone does not
   re-encrypt anything.
4. Commit both files, PR, merge; then on the device
   `git -C ~/dotfiles pull --ff-only && ~/dotfiles/scripts/rebuild.sh`.

Manual `sops` on macOS needs the key path, because sops' macOS default is under
`~/Library/Application Support`:

```bash
export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt
sops secrets/secrets.yaml
```

Hosts with `needsSecrets = false` (today only `Kassie-M5-Air13`, personal role)
don't import sops-nix and skip this section entirely.

---

## Before migrating an existing Mac

Run through this before the first nix-darwin activation on a Mac that already
has apps, settings and data. `$CS` as above.

- [ ] **Fresh audit** uploaded today: `./scripts/device audit` (choose run) or
      `./scripts/audit-device.sh --run`; confirm with
      `curl -s $CS/api/audit/$(hostname -s)`.
- [ ] **Hostname == flake attr.** `hostname -s` must equal the
      `darwinConfigurations` attr exactly (e.g. `rouven-air-m3`; the Mac mini is
      `rouvens-mac-mini-m4` once `chore/326-315-flake-hygiene` merges). Set it
      with `sudo scutil --set HostName <name>`, and the same for
      `LocalHostName` and `ComputerName`.
- [ ] **Escrow single-copy secrets.** Record the FileVault recovery key in
      1Password by hand (no script covers it). Escrow the age key, SSH private
      keys, GPG secret keys + ownertrust and any high-value `.env` files with
      rh-device-management's `scripts/escrow-secrets-1password.sh` — dry-run by
      default, `--apply` to upload; needs an interactive `op` session, so run
      it yourself.
- [ ] **Time Machine backup** completed (plus `./scripts/device backup` for the
      Brewfile / dock / defaults snapshot).
- [ ] **Retirement verdict is ready:** `curl -s $CS/api/fleet/retirement/$(hostname -s)`
      returns `"ready": true` (`status` `ready` or `ready-with-warnings`, no
      critical blockers). Admin-gated — run it from an admin tailnet identity.
- [ ] **Adopt what you want to keep.** `curl -s $CS/api/audit/gaps/$(hostname -s)`:
      `present_unmanaged` lists apps from the managed-cask catalogue that are
      installed but not brew-declared; `unmanaged_casks` / `unmanaged_formulas`
      list Homebrew installs no profile declares. Apps outside the catalogue
      appear in neither — also go through the audit's `applications` list
      (`curl -s $CS/api/audit/$(hostname -s)`) and the drift audit's
      informational `·` lines (undeclared casks/apps) from
      `./scripts/audit-config-drift.sh`. Add the keepers to the right
      `modules/darwin/profiles/*.nix` (or the host's `configurations/macos/*.nix`),
      PR, merge.
- [ ] **Dock:** the workstation and personal roles set
      `system.defaults.dock.persistent-apps`, which replaces the **whole** Dock
      on activation. Anything not declared there disappears from it.
- [ ] **Secrets recipient added** for `needsSecrets` hosts — see
      [Secrets](#secrets-sops-nix); with `fix/310-sops-onboarding`,
      `./scripts/setup-secrets.sh` must report that it can decrypt (before it,
      use the manual recipient step there).
- [ ] **Activate with `./scripts/rebuild.sh`** (drift audit → build → `nvd`
      diff → confirm), not `nrs-raw` / a raw `darwin-rebuild switch`. With
      `fix/312-rebuild-merged-only` it only activates a clean `main` equal to
      `origin/main`; `--allow-unmerged` deliberately tests a branch.
- [ ] **Know the rollback:** `sudo darwin-rebuild --rollback` returns to the
      previous nix-darwin generation, but **Homebrew installs/upgrades and
      `defaults` writes are not rolled back**. Undo Homebrew changes by hand
      (`brew uninstall`, or reinstall an older version) or from Time Machine —
      the `device backup` Brewfile is an inventory, not a rollback: `brew
      bundle` neither removes new packages nor downgrades. `dock.plist` from the
      backup restores the Dock.

Homebrew `cleanup` stays `"none"` (see FAQ) until the drift audit covers
formulae (dotfiles#11), so activation never uninstalls anything.

---

## Path B: Existing Device (already has apps, settings, manual config)

### Why audit first?

When you rebuild for the first time on an existing machine, nix-darwin will:
- **Install** everything in the dotfiles that's missing
- **Keep** everything that's not in the dotfiles (`cleanup = "none"`)
- **Overwrite** macOS defaults (Dock layout — the whole Dock, Finder settings, keyboard repeat rate)

The audit lets you see what you have, compare it to what the dotfiles manage, and add anything missing before you deploy.

> **Tip:** `./scripts/rebuild.sh` runs `audit-config-drift.sh` automatically as
> Step 2 and prompts before activating when **risky drift** (manual changes
> not in the flake) is detected. The fleet-wide audit (`./scripts/device audit`)
> below is still the broader inventory + config-service flow.

### Step 1: Clone dotfiles (don't rebuild yet!)

Nix must already be installed — the official installer from a GUI session (see
Path A prerequisites).

```bash
git clone https://github.com/rh7/dotfiles.git ~/dotfiles
cd ~/dotfiles
```

### Step 2: Audit the device

```bash
# Interactive menu (run + upload, save, install schedule, …)
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

```bash
# What's on this device but not in dotfiles?
curl -s $CS/api/audit/gaps/$(hostname -s) | python3 -m json.tool
```

This shows:
- **`present_unmanaged`**: apps from the managed-cask catalogue that are installed (e.g. dragged into /Applications) but not brew-declared. Apps the catalogue doesn't know are not listed here — review the audit's `applications` list for those
- **`unmanaged_casks`** / **`unmanaged_formulas`**: installed via Homebrew but not in any dotfiles profile
- **`missing_from_device`**: in dotfiles and genuinely absent from the device

### Step 4: Compare with another device

```bash
# What's different between this device and the Mac Air?
curl -s $CS/api/audit/compare/$(hostname -s)/m5-air | python3 -m json.tool
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

Branch → PR → review → merge. Don't rebuild from the branch: `rebuild.sh`
activates merged `main` (with `fix/312-rebuild-merged-only`).

### Step 6: Checklist, backup and deploy

Work through [Before migrating an existing Mac](#before-migrating-an-existing-mac), then:

```bash
./scripts/device backup     # safety net
./scripts/rebuild.sh        # drift audit → build → nvd diff → confirm → switch
```

The backup is a reference snapshot, not a full rollback:
- `~/dotfiles-backups/<timestamp>/Brewfile` → inventory of what was installed (`brew bundle install --file=...` reinstalls missing entries; it does not remove or downgrade)
- `~/dotfiles-backups/<timestamp>/dock.plist` → `defaults import com.apple.dock ... && killall Dock`
- Shell configs, git config, etc.

### Step 7: Post-deploy

```bash
./scripts/audit-device.sh --run   # fresh audit + registration (keeps the device's assigned role)
./scripts/device status
```

If this device's first upload came from this onboarding (Step 2), the registry
created it with role `unknown`, and audits keep that role. Set the real one
(admin-gated, from an admin tailnet identity):

```bash
curl -s -X PATCH -H 'content-type: application/json' \
  -d '{"role":"workstation"}' $CS/api/devices/$(hostname -s)
```

Don't use `./scripts/device register` for this: it posts the hard-coded role
`workstation`, overwriting whatever role the registry holds for a
non-workstation host (`Kassie-M5-Air13`, the Studio). The audit path reads the
registered role back first and re-posts it.

The daily audit keeps the device's connectivity current (if `crontab -l` still
shows the legacy `auto-sync.sh` heartbeat cron, remove it with
`./scripts/device sync --uninstall`). With `chore/326-315-flake-hygiene` every
`mkMac` host declares the schedule via
`modules/home/profiles/fleet-audit.nix` (LaunchAgent `com.rh7.collector-runner`,
daily 08:17, started through `/usr/local/libexec/rh7-fleet-launcher audit` — see
[Full Disk Access](#full-disk-access-optional-per-mac)). On `main` today only the Studio imports it, so on **any** host
without a `com.rh7.collector-runner` agent (`launchctl list | grep collector`)
run `./scripts/collector-runner.sh --install` once (it also retires a legacy
`com.rh7.audit` agent). Non-nix devices without a clone enrol with
`curl -fsSL https://config.rh7labs.com/enroll | bash` (first audit + a direct daily
audit schedule; append `-s -- --status` to check only, `-s -- --role <role>`
to set one of `personal`/`developer`/`server`/`ai-inference`/`smart-home`/`mobile`
— that PATCH is admin-gated, so it only succeeds from an admin tailnet identity).

---

## Fixing issues on a device

Every action item on the dashboard (`GET /api/fleet/health`) names a **fix id**.
Run it **on the affected device** — `scripts/fleet-fix.sh` inspects that machine,
prints each finding as `OK` / `FIX` / `MANUAL` with the exact command, and changes
nothing unless you pass `--apply`:

```bash
curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/fleet-fix.sh | bash -s -- doctor
~/dotfiles/scripts/fleet-fix.sh <fix-id> [--apply]      # same thing from a clone
```

| Fix id | Dry-run shows | `--apply` does | Needs |
|---|---|---|---|
| `doctor` | this host's open action items → fix id, then each fix id's plan | nothing (read-only) | — |
| `backup` | at-risk repos (re-checked live) with the git commands to push every branch to `backup/<host>-<date>/*` — only on a remote `gh` confirms PRIVATE; public/unverifiable remotes get a `git bundle` to keep in iCloud/Dropbox instead; secrets to escrow; other unprotected paths; Time Machine + iCloud Desktop & Documents; restic status (configured? last snapshot age, failure reason, setup command — see [Restic backups](#restic-backups)) | nothing — report-only (never pushes, never runs `op`) | 1Password (escrow by hand) |
| `age-key` | whether `~/.config/sops/age/keys.txt` exists | runs `setup-secrets.sh` (generate + register); prints `sops-add-host.sh <host>` for an existing recipient | a clone, recipient host |
| `audit` | collector-runner schedule + last audit age | `collector-runner.sh --install` (reloads the nix-declared agent where one exists) + one gated audit | — |
| `firewall` | macOS application firewall state; `rouvens-mac-studio` is exempt (#93) unless `--force` | `sudo socketfilterfw --setglobalstate on`, re-verify; if the CLI no-ops (macOS 15+), opens System Settings and re-verifies | sudo, GUI |
| `filevault` | `fdesetup status` | `sudo fdesetup enable` (interactive) + reminder to store the recovery key in 1Password | sudo |
| `disk-encryption` | Linux: LUKS present? (macOS: same as `filevault`) | nothing — Linux can't encrypt in place; accepted-risk path is a dashboard Ack | — |
| `resources` | disk %, swap, nix store, dead store paths, brew cache, `~/Library/Caches`, docker | only when disk > 80%: `nix-collect-garbage --delete-older-than 30d` + `brew cleanup` (never user data) | — |
| `drift` | output of `audit-config-drift.sh` | nothing — fold drift into the flake or `rebuild.sh` | a clone |
| `fleet-update` | `state.json`, last 50 log lines, `rh7-fleet-update --dry-run` (only with cached sudo) | lets that dry-run prompt for sudo; nothing else | sudo |

`--apply` asks on the terminal before anything that needs sudo, a GUI or
1Password (`--yes` answers for you). Exit codes: `0` nothing to fix, `1` items
remain (or `--apply` incomplete), `2` error (e.g. config service unreachable),
`64` usage. It reuses `scripts/lib/config-service.sh` (pin → probe resolver),
`setup-secrets.sh` and `collector-runner.sh`; run clone-free it fetches the
resolver and `collector-runner.sh` from raw `main`. `age-key --apply` and `drift`
need a clone (they evaluate the flake / secrets file) and say so.

---

## Restic backups

Targeted, encrypted, versioned backups of the folders the fleet backup policy
cares about, instead of full-disk Time Machine. Hosts opt in with
`resticBackup = true` in their `mkMac` entry (`flake.nix`; pilot:
`rouven-m5-pro`), which enables `modules/darwin/restic-backup.nix`:

- a **user** LaunchAgent `org.rh7.restic-backup`, daily at 13:00 (on wake if
  the Mac slept), never at load;
- the command `rh7-restic-backup` (nixpkgs restic baked in; no Homebrew), plus
  `restic` on PATH for the restore commands `restore-hint` prints;
- destination: the restic REST server on the Studio
  (`rest:http://rouvens-mac-studio:8000/<host>/`, append-only, one private repo
  per host — rh-device-management). A NAS later = change `repositoryHost`.

Default paths: `~/.ssh ~/.config ~/.gnupg ~/code ~/Projects ~/localtesting
~/dotfiles` (missing ones are skipped; a symlinked one is backed up through
its target). Excluded: `node_modules`, `.venv`,
`venv`, `__pycache__`, `target`, `dist`, `build`, `.next`, `.cache`, `*.tmp`,
`.DS_Store`, `~/.config/**/Cache*`, CACHEDIR.TAG dirs, and every file over
100 MB (model weights). Override with `services.rh7.resticBackup.paths` /
`exclude` / `excludeLargerThan`.

**Enabling is safe before setup**: each run records `not-configured` until the
device has credentials. Setup, once per device:

```bash
# on the Studio (rh-device-management): prints rh7-restic:<host>:<password> once
scripts/restic-server-add-host.sh <host>
# on the device: paste the token (or pipe it: pbpaste | rh7-restic-backup setup)
rh7-restic-backup setup
# escrow the encryption key it generated — without it the snapshots are unreadable
~/rh-device-management/scripts/escrow-secrets-1password.sh --env ~/.config/rh7-restic/repo-password          # dry-run
~/rh-device-management/scripts/escrow-secrets-1password.sh --env ~/.config/rh7-restic/repo-password --apply
rh7-restic-backup run                # first backup now
```

`setup` refuses a token issued for another hostname (`--force` if the registry
name really differs), never overwrites an existing encryption key, and refuses to
re-init a repo the key does not open. Daily use: `rh7-restic-backup status`,
`snapshots`, `restore-hint` (prints the list/restore commands). Nothing on the
device ever forgets or prunes — the server is append-only; retention is a
server-side job.

Each run writes `~/.local/state/rh7-restic/status.json` (log: `backup.log` next
to it): `ok`, `failed` (`auth-failed`, `repo-locked`, `permission-denied`,
`offline`, `unknown`), `skipped` (`on-battery` below 30 %, `offline` when the
Studio is unreachable) or `not-configured`. The daily audit reports it as the
`restic` entry of `backup_posture.programmatic` (with the backed-up `paths`), so
the config service credits exactly those folders; `fleet-fix.sh backup` shows it.

**Owner-approved paths.** Folders the owner marks *Back up* in the dashboard's
data view (see [Data inventory](#data-inventory)) reach the device dynamically:
every run asks `GET /api/fleet/data/<host>/backup-paths` (10 s cap, the fleet's
one config-service resolver), validates each path on the device and adds the
survivors to the module paths — no rebuild. A path must be `~/…`, contain no
control characters or `.`/`..` segments, not be `~` itself, not be under
`~/Library/Caches`, `~/.Trash`, `~/Library/CloudStorage`,
`~/Library/Mobile Documents` or `~/Dropbox*` (case-insensitively — APFS is), must
exist, resolve inside the home and be readable by the job; trailing slashes are
ignored. Anything else is skipped and reported, never fatal. If the control
plane is unreachable the last good list
(`~/.local/state/rh7-restic/approved-paths.json`) is used. `status.json` carries
`approved_paths`, `skipped_paths` (`{path, reason}`) and `approved_source`
(`control-plane` / `cache` / `none`); `fleet-fix.sh backup` lists them.
The size cap still applies to approved folders: files over `excludeLargerThan`
(100 MB) stay out of every snapshot, so the inventory does not report such a
folder as restic-covered (status records the cap as `exclude_larger_than`).

**~/Desktop, ~/Documents, ~/Downloads are not in the defaults.** macOS privacy
protection (TCC) stops a launchd job from reading them (and iCloud Drive /
external volumes) without Full Disk Access; iCloud Desktop & Documents already
replicates the first two. The job runs through
`/usr/local/libexec/rh7-fleet-launcher restic`; to include a protected folder,
grant that launcher Full Disk Access ([below](#full-disk-access-optional-per-mac)),
then add the folder to `paths` or approve it on the dashboard. Without the
grant an approved protected folder is skipped up front (`permission-denied` in
`skipped_paths`) instead of failing the run; a protected path in `paths` still
fails the run as `permission-denied` and is left out of `paths`.

Changing the backup script: run `bash scripts/tests/restic-backup.test.sh`
(stubs; CI runs it) and `bash scripts/tests/restic-backup-e2e.sh` (real restic
and rest-server from the flake's nixpkgs on 127.0.0.1; needs nix).

---

## Data inventory

The daily audit's `data_inventory` section answers *what important data is on
this Mac that nothing backs up?* for the account it runs as. The config service
shows it per device (admin-gated) so the owner can decide per item: **Back up**
(added to that device's restic job on its next run, see above), **Ignore**, or
**Delete later** (a to-do — nothing is ever deleted automatically).

Items: each top-level home folder (not `~/Library`, `~/.Trash` or cloud roots),
Photos libraries, `~/Library/Messages`, `~/Library/Mail`, app data of 100 MB+
under Application Support / Containers / Group Containers, wallet data folders
(size only, never opened), and git repos with work that exists only here. Each
carries `category`, `size_bytes`, `files`, `newest_mtime`, `coverage`
(`icloud`, `dropbox`, `cloud-storage`, `git-remote`, restic with a snapshot
< 48 h, Time Machine backup < 48 h and the path not excluded — a backup only
counts for a folder that existed before it ran, and restic only for a folder
fully scanned and holding no file over its size cap) and `status`:
`covered`, `unprotected`, `reinstallable` (`~/.ollama`, toolchains, editor
extensions, caches, Dropbox's own `~/.dropbox` state, WhatsApp) or
`not-inspected`. Plus `largest_files`: the 20 largest files over 500 MB
(caches, cloud roots and Photos library internals skipped). Names and sizes
only, never contents.

The classification rules (`DATA_CLASS_RULES`, wallets, browsers) are one block
shared verbatim by `audit-device.sh` and `pre-wipe-check.sh`;
`scripts/tests/data-inventory.test.sh` fails if the copies drift.

Cost: one 90 s budget with a per-folder `du` cap; sizes are cached in
`~/.local/state/rh7-audit/data-inventory-cache.json` and reused for a week
unless the folder's mtime changed, so once warm a daily run spends seconds.
`budget_exhausted: true` means some sizes are missing or stale (they fill in
over the next runs). Photos libraries are always listed and count as covered
only when the iCloud account reports iCloud Photos on — otherwise
`unprotected`, note *iCloud Photos not confirmed*.

### Full Disk Access (optional, per Mac)

Without it the audit never opens macOS-protected folders (Desktop, Documents,
Downloads, Pictures/Photos, Movies, Music, Messages, Mail, app containers) —
they are reported `not-inspected` with no size, and
`data_inventory.protected_access` is `denied` (Desktop/Documents still show as
`covered` when iCloud Desktop & Documents is on). To let the scheduled audit
**and** restic see them, grant FDA once to the one fleet launcher both jobs run
through (`modules/darwin/fleet-launcher.nix`):

1. System Settings → Privacy & Security → Full Disk Access → `+` → ⇧⌘G →
   `/usr/local/libexec/rh7-fleet-launcher` → Open, switch it on.
2. `launchctl kickstart -k gui/$(id -u)/com.rh7.collector-runner` — the audit
   then reports `protected_access: "granted"` (restic:
   `launchctl kickstart -k gui/$(id -u)/org.rh7.restic-backup`).

Grant that file — not Terminal, not a wrapper script, not restic/bash: it is a
small fixed binary copied there once and only replaced when the module bumps
its version, so the grant survives rebuilds. It accepts only a job name
(`audit`, `restic`) and rebuilds the environment, so a plist cannot steer what
runs under the grant; the module header lists the residual trust.
`--include-protected` on a one-off interactive audit still works without the
grant (macOS may prompt; `protected_access` is then `partial`).

---

## Device CLI Reference

All commands are run from `~/dotfiles`:

```bash
./scripts/device <command>
```

| Command | Purpose |
|---------|---------|
| `setup` | Backup → rebuild (via `rebuild.sh`) → `setup-secrets.sh` → register. Assumes Nix is installed; for a blank Mac use `scripts/setup.sh`. It rebuilds **before** the secrets step, so on a `needsSecrets` host use it only once the host is already a recipient (see [Secrets](#secrets-sops-nix)) — and not at all before `fix/310-sops-onboarding` merges |
| `update` | Rebuild via `rebuild.sh` → register |
| `status` | Device info (Nix, Tailscale, age key) + config service + fleet overview |
| `audit` | Interactive audit menu |
| `audit --run` | Audit + upload (non-interactive) |
| `audit --local` | Audit only, print JSON |
| `audit --save` | Save audit to `~/dotfiles-backups/audit/` |
| `backup` | Backup current system state (Homebrew, dock, defaults, dotfiles) |
| `backup /path` | Backup to custom location |
| `register` | `POST /api/devices/register` with OS, Tailscale IP, age pubkey. **Caveat:** hard-codes role `workstation` — `setup` and `update` call it too, so on non-workstation hosts (`Kassie-M5-Air13`, the Studio) prefer `rebuild.sh` + `audit-device.sh --run` |
| `secrets` | Run `setup-secrets.sh` — only after `fix/310-sops-onboarding` merges |
| `sync` / `sync --install` / `sync --uninstall` | Legacy auto-sync cron (every 30 min). Still runs `heartbeat.sh`, which posts role `workstation` — uninstall it; the daily audit replaces it |
| `fleet` | Fleet-wide status from the config service (`--detail`, `--stale`) |
| `heartbeat` | Retired — prints a warning and runs `audit-device.sh` instead |

On `main` today, `device setup` pulls, runs `nix flake update`, then rebuilds;
`device update` pulls and rebuilds, and only `device update --full` also runs
`nix flake update`. With `fix/312-rebuild-merged-only` neither command runs
`git pull` or `nix flake update` (`rebuild.sh` syncs to `origin/main` itself),
and `update --full` is removed: bump inputs on a branch with
`nix flake update --flake ~/dotfiles`, PR, merge, then `device update`. (The
`nup` alias currently expands to `nix flake update ~/dotfiles`, which newer Nix
reads as an input name and silently updates nothing.)

---

## Config Service API (for reviewing audits)

The config service runs on the Mac Studio (`rouvens-mac-studio:3456`, tailnet only).

| Endpoint | Purpose |
|----------|---------|
| `GET /api/audit` | All latest audits |
| `GET /api/audit/:hostname` | Latest audit for one device |
| `GET /api/audit/compare/:a/:b` | Diff two devices |
| `GET /api/audit/gaps/:hostname` | `present_unmanaged`, unmanaged casks/formulas, `missing_from_device` |
| `GET /api/fleet/overview` | Fleet status (online/stale/offline, from audit `last_seen`) |
| `GET /api/fleet/health` | Fleet-wide action items |
| `GET /api/fleet/retirement/:hostname` | Safe-to-wipe verdict (admin-gated) |
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
CS=http://rouvens-mac-studio:3456

# 1. Clone dotfiles (Nix already installed: official installer, GUI session)
git clone https://github.com/rh7/dotfiles.git ~/dotfiles
cd ~/dotfiles

# 2. Audit (non-destructive, just collects info) — choose "run" to upload
./scripts/device audit

# 3. Check gaps (from any machine on the tailnet)
curl -s $CS/api/audit/gaps/$(hostname -s) | python3 -m json.tool

# 4. Adopt keepers from present_unmanaged / unmanaged_casks / the audit's
#    applications list into profiles
#    → branch → PR → merge

# 5. Compare with a known-good device
curl -s $CS/api/audit/compare/$(hostname -s)/m5-air | python3 -m json.tool

# 6. Work through "Before migrating an existing Mac" (escrow, Time Machine,
#    retirement verdict, secrets recipient), then deploy
./scripts/device backup     # safety net
# needsSecrets hosts: recipient added first (see Secrets; once fix/310 merges,
# ./scripts/setup-secrets.sh confirms the device can decrypt)
./scripts/rebuild.sh        # drift audit → build → nvd diff → confirm → switch

# 7. Daily audit schedule (until fleet-audit.nix covers this host)
./scripts/collector-runner.sh --install
```

---

## FAQ

**Q: Will nix-darwin delete my manually installed apps?**
A: No. The current config sets `cleanup = "none"` in `modules/darwin/homebrew.nix`, so brew bundle never auto-uninstalls anything — manually installed apps stay, and casks removed from the flake also stay on disk until you uninstall them yourself. `audit-config-drift.sh` flags any installed-but-not-declared casks so you can decide what to do.

**Q: Why is `cleanup = "none"` instead of `"uninstall"`?**
A: Workaround for a Homebrew change (2026-06): `brew bundle install --cleanup` now refuses to run without `--force` / `--force-cleanup` / `$HOMEBREW_ASK`. nix-darwin's activate script hardcodes the `--cleanup` flag and runs brew under `sudo --preserve-env=PATH ... env brew bundle`, which strips any env var we'd set. The upstream nix-darwin fix bumps the required nixpkgs from 26.05 → 26.11 (newer nix-darwin enforces version matching), so disabling cleanup is the smaller change. Revisit when ready for a combined `nixpkgs` + `nix-darwin` input bump — and not before `audit-config-drift.sh` covers Homebrew formulae (dotfiles#11): the drift gate `rebuild.sh` runs before activation checks casks only, so turning cleanup on would uninstall undeclared formulae with no pre-activation warning (the fleet audit's `unmanaged_formulas` lists them, but nothing gates activation on it).

**Q: What about macOS settings (dock, finder, etc.)?**
A: These *will* be overwritten to match the dotfiles config. `./scripts/rebuild.sh` mitigates this by running `audit-config-drift.sh` as a pre-flight step and prompting when risky drift is detected — so you get a chance to fold manual changes into the flake before they're overwritten. `nrs` runs that gate for you; `nrs-raw` and a direct `darwin-rebuild switch` skip it. You can always restore with `defaults import`.

**Q: Can I run the audit without the config service?**
A: Yes. Use `./scripts/device audit --local` to just print the JSON, or `--save` to write it to a file.

**Q: What if hostname doesn't match the flake?**
A: `rebuild.sh` (`nrs`) uses `hostname -s` to pick the flake config. If your hostname is `Rs-MacBook-Air-M5` but the flake expects `m5-air`, the rebuild will fail. Either rename the host (`sudo scutil --set HostName m5-air`, likewise `LocalHostName` and `ComputerName`) or add the actual hostname to `flake.nix`. Don't activate a Mac under a *different* host's attr — `networking.hostName` would rename it and split its device identity in the fleet registry.

**Q: How do I add a new machine to the flake?**
A: Add an entry in `flake.nix` under `darwinConfigurations` (Mac) or `nixosConfigurations` (Linux). Use an existing entry as template — pick a role and any extra modules; set `needsSecrets = false` for a Mac that should not get sops-nix. Branch → PR → merge, then run `scripts/setup.sh` on the new machine (and, for a secrets host, the [Secrets](#secrets-sops-nix) flow).

**Q: How do I add an app that has no Homebrew cask and isn't on the App Store?**
A: If the vendor ships a stable direct-download URL, install it from `postActivation` in the relevant profile. See the **Dia browser** installer in `modules/darwin/profiles/core.nix` for the reference pattern: guard on the installed `.app` so the download only runs once per machine, mount the DMG read-only with `hdiutil -nobrowse`, copy the app out with `ditto`, `chown` it to `config.system.primaryUser`, and clear the quarantine xattr. Two gotchas that will bite you: (1) `postActivation` runs under `set -e`, so wrap the whole thing as `install_foo || true` or a single failure aborts the entire `switch`; (2) the nixpkgs **GNU** `mktemp` is on the activation PATH and rejects a bare `-t foo` template — call the system `/usr/bin/mktemp` (and other system tools) by absolute path. For apps that need GUI auth and *can't* be scripted (e.g. ExpressVPN), fall back to a `[ -d /Applications/Foo.app ] || echo "[WARN] …"` reminder instead.

---

## Before wiping a Mac

`scripts/pre-wipe-check.sh` is a read-only pre-erase report. Run it on the Mac
you are about to wipe; you don't need a clone:

```bash
curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/pre-wipe-check.sh | bash
# no macOS privacy prompts (skips Desktop/Documents/Downloads/Pictures, iCloud Drive, containers, Mail, Messages):
curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/pre-wipe-check.sh | bash -s -- --skip-protected
```

It prints a markdown report and saves it to `~/pre-wipe-<host>-<YYYYmmdd-HHMM>.md`:
RED (lost on erase), AMBER (check by hand) and GREEN counts, then a
`safe to wipe: no / check / likely` line. The report covers:

- the control plane's `GET /api/fleet/retirement/<host>` verdict (admin-gated)
- every app and where to reinstall it from, plus a Brewfile and `mas` ids
- data that exists only on this Mac: home folders (top 25 by size), Photos,
  Messages, app data, VMs, git repos with unpushed work, and secrets (names only)
- crypto wallets: Exodus, Electrum, Ledger Live, MyCrypto, KeepKey, Cypherock,
  Atomic Wallet, and MetaMask/Phantom/Coinbase Wallet/Rabby browser extensions —
  presence and folder size only, wallet files are never opened. Any wallet is
  RED until its seed phrase / recovery is confirmed stored offline
- data cleanup candidates, sizes only (nothing is deleted): caches, Xcode
  DerivedData/Archives/DeviceSupport/simulators, conda envs, `~/.cargo`,
  `~/.rustup`, `node_modules`, Docker/OrbStack, Downloads, Trash, Mail
  downloads, old installers over 200 MB, duplicate Photos libraries — each
  `SAFE-TO-DELETE`, `REVIEW` or `KEEP`. iPhone/iPad backups are AMBER, not
  cleanup: they may be the only copy of an old phone
- the 30 largest files over 500 MB (`~/Library/Caches`, cloud folders and
  Photos libraries skipped), as paths relative to the home folder
- Time Machine, Find My and browser sync status
- a backup plan: RED/AMBER totals and the exact commands for an encrypted
  restic archive to the Studio (same server as [Restic backups](#restic-backups))
  or a `ditto` copy to an external disk — printed, never run
- an ordered checklist, ending with `DELETE /api/devices/<host>`

Exit status is `0` (no RED), `1` (RED present) or `2` (script error). It never
uploads anything or modifies user data, and uses no sudo except in
`--all-users` mode below. The report is the only file the script writes,
though Homebrew and gpg may refresh their own caches when it queries them. To
escrow secrets, use `scripts/escrow-secrets-1password.sh` in
rh7/rh-device-management.

### A Mac with several accounts (`--all-users`)

For a shared Mac (e.g. one an admin set up but someone else mainly uses), run
it once from **your** admin account instead of logging in as each person:

```bash
sudo ~/dotfiles/scripts/pre-wipe-check.sh --all-users
# without a dotfiles clone:
curl -fsSL https://raw.githubusercontent.com/rh7/dotfiles/main/scripts/pre-wipe-check.sh -o /tmp/pre-wipe-check.sh
sudo bash /tmp/pre-wipe-check.sh --all-users
```

It lists every real account (UID ≥ 501, not hidden, home under `/Users`) with
admin flag, home size and last login, then re-runs itself **as each account**
(`sudo -u <account> -H`, script text on stdin) so that account's iCloud,
browser and app settings are the ones read. The system-wide parts (apps in
`/Applications`, Homebrew, control plane, Time Machine) run once, as you; each
account part also lists its own `~/Applications` and npm/pipx/uv tools. One
combined report, with a section per account, is written to **your** home
(owned by you, mode 600). An account whose check fails is RED in the verdict,
never silently skipped.

**Full Disk Access is required** (unless you pass `--skip-protected`, which
reads no protected location in any account). Without it macOS hides other
accounts' Mail, Messages, Safari and app data even from root, so the script
probes those folders first and refuses to run (exit 2) with these steps:

1. System Settings → Privacy & Security → **Full Disk Access**
   (`open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"`).
2. `+`, authenticate, add your terminal app (Terminal is in
   `/System/Applications/Utilities`; iTerm/Ghostty in `/Applications`).
3. Switch it on, **quit the terminal (⌘Q) and reopen it**, re-run.
4. Optionally switch it off again afterwards.

What still needs the account's owner in person — the report cannot do or
verify these:

- **Apple ID**: signing out of iCloud (turns off Find My / Activation Lock) and
  App Store / Music deauthorization happen inside their session, with their
  Apple ID password.
- **Crypto wallet seeds**: they confirm each wallet's seed phrase / recovery
  is stored offline. The script only sees that wallet data exists.
- **Browser sync**: confirming Chrome/Brave/Arc/Firefox profiles are signed in
  *and* syncing, and signing in again after the wipe.
- **1Password** (and other password managers): their account, Secret Key and
  any local-only vaults.
