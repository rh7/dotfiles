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
#     the primary user; the daemon first invalidates that user's sudo timestamp
#     (sudo-rebuild.nix makes it user-global) and there is no tty, so that sudo
#     fails fast instead of prompting or silently escalating. `brew bundle`
#     fails, nix-darwin's activation stops at the Homebrew step (`set -e`), and
#     the run records failed/brew-failed. The system profile already points at
#     the new generation (recorded as `generation`), but postActivation —
#     mas_install, home-manager — and the /run/current-system flip did not run.
#     It retries nightly; a human `rebuild.sh` clears it.
#   - No Mac App Store installs or upgrades. `mas_install` of a newly declared
#     app fails (mas needs sudo internally) and only warns; `mas upgrade` is
#     never run.
#   - No flake.lock bumps (weekly bot PR), no macOS updates (separate policy).
#   - It does not pull ~/dotfiles. User agents that run scripts from that
#     checkout (fleet-audit.nix, weekly-update.nix) keep running whatever it
#     holds.
#   - It never removes a Dock item. persistent-apps REPLACES the primary
#     user's whole Dock, so the daemon evaluates the new commit's declaration
#     and compares it with her current Dock (read-only, from her
#     com.apple.dock.plist) before building and again right before
#     activating. Any app that would vanish holds the
#     update: skipped/dock-protect, the paths in state `dock_protect`. An
#     unreadable Dock holds too. Additions, reorders and an unmanaged Dock
#     (persistent-apps unset) proceed. Resolve by declaring the apps, or by a
#     human `rebuild.sh` (it shows the Dock drift and asks).
# Activation also runs home-manager via `launchctl asuser`. If the primary user
# has no GUI login session, home-manager's LaunchAgent bootstrap into gui/<uid>
# fails and aborts activation (failed/activation-failed) — except on hosts with
# the household home profile, whose guard installs the agents for her next
# login instead (configurations/macos/home-household.nix); the run is then
# `applied` and the log carries a note.
#
# Every external step is bounded (fetch 10 min, build 3 h, activation 1 h) and
# runs with stdin closed, so a prompt can only ever fail, never block.
#
# Studio and mini are deliberately NOT enabled (control plane / out of scope);
# hosts opt in through mkMac's `autoUpdate` argument in flake.nix.
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
    export PATH=${lib.makeBinPath [ pkgs.git pkgs.gnupg pkgs.coreutils pkgs.jq pkgs.gnugrep pkgs.gnused ]}:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin
    export NIX_REMOTE=daemon
    export HOME=/var/root
    exec ${pkgs.bash}/bin/bash ${../../scripts/fleet-update.sh} \
      --channel ${lib.escapeShellArg cfg.channel} \
      --flake-attr ${lib.escapeShellArg cfg.flakeAttr} \
      --signer-key ${signerKey} \
      --primary-user ${lib.escapeShellArg config.system.primaryUser} \
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
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.flakeAttr != "";
      message = "services.rh7.fleetUpdate.flakeAttr must name this host's darwinConfiguration";
    }];

    environment.systemPackages = [ runner ];

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
  };
}
