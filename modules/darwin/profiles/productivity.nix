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

  homebrew.masApps = {
    "Trello" = 1278508951;
    "Streaks" = 963034692;
    "Be Focused" = 973134470;
  };
}
