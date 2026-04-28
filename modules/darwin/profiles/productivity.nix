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

  # Mac App Store apps — best-effort install via postActivation (not brew bundle).
  # See rh7/rh-device-management#50.
  system.activationScripts.postActivation.text = ''
    /opt/homebrew/bin/mas install 1278508951 2>/dev/null || true  # Trello
    /opt/homebrew/bin/mas install 963034692  2>/dev/null || true  # Streaks
  '';
}
