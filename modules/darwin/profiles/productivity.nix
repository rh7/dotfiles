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
    # ulysses, remarkable — Mac App Store only
    "grammarly-desktop"
  ];

  # Mac App Store apps — mas_install helper defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    mas_install 1278508951 "Trello"
    mas_install 963034692  "Streaks"
    mas_install 1521432881 "Session Pomodoro"

    # Laptop/desktop-only utilities (moved out of core.nix so servers skip them)
    mas_install 1513400665 "TripMode"
    mas_install 6714467650 "Perplexity"
    mas_install 1346247457 "Endel"
  '';
}
