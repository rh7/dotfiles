{ config, ... }:

{
  # ── macOS Workstation: full developer setup ──────────────────────────────
  # Composes all profiles for a developer Mac.
  imports = [
    ../darwin/profiles/core.nix
    ../darwin/profiles/dev-apps.nix
    ../darwin/profiles/communication.nix
    ../darwin/profiles/productivity.nix
    ../darwin/profiles/ai-tools.nix
    ../darwin/profiles/media.nix
    ../darwin/profiles/security.nix
  ];

  homebrew.casks = [
    "home-assistant"
    "istat-menus"
    "stremio"
  ];

  # Mac App Store apps — best-effort install via postActivation (not brew bundle).
  # See rh7/rh-device-management#50.
  system.activationScripts.postActivation.text = ''
    mas_install() { /opt/homebrew/bin/mas install "$1" 2>/dev/null || echo "[WARN] Failed to install $2 from App Store — sign in manually and run: mas install $1"; }
    mas_install 1569813296 "1Password for Safari"
    mas_install 973134470 "Be Focused"
    mas_install 980888073 "Crypto Pro"

    # Safari PWAs can't be installed declaratively — Safari generates a per-machine
    # UUID bundle ID. Warn if missing so the user creates them via "Add to Dock".
    pwa_check() { [ -d "/Users/${config.system.primaryUser}/Applications/$1.app" ] || echo "[WARN] Safari PWA '$1' missing — open $2 in Safari → File → Add to Dock"; }
    pwa_check "CC" "https://cc.rh7labs.com/"
  '';

  # ── Dock apps (shared across all workstation Macs) ──────────────────────
  # persistent-apps replaces the entire dock — no Apple defaults remain.
  # persistent-others clears the right side (Downloads, Documents folders).
  system.defaults.dock.persistent-others = [];
  system.defaults.dock.persistent-apps = [
    "/Applications/Arc.app"
    "/Applications/Google Chrome.app"
    "/Applications/Ghostty.app"
    "/Applications/Obsidian.app"
    "/Applications/Notion.app"
    "/Applications/Cursor.app"
    "/Applications/Superhuman.app"
    "/Applications/Reader.app"
    "/Applications/Slack.app"
    "/Applications/Telegram.app"
    "/Applications/Signal.app"
    "/Applications/Claude.app"
    "/Applications/ChatGPT.app"
    "/System/Applications/Messages.app"
    "/System/Applications/Reminders.app"
    "/Applications/Termius.app"
    "/Applications/Spotify.app"
    "/Users/rouvenheck/Applications/Penumbra.app"
    "/Applications/Element.app"
    "/Users/rouvenheck/Applications/CC.app"
    "/Applications/Home Assistant.app"
  ];
}
