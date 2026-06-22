# modules/home/profiles/fleet-audit.nix
#
# Declarative daily device audit (rh-device-management #83 Phase 1).
#
# THE BOUNDARY (do not blur it): nix declares the SCHEDULE; the audit LOGIC is
# PULLED at runtime. This launchd agent / systemd timer invokes
# collector-runner.sh, which fetches the current audit-device.sh from the config
# service (/api/collector) over Tailscale and runs it ONLY after verifying
# sha256 + the server read-only scan + the pinned serving ref (#96/#99), caching
# last-good. So both properties hold at once:
#   - changing WHAT is collected stays ONE merge to dotfiles (the runner pulls
#     the new committed blob on its next wake) — never a per-device rebuild (#83);
#   - the supply-chain gate the runner exists to provide is preserved.
# Do NOT point ProgramArguments at `curl … /audit | bash` (runs UNVERIFIED bytes
# off the public short link) and do NOT vendor audit-device.sh into the nix store
# (that reverts #83 — collection changes would then need a fleet rebuild). Only
# the thin runner is on disk; the logic it pulls stays central.
#
# WIRING (staged, per the coverage caveat below): import this FIRST from a host's
# `extraHomeModules` in flake.nix to validate on one or two hosts (e.g. the
# Studio, m5-air), then promote to modules/common.nix's `imports` list to apply
# to every mkMac / mkNixOS / mkLinux host.
#
# COVERAGE (honest bound): only takes effect on hosts that are actually
# nix-darwin/NixOS-managed AND rebuilt. Determinate-Nix Macs (e.g. m5-air today),
# appliances/phones/routers, and offline/stale hosts are NOT covered by this —
# they keep the imperative pull-runner (com.rh7.collector-runner via
# `collector-runner.sh --install`) or the no-clone curl path. This module does
# not retroactively cover the fleet; coverage grows as hosts are migrated/rebuilt.
{ pkgs, lib, config, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  homeDir = config.home.homeDirectory;

  # The runner lives in the same ~/dotfiles checkout nix rebuilds from, so on any
  # nix-managed host it is already on disk at a stable path — no clone bootstrap
  # is needed here (that is the no-clone curl path's concern, #119).
  runner = "${homeDir}/dotfiles/scripts/collector-runner.sh";

  # Fixed daily time. NOTE: a per-host minute stagger can't be derived in this
  # layer — the hostname is NOT threaded into home-manager (mkMac/mkNixOS pass no
  # extraSpecialArgs; only mkLinux passes `username`). To stagger, add
  # `extraSpecialArgs = { inherit hostname; }` to the mk* helpers and hash it
  # into `minute`. A synchronized ~dozen-host POST at 08:17 is harmless for the
  # single-writer config service.
  hour = 8;
  minute = 17;
  hh = lib.fixedWidthString 2 "0" (toString hour);
  mm = lib.fixedWidthString 2 "0" (toString minute);

  # Load-bearing PATH: collector-runner itself needs bash/curl/python3/shasum;
  # the audit it execs shells out to brew/docker/tailscale/mas (macOS) or the
  # system profile (Linux). Provide the tools from nix + the platform app paths.
  toolPath = lib.makeBinPath [ pkgs.bash pkgs.curl pkgs.python3 pkgs.coreutils ];
  appPath =
    if isDarwin
    then "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    else "/run/current-system/sw/bin:/usr/bin:/bin";
  fullPath = "${toolPath}:${appPath}";
in
{
  # ── macOS: user LaunchAgent ─────────────────────────────────────────────
  # Reuse Label com.rh7.collector-runner so home-manager's launchd activation
  # supersedes any imperatively-installed agent of the same name (no manual
  # launchctl). The runner's own first run still retires the legacy com.rh7.audit.
  launchd.agents.fleet-audit = lib.mkIf isDarwin {
    enable = true;
    config = {
      Label = "com.rh7.collector-runner";
      ProgramArguments = [ "/bin/bash" "-lc" "bash ${runner}" ]; # runner defaults to --run
      StartCalendarInterval = { Hour = hour; Minute = minute; };
      RunAtLoad = false; # don't audit on every login/rebuild; setup.sh does the first audit
      StandardOutPath = "/tmp/com.rh7.collector-runner.out.log";
      StandardErrorPath = "/tmp/com.rh7.collector-runner.err.log";
      EnvironmentVariables = { PATH = fullPath; };
    };
  };

  # ── Linux: systemd user oneshot + timer ─────────────────────────────────
  # CAVEAT: a systemd --user timer fires only with an active or lingering user
  # session. NixOS desktop hosts have this; a headless OrbStack VM needs
  # `loginctl enable-linger "$USER"`, OR declare this as SYSTEM-level
  # systemd.services + systemd.timers in that host's NixOS module (not possible
  # from this home-manager layer). Until then such VMs keep the imperative cron.
  systemd.user.services.fleet-audit = lib.mkIf (!isDarwin) {
    Unit.Description = "Fleet device audit (pull-based collector-runner)";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${runner}";
      Environment = [ "PATH=${fullPath}" ];
    };
  };
  systemd.user.timers.fleet-audit = lib.mkIf (!isDarwin) {
    Unit.Description = "Daily fleet device audit";
    Timer = {
      OnCalendar = "*-*-* ${hh}:${mm}:00";
      Persistent = true; # catch up a missed run if the box was off
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
