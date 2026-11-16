# modules/darwin/fleet-update.nix
#
# Unattended nightly config updates for a nix-darwin Mac (replaces manual
# scripts/rebuild.sh runs for routine changes).
#
# WHAT IT IS: a root LaunchDaemon, org.rh7.fleet-update, that runs
# scripts/fleet-update.sh daily at 03:30 (+ up to 30 min random delay). If the
# Mac is asleep at 03:30 launchd runs the job once on the next wake. Each run
# fetches this repo into a root-owned checkout (/var/lib/rh7-fleet-update/
# dotfiles — never ~/dotfiles), and switches ONLY when the channel tip:
#   - carries a signature that verifies against the PINNED key below (GitHub's
#     web-flow key, which signs every PR-merge commit on main);
#   - is already in `main` (a branch can never carry unreviewed code);
#   - fast-forwards from BOTH the last applied commit and the commit the
#     running generation was built from (configurationRevision, set by mkMac),
#     so neither a lagging channel nor the night after a manual rebuild.sh from
#     a newer main rolls a host back. A host hand-rebuilt from a NEWER merged
#     main commit records skipped/channel-behind and waits for the channel;
#     an unmerged/local/-dirty build or a diverged tip is refused.
# It builds darwinConfigurations.<flakeAttr>.system, sets the system profile
# and runs the generation's `activate` as root. Result -> /var/lib/
# rh7-fleet-update/state.json (collected into the daily audit as
# `fleet_update`), log -> /var/log/rh7-fleet-update.log.
#
# CHANNELS: canaries track `main`; everything else tracks `fleet/stable`, which
# is fast-forwarded from main only after the canaries reported success and a
# soak period (promotion lives outside this module).
#
# TRUST ANCHOR FROM THE ACTIVATED GENERATION. The script, the pinned key and
# the git/gnupg it uses are store paths baked into the `rh7-fleet-update`
# wrapper, which is installed into /run/current-system/sw/bin. Nothing the
# daemon trusts is read from the tree it just fetched: a commit can change the
# key or the checks only by first passing the CURRENT ones.
#
# WHY THE PLIST POINTS AT /run/current-system AND NOT AT A STORE PATH: nix-darwin
# activation `launchctl unload`s every daemon whose plist changed. If the plist
# embedded the script's store path, every change to the script (or to git/gnupg
# via flake.lock) would make the update's own activation SIGTERM the update
# mid-run. The plist is therefore byte-stable; the wrapper behind the stable path
# changes instead. Changing the plist itself (schedule, label) still costs one
# interrupted run: AbandonProcessGroup lets that activation finish, the script
# dies without recording it, and the next night re-applies the same commit
# idempotently.
#
# WHAT AN UNATTENDED RUN DOES NOT DO (by design — a human runs rebuild.sh):
#   - No Homebrew upgrades. homebrew.onActivation.upgrade = false; brew bundle
#     only installs MISSING formulae/casks. Upgrades remain
#     `rebuild.sh --upgrade=critical|all`.
#   - No pkg-installer casks. Casks that need root (pkg installers) call sudo as
#     homebrew.user (who `brew bundle` runs as); the daemon first invalidates
#     that user's and the primary user's sudo timestamps (sudo-rebuild.nix
#     makes the brew user's user-global) and there is no tty, so that sudo
#     fails fast instead of prompting or silently escalating. `brew bundle`
#     fails, nix-darwin's activation stops at the Homebrew step (`set -e`), and
#     the run records failed/brew-failed. The system profile already points at
#     the new generation (recorded as `generation`), but postActivation —
#     mas_install, home-manager — and the /run/current-system flip did not run.
#     It retries nightly; a human `rebuild.sh` clears it.
#   - No new cask as a homebrew.user that cannot write /Applications (a
#     standard account). Even a plain app cask then needs Homebrew's own
#     `sudo cp` as that user. Nor any Homebrew run while Homebrew's own prefix
#     directories are not homebrew.user's (the option changed; only a human `rebuild.sh`
#     migrates the prefix, with one chown question). The daemon evaluates
#     the commit's homebrew.user and casks BEFORE building; either case
#     records failed/brew-failed (the log names the cause and the fix) and
#     nothing is built or switched.
#   - No Mac App Store installs or upgrades. `mas_install` of a newly declared
#     app fails (mas needs sudo internally) and only warns; `mas upgrade` is
#     never run.
#   - No flake.lock bumps (weekly bot PR), no macOS updates (separate policy).
#   - It does not pull ~/dotfiles. User agents that run scripts from that
#     checkout (fleet-audit.nix, weekly-update.nix) keep running whatever it
#     holds.
#   - It never removes a Dock item. persistent-apps (apps, left side) and
#     persistent-others (folders/stacks/files, right side) each REPLACE that
#     side of the primary user's Dock, so the daemon evaluates the new
#     commit's declaration and compares it with her current Dock (read-only,
#     from her com.apple.dock.plist) before building and again right before
#     activating. Any item that would vanish holds the update:
#     skipped/dock-protect, the paths in state `dock_protect`. An unreadable
#     Dock holds too. Additions, reorders and an unmanaged side (option
#     unset) proceed. Resolve by declaring the items, or by a human
#     `rebuild.sh` (it shows the Dock drift and asks).
# Activation also runs home-manager via `launchctl asuser`. If the primary user
# has no GUI login session, home-manager's LaunchAgent bootstrap into gui/<uid>
# fails and aborts activation (failed/activation-failed) — except on household
# hosts, whose primary user's home-manager declares no LaunchAgent at all (the
# daily audit is a system LaunchDaemon there, modules/darwin/fleet-audit.nix),
# so their activation does not depend on her being logged in.
#
# Every external step is bounded (fetch 10 min, build 3 h, activation 1 h) and
# runs with stdin closed, so a prompt can only ever fail, never block.
#
# DEPLOY NOW (org.rh7.deploy-request). A second root LaunchDaemon, every 15
# minutes, asks the pinned config service (/etc/rh7/config-service) whether
# the owner requested a deploy of this host: GET /api/fleet/deploy-request/
# <flakeAttr>. Nothing requested -> it exits silently; an unreachable service
# -> one log line, nothing else (fail-soft). Requested -> it acks `started`,
# runs this same rh7-fleet-update once with --requested <id> (and --fast-lane
# when the owner allowed it), and acks the result read back from state.json
# (status, commit, lane, reason). It goes through the update's own lock, so it
# never overlaps the nightly run: whichever comes second logs lock-held and
# the request stays pending for the next poll. Outbound only — nothing on the
# Mac listens, and SSH / Screen Sharing stay as they are (household Macs: off).
# Requested runs keep every trust check; they differ only in power (battery
# with >= 50% charge is enough), jitter (none) and the FAST LANE: with
# `fastLaneFile` set (mkMac `hostFile`, a file only this host imports) and
# the owner's consent, the signed main tip is applied instead of the channel
# tip when channel..main touches nothing but that file and only adds
# cask/formula/package list entries (and CI is green on it). fleet/stable is
# not moved; the host is ahead of it until it catches up (channel runs record
# skipped/channel-behind meanwhile). Details: scripts/fleet-update.sh
# "REQUESTED RUNS", scripts/deploy-request.sh, docs/device-guide.md
# "Deploy now (remote, household)".
#
# Studio and mini are deliberately NOT enabled (control plane / out of scope);
# hosts opt in through mkMac's `autoUpdate` argument in flake.nix. The deploy-
# request daemon exists exactly where this module is enabled.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.rh7.fleetUpdate;

  # GitHub web-flow commit-signing key, fingerprint
  # 968479A1AFF927E37D1A566BB5690EEEBB952194 (see the file header). `.asc`, not
  # `.gpg`: the repo's .gitignore drops `*.gpg` so raw secrets can't be committed.
  signerKey = ../../keys/github-web-flow.asc;

  runner = pkgs.writeShellScriptBin "rh7-fleet-update" ''
    # Store tools first. nix itself comes from the official installer's default
    # profile (nix.enable = false in defaults.nix); pmset/pgrep/sudo from macOS.
    export PATH=${lib.makeBinPath [ pkgs.git pkgs.gnupg pkgs.coreutils pkgs.jq pkgs.gnugrep pkgs.gnused pkgs.curl ]}:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin
    export NIX_REMOTE=daemon
    export HOME=/var/root
    exec ${pkgs.bash}/bin/bash ${../../scripts/fleet-update.sh} \
      --channel ${lib.escapeShellArg cfg.channel} \
      --flake-attr ${lib.escapeShellArg cfg.flakeAttr} \
      --signer-key ${signerKey} \
      --primary-user ${lib.escapeShellArg config.system.primaryUser} \
      ${lib.optionalString (cfg.fastLaneFile != null) "--fast-lane-file ${lib.escapeShellArg cfg.fastLaneFile}"} \
      "$@"
  '';

  # The deploy-request poller. It runs the update through the store path of the
  # runner above (same generation), never through a PATH lookup.
  poller = pkgs.writeShellScriptBin "rh7-deploy-request" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.jq pkgs.gnugrep pkgs.gnused pkgs.curl ]}:/usr/bin:/bin:/usr/sbin:/sbin
    export HOME=/var/root
    exec ${pkgs.bash}/bin/bash ${../../scripts/deploy-request.sh} \
      --hostname ${lib.escapeShellArg cfg.flakeAttr} \
      --fleet-update ${runner}/bin/rh7-fleet-update \
      "$@"
  '';
