# modules/darwin/restic-backup.nix
#
# Targeted, encrypted, versioned backups of the folders the fleet backup policy
# cares about (rh-device-management src/backup-policy.ts, developer
# workstation) — instead of full-disk Time Machine. Destination: the restic
# REST server on the Mac Studio (rh-device-management, append-only,
# --private-repos: one repo per host, path == REST user == hostname).
# Moving to a NAS later = change `repositoryHost`/`port`.
#
# WHAT IT IS: a USER LaunchAgent, org.rh7.restic-backup, in the primary user's
# ~/Library/LaunchAgents. User, not root: root gets no extra macOS privacy (TCC)
# access and would own the user's state files. Daily at hour:minute (default
# 13:00 — laptops are usually awake; if asleep, launchd runs it on wake),
# never at load. It runs scripts/restic-backup.sh through the wrapper
# `rh7-restic-backup` (in /run/current-system/sw/bin), which bakes in nixpkgs
# restic, jq and curl by store path — no Homebrew dependency.
#
# SAFE TO ENABLE BEFORE SETUP: until `rh7-restic-backup setup` has stored the
# server token and generated the encryption key, every run is a no-op that
# records last_result=not-configured in ~/.local/state/rh7-restic/status.json
# (the audit reports it, the config service sees "restic present, not
# configured"). So the nightly fleet-update applying this is harmless.
#
# Skips (and records why) on battery below 30 % and when the server is
# unreachable. Never forgets/prunes — the server is append-only.
#
# SETUP (once per device, as the user):
#   on the Studio:  scripts/restic-server-add-host.sh <hostname>   -> token
#   on the device:  rh7-restic-backup setup      # paste the token
#                   ~/rh-device-management/scripts/escrow-secrets-1password.sh \
#                     --env ~/.config/rh7-restic/repo-password --apply
#
# PROTECTED FOLDERS (TCC) — why ~/Desktop, ~/Documents, ~/Downloads are NOT in
# the defaults: macOS privacy protection judges the program a launchd job
# starts, and without Full Disk Access (FDA) it cannot read those folders,
# iCloud Drive or external volumes — restic gets EPERM ("operation not
# permitted"). iCloud Desktop & Documents already replicates those two folders.
# The job runs through the fleet's ONE launcher,
# `/usr/local/libexec/rh7-fleet-launcher restic` (modules/darwin/fleet-launcher.nix),
# so the optional per-Mac FDA grant described there covers this job AND the
# daily audit. With the grant, add a protected path to `paths` or approve it on
# the dashboard; without it an approved protected folder is skipped up front
# (skipped_paths: permission-denied) rather than failing the run.
#
# OWNER-APPROVED PATHS: each run also fetches the paths the owner marked
# "back up" in the control plane's data inventory
# (GET /api/fleet/data/<host>/backup-paths), validates them on the device and
# adds them to `paths` — see scripts/restic-backup.sh "APPROVED PATHS". The
# wrapper therefore ships restic-backup.sh together with the config-service
# resolver it loads (scripts/lib/config-service.sh + collector-runner.sh).
#
# WHY THE PLIST POINTS AT FIXED PATHS: nix-darwin reloads a user agent whose
# plist changed, killing a backup in flight. Paths, excludes and tools live in
# the wrapper behind the stable launcher, so routine changes never touch the
# plist; only schedule changes do.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.rh7.resticBackup;

  # Installed by modules/darwin/fleet-launcher.nix (imported for every Mac).
  launcherPath = "/usr/local/libexec/rh7-fleet-launcher";

  # restic-backup.sh + the config-service resolver it loads for the approved
  # paths, in the scripts/ layout it expects.
  scripts = pkgs.runCommand "rh7-restic-scripts" { } ''
    mkdir -p $out/scripts/lib
    cp ${../../scripts/restic-backup.sh} $out/scripts/restic-backup.sh
    cp ${../../scripts/collector-runner.sh} $out/scripts/collector-runner.sh
    cp ${../../scripts/lib/config-service.sh} $out/scripts/lib/config-service.sh
  '';

  runner = pkgs.writeShellScriptBin "rh7-restic-backup" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.jq pkgs.curl pkgs.gnugrep pkgs.gnused ]}:/usr/bin:/bin:/usr/sbin:/sbin
    export RH7_RESTIC_BIN=${pkgs.restic}/bin/restic
    export RH7_RESTIC_REPO_HOST=${lib.escapeShellArg cfg.repositoryHost}
    export RH7_RESTIC_PORT=${toString cfg.port}
    export RH7_RESTIC_PATHS=${lib.escapeShellArg (lib.concatStringsSep "\n" cfg.paths)}
    export RH7_RESTIC_EXCLUDES=${lib.escapeShellArg (lib.concatStringsSep "\n" cfg.exclude)}
    export RH7_RESTIC_EXCLUDE_LARGER_THAN=${lib.escapeShellArg cfg.excludeLargerThan}
    exec ${pkgs.bash}/bin/bash ${scripts}/scripts/restic-backup.sh "$@"
  '';
