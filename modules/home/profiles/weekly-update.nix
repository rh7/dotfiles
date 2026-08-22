# modules/home/profiles/weekly-update.nix
#
# Weekly unattended Homebrew updates, so app upgrades stop piling up into a
# 30-minute surprise on the next interactive rebuild.
#
# THE BOUNDARY (mirrors fleet-audit.nix): nix declares the SCHEDULE only. The
# update LOGIC lives in scripts/weekly-update.sh in the same checkout nix
# rebuilds from, so changing what the job does is a merge, not a fleet rebuild.
#
# SCOPED TO DECLARED FORMULAE — the job upgrades formulae that homebrew.brews
# declares, and nothing else. `brew outdated` also lists hand-installed
# software; upgrading that here would make the weekly job broader than a
# rebuild and quietly demote the flake from source of truth. Undeclared
# packages are reported as drift so they stay visible instead of rotting.
# (Homebrew still resolves dependencies, so an undeclared dependency of a
# declared formula may be upgraded — only target SELECTION is restricted.)
#
# FORMULAE ONLY — an earlier version also upgraded casks, skipping the ones
# that failed on the theory they had needed root. That could not actually deny
# root: modules/darwin/sudo-rebuild.nix keeps a user-global sudo timestamp open
# for the length of a rebuild, and a cask install running in this agent during
# that window would have inherited it and escalated silently, unattended.
#
# Restricting to formulae removes the expected privileged path (the cask
# installer). Be precise about what that does and does not buy: formula
# install/post-install code still runs as this user and could invoke sudo
# against a valid timestamp. This is a large practical risk reduction, not a
# technical guarantee — a real boundary would need a separate non-admin
# identity that cannot use sudo at all.
#
# Outdated casks are reported and prefetched for an interactive rebuild.sh,
# where a human authenticates once and watches. Do NOT re-add cask upgrades
# here, and do NOT promote this to launchd.daemons — both reintroduce
# unattended privileged installs.
#
# ACCEPTED RISK (not a fix): this agent runs the script from the mutable
# ~/dotfiles checkout, per the same convention fleet-audit.nix documents, so
# its notion of "declared" comes from the checkout rather than the activated
# generation. A dirty or ahead-of-activation checkout can therefore select a
# different upgrade set than the running system declares. Changing that is a
# repo-wide architectural decision, deliberately out of scope here.
#
# WIRING (staged, per the same convention fleet-audit.nix documents): imported
# from a single host's `extraHomeModules` in flake.nix first. Promote to
# modules/common.nix once it has proven itself over a few weeks.
#
# COVERAGE (honest bound): a user LaunchAgent runs only while the user is
# logged in. If the Mac is asleep at the scheduled moment launchd runs the job
# on next wake, but a machine that is off all Monday simply misses that week —
# StartCalendarInterval does not backfill multiple missed runs. This is a
# best-effort convenience, not a compliance mechanism.
{ pkgs, lib, config, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  homeDir = config.home.homeDirectory;

  updater = "${homeDir}/dotfiles/scripts/weekly-update.sh";

  # Monday morning. Late enough that a laptop opened for the day is awake and
  # on wifi, early enough that the upgrades are done before real work starts.
  weekday = 1; # 1 = Monday
  hour = 10;
  minute = 0;

  # Load-bearing PATH: the script needs bash/git/coreutils/jq from nix, brew
  # from the Homebrew prefix, and `nix` itself — it evaluates the flake to
  # learn which packages are DECLARED (undeclared ones are reported, never
  # upgraded). launchd agents get a minimal PATH, and without the nix profile
  # dirs below that eval fails and the job refuses to run, every week. The
  # script has locating fallbacks for brew and nix, but set it properly here.
  toolPath = lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.git pkgs.jq ];
  nixPath = "/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin";
  appPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
  fullPath = "${toolPath}:${nixPath}:${appPath}";
in
{
  launchd.agents.weekly-update = lib.mkIf isDarwin {
    enable = true;
    config = {
      Label = "com.rh7.weekly-update";
      ProgramArguments = [ "/bin/bash" "-lc" "bash ${updater}" ];
      StartCalendarInterval = [{
        Weekday = weekday;
        Hour = hour;
        Minute = minute;
      }];
      # Never on login/rebuild — this pulls software over the network and would
      # otherwise fire on every `darwin-rebuild switch`, which is exactly the
      # surprise-download behaviour this module exists to remove.
      RunAtLoad = false;
      StandardOutPath = "/tmp/com.rh7.weekly-update.out.log";
      StandardErrorPath = "/tmp/com.rh7.weekly-update.err.log";
      EnvironmentVariables = { PATH = fullPath; };
      # Upgrades are I/O and network heavy; keep them out of the way of
      # whatever the user is actually doing.
      LowPriorityIO = true;
      Nice = 5;
    };
  };
}
