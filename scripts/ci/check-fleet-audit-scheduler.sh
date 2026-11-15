#!/usr/bin/env bash
# Eval-level check: WHICH launchd job runs each Mac's daily audit
# (services.rh7.fleetAudit.scheduler, modules/darwin/fleet-audit.nix).
#
#   household hosts — a SYSTEM LaunchDaemon /Library/LaunchDaemons/
#     com.rh7.collector-runner.plist running the fleet launcher's `audit` job
#     AS the primary user (launchd UserName) daily at 08:17, not at load; the
#     primary user's home-manager declares NO LaunchAgent and retires the
#     agent of earlier generations before setupLaunchAgents.
#   every other host — unchanged: home-manager's gui LaunchAgent with the same
#     label/program/time, and no such daemon.
#
# Run from the repo root (flake-check.yml). Exit 0 ok, 1 any failure.
set -euo pipefail

# Hosts with role = ./modules/roles/household-mac.nix in flake.nix (same list
# as check-household-brew-shim.sh).
HOUSEHOLD_HOSTS="kassie-mbp-m1"
LABEL="com.rh7.collector-runner"

fail=0
bad() { echo "::error::$*"; fail=1; }

# One summary per host: the daemon's serviceConfig (or null), the primary
# user's enabled LaunchAgents with their config, and the retirement step.
SUMMARY='c: let
  u = c.system.primaryUser;
  hm = c.home-manager.users.${u};
  d = c.launchd.daemons;
  daemons = builtins.filter (n: (d.${n}.serviceConfig.Label or null) == "'"$LABEL"'") (builtins.attrNames d);
  agents = builtins.filter (n: hm.launchd.agents.${n}.enable) (builtins.attrNames hm.launchd.agents);
  act = hm.home.activation;
in {
  user = u;
  scheduler = c.services.rh7.fleetAudit.scheduler;
  daemon = if daemons == [ ] then null else
    let s = d.${builtins.head daemons}.serviceConfig; in {
      inherit (s) Label ProgramArguments UserName GroupName StartCalendarInterval RunAtLoad;
      plist = c.environment.launchDaemons ? "'"$LABEL"'.plist";
    };
  agents = map (n: { name = n; inherit (hm.launchd.agents.${n}.config) Label ProgramArguments StartCalendarInterval RunAtLoad; }) agents;
  retire = if act ? retireUserAuditAgent then { inherit (act.retireUserAuditAgent) before after; } else null;
}'

hosts=$(nix eval --json '.#darwinConfigurations' --apply 'builtins.attrNames' | jq -r '.[]')
[[ -n "$hosts" ]] || { bad "no darwinConfigurations found"; exit 1; }

for h in $hosts; do
  s=$(nix eval --json ".#darwinConfigurations.\"$h\".config" --apply "$SUMMARY")
  user=$(jq -r .user <<<"$s")
  # Unset launchd keys evaluate to null (Day/Month/Weekday): drop them.
  q() { jq -cS "$1"' | walk(if type == "object" then with_entries(select(.value != null)) else . end)' <<<"$s"; }
  if [[ " $HOUSEHOLD_HOSTS " == *" $h "* ]]; then
    [[ $(q .scheduler) == '"system-daemon"' ]] || bad "$h: scheduler is $(q .scheduler), want system-daemon"
    want=$(jq -cn --arg u "$user" --arg l "$LABEL" '{Label: $l,
      ProgramArguments: ["/usr/local/libexec/rh7-fleet-launcher", "audit"],
      UserName: $u, GroupName: "staff",
      StartCalendarInterval: [{Hour: 8, Minute: 17}], RunAtLoad: false, plist: true}')
    [[ $(q .daemon) == "$(jq -cS . <<<"$want")" ]] \
      || bad "$h: audit daemon is $(q .daemon), want $want"
    [[ $(q .agents) == "[]" ]] || bad "$h: home-manager for $user still declares LaunchAgents: $(q .agents)"
    [[ $(q '.retire.before | index("setupLaunchAgents") != null') == true \
      && $(q '.retire.after | index("writeBoundary") != null') == true ]] \
      || bad "$h: retireUserAuditAgent must run after writeBoundary and before setupLaunchAgents, got $(q .retire)"
    echo "$h: system LaunchDaemon $LABEL as $user at 08:17; no home-manager LaunchAgent"
  else
    [[ $(q .scheduler) == '"user-agent"' ]] || bad "$h: scheduler is $(q .scheduler), want user-agent"
    [[ $(q .daemon) == null ]] || bad "$h: not a household host but has the audit LaunchDaemon: $(q .daemon)"
    want=$(jq -cn --arg l "$LABEL" '[{name: "fleet-audit", Label: $l,
      ProgramArguments: ["/usr/local/libexec/rh7-fleet-launcher", "audit"],
      StartCalendarInterval: {Hour: 8, Minute: 17}, RunAtLoad: false}]')
    [[ $(q '[.agents[] | select(.name == "fleet-audit")]') == "$(jq -cS . <<<"$want")" ]] \
      || bad "$h: home-manager audit agent is $(q .agents), want $want"
    [[ $(q .retire) == null ]] || bad "$h: not a household host but retires the audit agent"
    echo "$h: home-manager LaunchAgent $LABEL at 08:17 (unchanged)"
  fi
done

[[ $fail -eq 0 ]] || exit 1
echo "fleet audit scheduler: OK"
