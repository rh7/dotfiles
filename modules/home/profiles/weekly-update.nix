# modules/home/profiles/weekly-update.nix
#
# Weekly unattended Homebrew updates, so app upgrades stop piling up into a
# 30-minute surprise on the next interactive rebuild.
#
# THE BOUNDARY (mirrors fleet-audit.nix): nix declares the SCHEDULE only. The
# update LOGIC lives in scripts/weekly-update.sh in the same checkout nix
# rebuilds from, so changing what the job does is a merge, not a fleet rebuild.
#
# SCOPED TO DECLARED PACKAGES — the job upgrades what homebrew.brews/casks
# declare and nothing else. `brew outdated` also lists hand-installed software;
# upgrading that here would make the weekly job broader than a rebuild and quietly
# demote the flake from source of truth. Undeclared outdated packages are
# reported as drift in the log so they stay visible instead of silently rotting.
#
# ROOTLESS BY DESIGN — this is a user LaunchAgent, not a system daemon. See the
# long rationale at the top of scripts/weekly-update.sh; the short version is
# that unattended root would require either auto-deploying whatever is on `main`
# or a standing NOPASSWD grant, and neither is worth it for convenience. Casks
# that need root are skipped and reported, then finished by an interactive
# rebuild.sh run. Do NOT "fix" that by promoting this to launchd.daemons.
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
