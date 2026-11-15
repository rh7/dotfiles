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
# WIRING: imported by flake.nix's mkMac helper for EVERY darwinConfiguration
# (promoted from the Studio's extraHomeModules, rh-device-management #315).
# Deliberately NOT in modules/common.nix, so mkNixOS / mkLinux hosts do not get
# it: a systemd --user timer only fires with an active or lingering session (see
# the Linux CAVEAT below), so on headless Linux it would look installed while
# never running. Wire it per Linux host only once that host has linger or a
# system-level timer. The runner path follows home.homeDirectory, so it is
# correct for non-default usernames (e.g. /Users/rouven, /Users/kassie).
#
# FULL DISK ACCESS (optional, per Mac): on macOS the agent starts
# `/usr/local/libexec/rh7-fleet-launcher audit` (modules/darwin/fleet-launcher.nix,
# which mkMac imports for every Mac alongside this module), not a script: the
# launcher is the one stable binary an FDA grant can attach to, shared with
# the restic job. It runs the system wrapper `rh7-fleet-audit` — the runner
# baked in by store path with the PATH below — under a rebuilt environment.
# Without the grant the audit behaves as before and its data_inventory reports
# the protected folders `not-inspected`; with it they are measured.
#
# SCHEDULER (macOS): nix-darwin's services.rh7.fleetAudit.scheduler
# (modules/darwin/fleet-audit.nix), read here through osConfig.
#   "user-agent" (default) — this module's gui LaunchAgent below. It runs only
#     while the primary user has a GUI login session.
#   "system-daemon" (household Macs, modules/roles/household-mac.nix) — the
#     SAME label/program/time as a system LaunchDaemon running as the primary
#     user, independent of who is logged in. This module then declares NO
#     agent and retires one left in ~/Library/LaunchAgents (a previous
#     generation's, or an imperative `collector-runner.sh --install` copy),
#     so the Mac never audits twice.
#
# COVERAGE (honest bound): only takes effect on Macs that are actually
# nix-darwin-managed AND rebuilt since this landed. Linux hosts, appliances/
# phones/routers, not-yet-migrated Macs and offline/stale hosts are NOT covered
# by this — they keep the imperative pull-runner (com.rh7.collector-runner via
# `collector-runner.sh --install`) or the no-clone curl path. On a migrated Mac
# the declarative agent supersedes the imperative one (same Label, see below).
#
# osConfig is the nix-darwin config home-manager's darwin module passes in;
# it is read only on Darwin (mkMac), never on Linux.
{ pkgs, lib, config, osConfig, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  homeDir = config.home.homeDirectory;

  # Linux: the runner lives in the same ~/dotfiles checkout nix rebuilds from,
  # so it is already on disk at a stable path — no clone bootstrap is needed
  # here (that is the no-clone curl path's concern, #119). macOS runs the
  # store copy behind the fleet launcher instead (see FULL DISK ACCESS).
  runner = "${homeDir}/dotfiles/scripts/collector-runner.sh";
  launcher = "/usr/local/libexec/rh7-fleet-launcher";

  # Daily time, shared with the household system daemon.
  inherit (import ../../fleet-audit-time.nix) hour minute;
  hh = lib.fixedWidthString 2 "0" (toString hour);
  mm = lib.fixedWidthString 2 "0" (toString minute);

  label = "com.rh7.collector-runner";
  scheduler = if isDarwin then osConfig.services.rh7.fleetAudit.scheduler else "user-agent";

  # Load-bearing PATH (Linux; on macOS the rh7-fleet-audit wrapper in
  # fleet-launcher.nix sets its own): collector-runner itself needs
  # bash/curl/python3/shasum; the audit it execs shells out to the system
  # profile. Provide the tools from nix + the system profile.
  toolPath = lib.makeBinPath [ pkgs.bash pkgs.curl pkgs.python3 pkgs.coreutils ];
  fullPath = "${toolPath}:/run/current-system/sw/bin:/usr/bin:/bin";
in
{
  # ── macOS: user LaunchAgent ─────────────────────────────────────────────
  # Reuse Label com.rh7.collector-runner so home-manager's launchd activation
  # supersedes an imperatively-installed agent of the SAME label. The legacy
  # direct-audit agent has a DIFFERENT label (com.rh7.audit) and the runner only
  # retires it in --install mode (not the default --run this agent uses), so it
  # is retired explicitly in home.activation below.
  launchd.agents.fleet-audit = lib.mkIf (isDarwin && scheduler == "user-agent") {
    enable = true;
    config = {
      Label = label;
      # The launcher rebuilds the environment (fixed PATH, HOME from the
      # password database); rh7-fleet-audit sets the tool PATH itself.
      ProgramArguments = [ launcher "audit" ]; # runner defaults to --run
      StartCalendarInterval = { Hour = hour; Minute = minute; };
      RunAtLoad = false; # don't audit on every login/rebuild; setup.sh does the first audit
      StandardOutPath = "/tmp/${label}.out.log";
      StandardErrorPath = "/tmp/${label}.err.log";
    };
  };

  # The system daemon runs the audit: remove this account's agent of the same
  # label BEFORE setupLaunchAgents. home-manager would drop a previous
  # generation's agent itself, but it skips a plist whose content diverged (an
  # imperative --install copy) and it bootouts through gui/<uid>; doing it here
  # covers both, and leaves home-manager nothing to boot out. Without a GUI
  # session nothing is loaded and the plist is simply removed. A LOADED agent
  # that refuses to boot out fails activation with its plist kept, instead of
  # running beside the daemon until logout. launchctl + ~/Library/LaunchAgents
  # only, so TCC-safe.
  home.activation.retireUserAuditAgent = lib.mkIf (isDarwin && scheduler == "system-daemon") (
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
      agent="$HOME/Library/LaunchAgents/${label}.plist"
      if /bin/launchctl print "gui/$UID/${label}" >/dev/null 2>&1 \
        && ! run /bin/launchctl bootout "gui/$UID/${label}" \
        && /bin/launchctl print "gui/$UID/${label}" >/dev/null 2>&1; then
        errorEcho "rh7: cannot boot out gui/$UID/${label} — the old audit agent would run beside the system daemon; kept $agent, re-run the rebuild"
        exit 1
      fi
      if [[ -e "$agent" || -L "$agent" ]]; then
        run rm -f "$agent"
        noteEcho "rh7: removed the ${label} LaunchAgent — the daily audit is the system daemon /Library/LaunchDaemons/${label}.plist"
      fi
    ''
  );

  # Retire the legacy imperative com.rh7.audit agent when a host comes under nix
  # management. It has a different Label so the new agent won't supersede it, and
  # the runner's retire-on-install path isn't reached in default --run mode —
  # without this a migrating Mac runs BOTH (duplicate uploads; the legacy job
  # bypasses the supply-chain gate). launchctl-only, so TCC-safe.
  home.activation.retireLegacyAudit = lib.mkIf isDarwin (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      legacy="$HOME/Library/LaunchAgents/com.rh7.audit.plist"
      if [ -f "$legacy" ]; then
        $DRY_RUN_CMD /bin/launchctl unload "$legacy" 2>/dev/null || true
        $DRY_RUN_CMD rm -f "$legacy"
        echo "retired legacy com.rh7.audit LaunchAgent (superseded by com.rh7.collector-runner)"
      fi
    ''
  );

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