in
{
  options.services.rh7.fleetUpdate = {
    enable = lib.mkEnableOption "unattended nightly nix-darwin updates from a signed rh7/dotfiles channel";

    channel = lib.mkOption {
      type = lib.types.enum [ "main" "fleet/stable" ];
      default = "fleet/stable";
      description = "Branch of rh7/dotfiles to follow. Canaries use main.";
    };

    flakeAttr = lib.mkOption {
      type = lib.types.str;
      description = ''
        darwinConfigurations attribute to build. Baked in at evaluation time
        (mkMac sets it) — never derived from the runtime hostname, which a
        user can change.
      '';
    };

    fastLaneFile = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "configurations/macos/[A-Za-z0-9._-]+\\.nix");
      default = null;
      example = "configurations/macos/kassie-mbp-m1.nix";
      description = ''
        Repo-relative path of the file only this host imports (mkMac sets it
        from `hostFile`). A requested deploy may take the fast lane only for
        a change confined to this file. null = no fast lane: a shared file
        (macbook.nix) changes other hosts too.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.flakeAttr != "";
      message = "services.rh7.fleetUpdate.flakeAttr must name this host's darwinConfiguration";
    }];

    environment.systemPackages = [ runner poller ];

    launchd.daemons.fleet-update.serviceConfig = {
      Label = "org.rh7.fleet-update";
      # Stable path on purpose — see "WHY THE PLIST POINTS AT /run/current-system".
      ProgramArguments = [ "/run/current-system/sw/bin/rh7-fleet-update" "--scheduled" ];
      StartCalendarInterval = [{ Hour = 3; Minute = 30; }];
      RunAtLoad = false;
      # The script keeps its own rotated log; this only catches launchd-level
      # failures before it starts.
      StandardOutPath = "/var/log/rh7-fleet-update.launchd.log";
      StandardErrorPath = "/var/log/rh7-fleet-update.launchd.log";
      AbandonProcessGroup = true;
      LowPriorityIO = true;
      Nice = 5;
    };

    # "Deploy now" poller — see DEPLOY NOW above. Stable path for the same
    # reason as the update's plist. AbandonProcessGroup: when an update it
    # started changes THIS plist, activation unloads the poller mid-run; the
    # update itself must finish, and the next poll acks its result from
    # state.json. No Nice/LowPriorityIO: somebody is waiting for this one.
    launchd.daemons.deploy-request.serviceConfig = {
      Label = "org.rh7.deploy-request";
      ProgramArguments = [ "/run/current-system/sw/bin/rh7-deploy-request" ];
      StartInterval = 900;
      RunAtLoad = false;
      StandardOutPath = "/var/log/rh7-deploy-request.launchd.log";
      StandardErrorPath = "/var/log/rh7-deploy-request.launchd.log";
      AbandonProcessGroup = true;
    };
  };
}
