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
    # TripMode was declared as a MAS app while the copy actually installed was
    # this cask (no _MASReceipt in the bundle), so one app had two sources and
    # neither fully owned it. The cask matches what is on disk; the App Store
    # licence is unaffected, it just is not the install path.
    "tripmode"
  ];

  # Mac App Store apps — mas_install helper defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    mas_install 1278508951 "Trello"
    mas_install 963034692  "Streaks"
    mas_install 1521432881 "Session Pomodoro"

    # Laptop/desktop-only utilities (moved out of core.nix so servers skip them)
    # TripMode moved to homebrew.casks above — it was declared here but the
    # installed copy came from the cask, so this line never owned the app.
    mas_install 6714467650 "Perplexity"
    mas_install 1346247457 "Endel"
  '';
}
