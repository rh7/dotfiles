# modules/darwin/fleet-audit.nix
#
# WHICH launchd domain runs a Mac's daily audit (rh-device-management #83).
# Imported by flake.nix's mkMac for EVERY Mac; the audit itself — runner, gate,
# launcher — is the same whichever scheduler is chosen.
#
#   services.rh7.fleetAudit.scheduler = "user-agent"     (default)
#     home-manager's gui-domain LaunchAgent in the primary user's account
#     (modules/home/profiles/fleet-audit.nix). Runs only while that account
#     has a GUI login session. Right for a Mac whose primary user IS the one
#     at the keyboard every day (workstations, personal Macs).
#
#   services.rh7.fleetAudit.scheduler = "system-daemon"  (modules/roles/household-mac.nix)
#     a LaunchDaemon in the SYSTEM domain, /Library/LaunchDaemons/
#     com.rh7.collector-runner.plist, that runs the audit AS the primary user
#     whether or not anybody is logged in. home-manager then installs NO agent
#     for this label and removes one left from an earlier generation, so the
#     Mac never audits twice. Exists because kassie-mbp-m1's daily user is not
#     logged in every day: the gui agent only ran when somebody started the
#     collector by hand, and the dashboard flagged audit-missed.
#
# SAME LABEL, SAME PROGRAM, SAME TIME as the agent: com.rh7.collector-runner
# (the control plane classifies the mechanism by that label), started as
# `/usr/local/libexec/rh7-fleet-launcher audit` → rh7-fleet-audit → the
# store-pinned collector-runner (modules/darwin/fleet-launcher.nix), which
# fetches the collector only after sha256 + read-only scan + pinned ref
# (#96/#99). Daily at modules/fleet-audit-time.nix (08:17); launchd runs a
# StartCalendarInterval missed while the Mac slept once on wake (not one that
# fell while it was powered off).
#
# AS THE USER, VIA launchd `UserName` — not `sudo -u` in ProgramArguments:
#   - launchd itself sets uid/gid/supplementary groups before exec; no sudo,
#     PAM or sudoers involved, nothing that can prompt or fail on a policy;
#   - the launcher stays the job's program, i.e. the RESPONSIBLE process
#     macOS privacy protection (TCC) judges. With `sudo -u … launcher` sudo
#     would be the job's program and an FDA grant on the launcher would not
#     apply. The launcher then takes HOME/USER/TMPDIR from the password
#     database for uid = the primary user, exactly as under the agent.
#   - No GUI session is needed or used. The job is not in her gui/<uid>
#     domain, so nothing it runs can surface UI in her session.
#
# FULL DISK ACCESS (optional) carries over: the grant is a system-wide TCC
# entry (System Settings → Privacy & Security → Full Disk Access, stored in
# /Library/Application Support/com.apple.TCC/TCC.db) for the launcher's code
# identity, and the launcher is the responsible process here too — so a Mac
# that granted it keeps measuring its protected folders, and one that did not
# gets `not-inspected` as before. Expectation from how TCC attributes access,
# not yet observed on a system-domain job: the first daemon run's
# data_inventory.protected_access ("granted" | "denied") is the check. No
# prompt can appear either way — the collector never touches a per-folder
# TCC location in a scheduled run (audit-device.sh: AUDIT_INCLUDE_PROTECTED
# stays 0; protected folders are reached only under FDA, probed via TCC.db,
# which never prompts), and a process outside any GUI session has no UI to
# prompt in.
#
# Kick off a run by hand: `sudo launchctl kickstart -k system/com.rh7.collector-runner`.
# Logs: /tmp/com.rh7.collector-runner.{out,err}.log (launchd) and the runner's
# own ~<user>/.cache/fleet-collector/runner.log.
{ config, lib, ... }:

let
  cfg = config.services.rh7.fleetAudit;
  time = import ../fleet-audit-time.nix;
  label = "com.rh7.collector-runner";
in
{
  options.services.rh7.fleetAudit.scheduler = lib.mkOption {
    type = lib.types.enum [ "user-agent" "system-daemon" ];
    default = "user-agent";
    description = ''
      launchd domain of the daily fleet audit: "user-agent" = home-manager's
      gui LaunchAgent in the primary user's account (runs only while she is
      logged in); "system-daemon" = a LaunchDaemon that runs the same audit as
      the primary user regardless of who is logged in (household Macs).
    '';
  };

  config = lib.mkIf (cfg.scheduler == "system-daemon") {
    launchd.daemons.fleet-audit.serviceConfig = {
      Label = label;
      # The launcher rebuilds the environment (fixed PATH, HOME from the
      # password database); rh7-fleet-audit sets the tool PATH itself.
      ProgramArguments = [ "/usr/local/libexec/rh7-fleet-launcher" "audit" ];
      UserName = config.system.primaryUser;
      GroupName = "staff";
      StartCalendarInterval = [ { Hour = time.hour; Minute = time.minute; } ];
      RunAtLoad = false; # no audit on every boot/rebuild — once a day
      # Same files as the agent's. launchd opens them for the job; the old
      # agent left them owned by this same user, and /tmp is cleared at boot.
      StandardOutPath = "/tmp/${label}.out.log";
      StandardErrorPath = "/tmp/${label}.err.log";
    };
  };
}
