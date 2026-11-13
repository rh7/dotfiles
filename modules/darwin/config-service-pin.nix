{ config, lib, ... }:

let
  cfg = config.services.rh7;
  pin = "${cfg.configServiceUrl}\n";
in
{
  # ── Config-service pin (/etc/rh7/config-service) ─────────────────────────
  # find_config_service (the shared resolver block in scripts/collector-runner.sh
  # and scripts/audit-device.sh) reads the first non-comment line of this file
  # and, when it is present, uses it and FAILS CLOSED if it does not answer.
  # Without it every collector run probes the fallbacks and warns
  # "no config-service pin on this host". Declaring it here pins every
  # nix-managed Mac; moving the service (e.g. to vps-honcho) is this one option.
  #
  # Default is the Tailscale IP, not the MagicDNS name: a pin is never re-probed,
  # so a name that does not resolve on a host with MagicDNS off (household Macs)
  # would silently stop every audit. The IP is stable for the life of the node.
  options.services.rh7.configServiceUrl = lib.mkOption {
    type = lib.types.strMatching "https?://[^[:space:]/#]+(:[0-9]+)?";
    default = "http://100.100.241.110:3456";
    description = "Config-service base URL written to /etc/rh7/config-service.";
  };

  config.environment.etc."rh7/config-service" = {
    text = pin;
    # A hand-written pin made with the resolver's own advice
    # (`echo URL | sudo tee /etc/rh7/config-service`) has exactly this content;
    # nix-darwin moves a file with a known hash aside itself instead of aborting
    # with "Unexpected files in /etc". Any other valid-URL pin is offered to be
    # moved aside by rebuild.sh's /etc preflight.
    knownSha256Hashes = [ (builtins.hashString "sha256" pin) ];
  };
}
