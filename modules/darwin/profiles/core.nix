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

  # Note: laptop/desktop-only MAS apps (TripMode, Perplexity, Endel) live in
  # productivity.nix so they reach workstation + personal Macs but NOT servers.
  # See rh7/rh-device-management#50 for why masApps is disabled in brew bundle.
}
