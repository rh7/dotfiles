{ ... }:

{
  # ── Core macOS apps (every Mac gets these) ───────────────────────────────
  homebrew.casks = [
    "1password"
    "1password-cli"   # `op` — used by config-service secret reconciliation (rh-device-management#70)
    "google-chrome"
    "arc"
    "firefox"
    # "raycast"  # dev profile only, not for all users
    "dropbox"
    # "obsidian"  # moved to dev-apps profile
    # "expressvpn"  # install manually — cask installer helper needs GUI auth, fails under brew bundle
    # "tripmode"  # install from App Store — Homebrew cask version hangs on activation dialog
    "tailscale-app"
    # dia — manual download only (no Homebrew cask, not on App Store); see postActivation warning below
    # speedtest — Mac App Store only, not in Homebrew
  ];

  homebrew.brews = [
    "mas"        # Mac App Store CLI (kept for manual use)
    "mackup"     # settings sync
  ];

  # Note: laptop/desktop-only MAS apps (TripMode, Perplexity, Endel) live in
  # productivity.nix so they reach workstation + personal Macs but NOT servers.
  # See rh7/rh-device-management#50 for why masApps is disabled in brew bundle.
  # mas_install helper is defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    # ExpressVPN cask installer needs GUI auth — can't run under brew bundle.
    # Warn if missing so the user runs `brew install --cask expressvpn` once.
    [ -d "/Applications/ExpressVPN.app" ] || echo "[WARN] ExpressVPN.app missing — install once via: brew install --cask expressvpn"

    # Dia browser is distributed as a direct download only (no Homebrew cask,
    # not on the Mac App Store). Warn if missing so the user installs it once.
    [ -d "/Applications/Dia.app" ] || echo "[WARN] Dia.app missing — download once from https://www.diabrowser.com"
  '';
}
