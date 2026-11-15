{ config, lib, pkgs, ... }:

# ── Mac Studio application firewall: ON, with a per-app allow-list ───────────
# rh7/mac-studio-services#920 (host baseline: firewall). Imported by
# mac-studio.nix only. The client roles keep modules/darwin/firewall.nix
# (on + stealth, no per-app rules).
#
# Until this module the firewall stayed OFF here: turned on blindly, it blocked
# the config service. Node runs that service from the nix store, ad-hoc signed,
# so macOS's "allow signed software" did not cover it (rh7/rh-device-management#93).
# Now the firewall is ON and every unsigned binary that must take connections
# from the LAN or the tailnet is named below.
#
# HOW THE FIREWALL DECIDES (socketfilterfw):
#   * Loopback is never filtered. Everything that only binds 127.0.0.1 (the
#     inference stack, LiteLLM, Open WebUI, the RAG API, Docker-published
#     ports) is unaffected. That includes what `tailscale serve` exposes:
#     tailscaled proxies those to localhost itself.
#   * Every other interface is filtered by the receiving PROCESS, the tailnet
#     included: a packet from a peer comes out of the utun device and is
#     delivered to the listening socket like LAN traffic. So both tailscaled
#     (WireGuard UDP, peer API, Tailscale SSH and serve) and any service a peer
#     reaches directly on the tailnet IP need a rule.
#   * allowSigned / allowSignedApp: Apple's own binaries and Developer-ID-signed
#     apps are allowed without a rule. That covers sshd and sshd-session, Screen
#     Sharing and ARDAgent (the out-of-band console), rapportd, sharingd, and
#     signed apps such as Dropbox — exactly as they work today.
#   * Ad-hoc / unsigned binaries need an explicit rule. With none, macOS asks
#     the logged-in user and blocks until somebody answers, which on a headless
#     box means it blocks.
#   * An explicit block rule beats the signed allowance.
#
# THE RULES (paths are the STABLE names; rh7-studio-firewall-rules resolves
# each to the real binary on every run — see scripts/studio-firewall-rules.sh):
#   allow  tailscaled (Homebrew formula, ad-hoc signed). It must stay
#          reachable: direct WireGuard paths, Tailscale SSH, `tailscale serve`.
#   allow  node, the primary user's home-manager profile — the config service
#          (rh7/rh-device-management service.sh pins its PATH there); ad-hoc
#          signed nix-store binary.
#   allow  restic rest-server — the fleet's backup target on the tailnet IP,
#          run from rh-device-management's out-link; ad-hoc signed.
#   block  ControlCenter.app — the AirPlay receiver. Nothing should cast to a
#          server. Apple-signed, so it would be allowed without this rule.
#   block  limactl (Homebrew) — colima's port forwarder republishes a
#          guest-internal service on the host's interfaces; nothing off-host
#          uses it. The guests' own traffic (hermes-lab's guest tailscaled
#          included) is outbound-initiated and is expected to keep working;
#          the owner window checks it before keeping the rule.
#
# STEALTH MODE stays OFF, as today. Stealth only stops the Mac answering
# pings and probes of closed ports. The Studio sits behind the home router
# and tailnet ACLs, so that hides nothing a peer could not learn anyway. It
# would cost the owner ping and connection-refused answers while diagnosing
# the always-on server in a window. The roaming client Macs keep stealth
# (firewall.nix).
#
# ORDER: the rules are applied BEFORE nix-darwin turns the firewall on (mkBefore
# on the networking activation step, after /etc and the per-user profile are
# linked), so no allowed listener sees a window without its rule.
let
  user = config.system.primaryUser;
  home = "/Users/${user}";

  allow = [
    "/opt/homebrew/opt/tailscale/bin/tailscaled"
    "/etc/profiles/per-user/${user}/bin/node"
    "${home}/rh-device-management/services/config-service/data/restic-rest-server/bin/rest-server"
  ];
  block = [
    "/System/Library/CoreServices/ControlCenter.app"
    "/opt/homebrew/opt/lima/bin/limactl"
  ];

  ruleArgs = lib.escapeShellArgs (
    lib.concatMap (p: [ "--allow" p ]) allow ++ lib.concatMap (p: [ "--block" p ]) block
  );

  rulesCmd = pkgs.writeShellScriptBin "rh7-studio-firewall-rules" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.gnused ]}:/usr/bin:/bin:/usr/sbin:/sbin
    exec ${pkgs.bash}/bin/bash ${../../scripts/studio-firewall-rules.sh} "$@" ${ruleArgs}
  '';
in
{
  networking.applicationFirewall = {
    enable = true;
    blockAllIncoming = false;  # block-all would drop even the allowed apps
    allowSigned = true;        # built-in: sshd, Screen Sharing, ARDAgent, …
    allowSignedApp = true;     # downloaded Developer-ID-signed apps
    enableStealthMode = false; # see STEALTH MODE above
  };

  environment.systemPackages = [ rulesCmd ];

  # The per-app rules land before `socketfilterfw --setglobalstate on`, which
  # nix-darwin's networking step runs next. A failure warns rather than aborts:
  # half an activation is worse than one missing rule, which the warning names
  # and the daemon below retries.
  system.activationScripts.networking.text = lib.mkBefore ''
    echo "configuring application firewall rules..." >&2
    if ! ${rulesCmd}/bin/rh7-studio-firewall-rules; then
      echo "warning: rh7-studio-firewall-rules could not set every rule — run: sudo rh7-studio-firewall-rules" >&2
    fi
  '';

  # Verify, not trust: macOS 15+ has silently ignored socketfilterfw before
  # (firewall.nix). Say so loudly if the global state did not come on.
  system.activationScripts.postActivation.text = ''
    if ! /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate | grep -q 'enabled'; then
      printf '\e[1;33mwarning: the application firewall is not enabled after activation (socketfilterfw --getglobalstate). See configurations/macos/mac-studio-firewall.nix.\e[0m\n' >&2
    fi
  '';

  # Re-apply every 10 minutes: a `brew upgrade tailscale` or a new rest-server
  # out-link moves a binary without a rebuild. Quiet unless it changes a rule,
  # so the log stays small. Stable path on purpose (fleet-update.nix: the plist
  # survives rebuilds); the program name is what Login Items shows.
  launchd.daemons.studio-firewall-rules.serviceConfig = {
    Label = "org.rh7.studio-firewall-rules";
    ProgramArguments = [ "/run/current-system/sw/bin/rh7-studio-firewall-rules" ];
    StartInterval = 600;
    RunAtLoad = false;
    StandardOutPath = "/var/log/rh7-studio-firewall-rules.log";
    StandardErrorPath = "/var/log/rh7-studio-firewall-rules.log";
    LowPriorityIO = true;
    Nice = 5;
  };
}
