{ pkgs, ... }:

let
  # ── Your Home Assistant instance ─────────────────────────────────────────
  # Verified reachable from the thinkpad: returns 200 and serves the Home
  # Assistant frontend. Note it is `homeassistant`, NOT `homeassistant.local` —
  # the mDNS name does not resolve on this network, so the .local form (the
  # usual first guess) fails. An earlier draft pointed at https://ha.rh7labs.com,
  # which resolves but 404s on every path.
  #
  # Swap in a Nabu Casa remote URL if you want this to work off the LAN.
  url = "http://homeassistant:8123/";

  # Official logo. A .desktop `Icon=` name is resolved against installed icon
  # themes only, and no theme ships a Home Assistant icon — so we install one.
  logo = pkgs.fetchurl {
    url = "https://brands.home-assistant.io/homeassistant/icon.png";
    hash = "sha256-thnaMhzd9GtWWqZMXxZ18M7RpEXr8j9uKUEwYdbpJcA=";
  };
in
{
  # ── Home Assistant (Linux) ───────────────────────────────────────────────
  # Linux has no Companion app: the macOS `home-assistant` cask is macOS/iOS/
  # Android only, and nixpkgs' `home-assistant` is the *server*, not a client.
  # Chrome's --app mode is the closest equivalent — a chromeless window that
  # reuses the already-logged-in Chrome profile. Same idea as the `stub` engine
  # in scripts/pwa-apps.sh, which only emits macOS .app bundles.
  #
  # google-chrome itself comes from modules/nixos/desktop.nix (system-wide), so
  # this is deliberately a bare binary name rather than a ${pkgs.google-chrome}
  # store path — referencing the package here would pull a second copy into the
  # user profile.
  home.file.".local/share/icons/hicolor/256x256/apps/home-assistant.png".source = logo;

  xdg.desktopEntries.home-assistant = {
    name = "Home Assistant";
    genericName = "Home Automation";
    comment = "Home Assistant dashboard";
    exec = "google-chrome-stable --app=${url}";
    icon = "home-assistant";
    terminal = false;
    categories = [ "Utility" ];
  };
}
