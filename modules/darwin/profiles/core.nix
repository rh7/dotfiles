{ ... }:

{
  # ── Core macOS apps (every Mac gets these) ───────────────────────────────
  homebrew.casks = [
    "1password"
    "google-chrome"
    "arc"
    "firefox"
    "dia"
    "raycast"
    "dropbox"
    "obsidian"
    "tailscale-app"
    "speedtest"
  ];

  homebrew.brews = [
    "mas"        # Mac App Store CLI
    "mackup"     # settings sync
  ];

  homebrew.masApps = {
    "Perplexity" = 6714467650;
    "Endel" = 1346247457;
  };
}
