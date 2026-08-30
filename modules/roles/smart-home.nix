{ ... }:

{
  # ── Smart Home: Mac Mini office hub ──────────────────────────────────────
  homebrew.casks = [
    "sonos"
    # home-assistant — declared fleet-wide in modules/roles/workstation-mac.nix
    # sensibo, homey — Mac App Store only
  ];
}
