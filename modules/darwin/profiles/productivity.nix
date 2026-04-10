{ ... }:

{
  # ── Productivity apps ────────────────────────────────────────────────────
  homebrew.casks = [
    "slack"
    "zoom"
    "superhuman"
    "granola"
    "clockify"
    "notion"
    # "linear-linear"  # not in use
    "reader"  # Readwise Reader
    "session"
    # ulysses, remarkable — Mac App Store only
    "grammarly-desktop"
  ];

  # Mac App Store apps: install manually via App Store app.
  # `mas` CLI auto-install is unreliable on recent macOS — it prompts for
  # Apple ID auth non-interactively and fails the whole brew bundle.
  # homebrew.masApps = {
  #   "Trello" = 1278508951;
  #   "Streaks" = 963034692;
  # };
}