in
{
  options.services.rh7.resticBackup = {
    enable = lib.mkEnableOption "daily restic backup of the policy folders to the fleet restic REST server";

    repositoryHost = lib.mkOption {
      type = lib.types.str;
      default = "rouvens-mac-studio";
      description = "Tailscale name of the restic REST server.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = "Port of the restic REST server.";
    };

    paths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Developer-workstation set of the fleet backup policy. Missing paths are
      # skipped at run time; status.json records only the ones backed up.
      # ~/Desktop, ~/Documents, ~/Downloads: deliberately absent — see header.
      default = [
        "~/.ssh"
        "~/.config"
        "~/.gnupg"
        "~/code"
        "~/Projects"
        "~/localtesting"
        "~/dotfiles"
      ];
      description = ''
        Paths to back up, as "~/…" or absolute. Protected macOS folders need
        the Full Disk Access grant described in the module header.
      '';
    };

    exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "node_modules"
        ".venv"
        "venv"
        "__pycache__"
        "target"
        "dist"
        "build"
        ".next"
        ".cache"
        "*.tmp"
        ".DS_Store"
        "~/.config/**/Cache*"
      ];
      description = ''
        restic --exclude patterns; a leading "~/" is expanded. Files larger
        than `excludeLargerThan` (model weights: *.gguf, *.safetensors, *.bin)
        and CACHEDIR.TAG-marked directories are excluded on top of these.
      '';
    };

    excludeLargerThan = lib.mkOption {
      type = lib.types.str;
      default = "100M";
      description = "restic --exclude-larger-than: keeps large model/weight files out.";
    };

    hour = lib.mkOption {
      type = lib.types.ints.between 0 23;
      default = 13;
      description = "Local hour of the daily run.";
    };

    minute = lib.mkOption {
      type = lib.types.ints.between 0 59;
      default = 0;
      description = "Minute of the daily run.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = lib.all (p: lib.hasPrefix "~/" p || lib.hasPrefix "/" p) cfg.paths;
      message = "services.rh7.resticBackup.paths must be \"~/…\" or absolute";
    }];

    # restic itself too: `rh7-restic-backup restore-hint` prints plain restic
    # commands for listing and restoring.
    environment.systemPackages = [ runner pkgs.restic ];

    launchd.user.agents.restic-backup.serviceConfig = {
      Label = "org.rh7.restic-backup";
      # Fixed paths on purpose — see "WHY THE PLIST POINTS AT FIXED PATHS".
      ProgramArguments = [ launcherPath "restic" ];
      StartCalendarInterval = [{ Hour = cfg.hour; Minute = cfg.minute; }];
      RunAtLoad = false;
      # The script keeps its own log (~/.local/state/rh7-restic/backup.log);
      # this only catches launchd-level failures.
      StandardOutPath = "/tmp/org.rh7.restic-backup.launchd.log";
      StandardErrorPath = "/tmp/org.rh7.restic-backup.launchd.log";
      LowPriorityIO = true;
      Nice = 10;
    };
  };
}
