# modules/darwin/fleet-launcher.nix
#
# ONE stable program for the fleet's scheduled jobs to start, so ONE optional
# Full Disk Access (FDA) grant per Mac covers all of them:
#
#   /usr/local/libexec/rh7-fleet-launcher audit    com.rh7.collector-runner
#                                                  (modules/home/profiles/fleet-audit.nix)
#   /usr/local/libexec/rh7-fleet-launcher restic   org.rh7.restic-backup
#                                                  (modules/darwin/restic-backup.nix)
#
# Imported by flake.nix's mkMac for EVERY Mac (the audit agent is on every Mac).
#
# WHY A LAUNCHER: macOS privacy protection (TCC) judges the program launchd
# starts. Without FDA a launchd job cannot read ~/Desktop, ~/Documents,
# ~/Downloads, ~/Pictures (Photos), ~/Movies, ~/Music, ~/Library/Messages,
# ~/Library/Mail, app containers or iCloud Drive. A script runs as its
# interpreter — a nix-store bash whose identity changes with every nixpkgs bump
# — so a grant has to land on a fixed binary: fleet-launcher.c, COPIED to that
# path, ad-hoc signed (hardened runtime) and only replaced when
# `launcherVersion` below changes, so a grant survives rebuilds and flake.lock
# bumps. It spawns the job as a child and waits, staying the responsible
# process; it takes only a job NAME (targets fixed in the C source) and
# rebuilds the environment, so nothing from a plist can steer what runs under
# the grant. Bumping launcherVersion invalidates every grant: say so in the PR.
#
# THE GRANT IS OPTIONAL, PER DEVICE. Without it:
#   - the audit's data_inventory reports the protected folders `not-inspected`
#     (and protected_access "denied"); everything else is collected as before;
#   - restic refuses an owner-approved protected folder up front
#     (skipped_paths reason permission-denied) instead of failing the run.
# To grant (once per Mac, needs an admin):
#   1. System Settings → Privacy & Security → Full Disk Access → "+" → ⇧⌘G →
#      /usr/local/libexec/rh7-fleet-launcher → Open, switch it on;
#   2. `launchctl kickstart -k gui/$(id -u)/com.rh7.collector-runner` — the next
#      audit reports data_inventory.protected_access "granted";
#      restic: `launchctl kickstart -k gui/$(id -u)/org.rh7.restic-backup`.
# Grant THAT file — not Terminal, not a wrapper script, not restic/bash. FDA lets
# it (and the job it starts) read everything the user can. Residual trust: the
# audit job runs the collector the runner pulls (sha256 + read-only scan +
# pinned ref gated), and the runner trusts the user's pin file and its cache —
# so a process that can already write as this user can influence what runs
# under the grant. That is the price of the opt-in.
#
# HISTORY: until 2026-11 the restic module installed its own
# /usr/local/libexec/rh7-restic-launcher. No Mac ever granted it FDA, so
# activation removes that file instead of keeping an alias.
{ lib, pkgs, ... }:

let
  # Bump to make activation replace the installed launcher (and invalidate any
  # FDA grant on it — say so in the PR that bumps it).
  launcherVersion = "1";
  launcherPath = "/usr/local/libexec/rh7-fleet-launcher";
  legacyLauncher = "/usr/local/libexec/rh7-restic-launcher";

  launcher = pkgs.runCommandCC "rh7-fleet-launcher" { } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -Werror -o $out/bin/rh7-fleet-launcher ${./fleet-launcher.c}
  '';

  # `rh7-fleet-launcher audit` target. The THIN runner is baked in by store
  # path (a user-writable ~/dotfiles copy must not be what runs under the
  # grant); the audit LOGIC it pulls stays central and gated (#83, #96).
  # Load-bearing PATH: the runner needs bash/curl/python3/shasum; the audit
  # it execs shells out to brew/docker/tailscale/mas.
  fleetAudit = pkgs.writeShellScriptBin "rh7-fleet-audit" ''
    export PATH=${lib.makeBinPath [ pkgs.bash pkgs.curl pkgs.python3 pkgs.coreutils ]}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
    exec ${pkgs.bash}/bin/bash ${../../scripts/collector-runner.sh} "$@"
  '';
in
{
  environment.systemPackages = [ fleetAudit ];

  # Copy, never symlink: TCC binds a grant to this file's code identity.
  system.activationScripts.postActivation.text = lib.mkAfter ''
    rh7_launcher=${launcherPath}
    if [ ! -x "$rh7_launcher" ] || [ "$(cat "$rh7_launcher.version" 2>/dev/null)" != ${launcherVersion} ]; then
      echo "installing $rh7_launcher (version ${launcherVersion})" >&2
      mkdir -p "$(dirname "$rh7_launcher")"
      install -m 0755 -o root -g wheel ${launcher}/bin/rh7-fleet-launcher "$rh7_launcher.new"
      /usr/bin/codesign --force --sign - --options runtime --identifier org.rh7.fleet-launcher "$rh7_launcher.new"
      mv -f "$rh7_launcher.new" "$rh7_launcher"
      echo ${launcherVersion} >"$rh7_launcher.version"
    fi
    if [ -e ${legacyLauncher} ]; then
      echo "removing superseded ${legacyLauncher} (now ${launcherPath} restic)" >&2
      rm -f ${legacyLauncher} ${legacyLauncher}.version
    fi
  '';
}
