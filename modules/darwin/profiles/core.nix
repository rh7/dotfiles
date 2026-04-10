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
    "tripmode"
    "tailscale-app"
    # dia, speedtest — Mac App Store only, not in Homebrew
  ];

  homebrew.brews = [
    "mas"        # Mac App Store CLI (kept for manual use)
    "mackup"     # settings sync
  ];

  # masApps disabled — `mas` install fails non-interactively on modern macOS,
  # which breaks the entire `darwin-rebuild switch` brew bundle phase.
  # Tracked as App Store manual installs in the post-setup checklist instead.
  # See rh7/rh-device-management#50.
  # homebrew.masApps = {
  #   "Perplexity" = 6714467650;
  #   "Endel" = 1346247457;
  # };
}
