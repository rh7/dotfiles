{ ... }:

{
  # ── Core macOS apps (every Mac gets these) ───────────────────────────────
  homebrew.casks = [
    "1password"
    "google-chrome"
    "arc"
    "firefox"
    # "raycast"  # dev profile only, not for all users
    "dropbox"
    # "obsidian"  # moved to dev-apps profile
    # "expressvpn"  # install manually — Homebrew cask conflicts with existing installs
    # "tripmode"  # install from App Store — Homebrew cask version hangs on activation dialog
    "tailscale-app"
    # dia, speedtest — Mac App Store only, not in Homebrew
  ];

  homebrew.brews = [
    "mas"        # Mac App Store CLI (kept for manual use)
    "mackup"     # settings sync
  ];

  # Mac App Store apps — best-effort install via postActivation (not brew bundle).
  # See rh7/rh-device-management#50 for why masApps is disabled in brew bundle.
  system.activationScripts.postActivation.text = ''
    mas_install() { /opt/homebrew/bin/mas install "$1" 2>/dev/null || echo "[WARN] Failed to install $2 from App Store — sign in manually and run: mas install $1"; }
    mas_install 1513400665 "TripMode"
    mas_install 6714467650 "Perplexity"
    mas_install 1346247457 "Endel"
  '';
}
