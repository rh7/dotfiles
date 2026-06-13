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
  '';
}
