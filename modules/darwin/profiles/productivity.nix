{ ... }:

{
  # ── Productivity apps ────────────────────────────────────────────────────
  homebrew.casks = [
    "superhuman"
    "granola"
    "clockify"
    "notion"
    "linear-linear"
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
