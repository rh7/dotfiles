{ lib, ... }:

{
  # ── MacBook-specific casks (not needed on desktop/studio) ────────────────
  homebrew.casks = [
    # ── Finance (Germany + US + Crypto) ──
    # "quicken"           # uncomment when needed
    # "finanzguru"
    # "starmoney"
    # "ibkr"              # Interactive Brokers

    # ── Creative ──
    # "adobe-creative-cloud"  # manual install recommended (license)

    # ── Personal ──
    "vlc"

  ];

  # ── MacBook-specific dock pins (appended after workstation-mac.nix list) ──
  # mkAfter keeps the shared dock intact and tacks personal apps on the end.
  system.defaults.dock.persistent-apps = lib.mkAfter [
    "/Users/rouvenheck/Applications/Kubera.app"
  ];
}
