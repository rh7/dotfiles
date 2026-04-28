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
    mas_install() { /opt/homebrew/bin/mas install "$1" 2>/dev/null || echo "[WARN] Failed to install $2 from App Store — sign in manually and run: mas install $1"; }
    mas_install 1278508951 "Trello"
    mas_install 963034692  "Streaks"
  '';
}
