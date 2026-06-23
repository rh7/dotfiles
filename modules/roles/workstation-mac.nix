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
    ../darwin/firewall.nix          # application firewall (client Macs only, #93)
  ];

  homebrew.casks = [
    "home-assistant"
    "istat-menus"
    "stremio"
  ];

  # Mac App Store apps — mas_install helper defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
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
    "/Applications/Canary Mail.app"
    "/Applications/Reader.app"
    "/Applications/Slack.app"
    "/Applications/Telegram.app"
    "/Applications/WhatsApp.app"
    "/Applications/Signal.app"
    "/Applications/Claude.app"
    "/Users/${config.system.primaryUser}/Applications/CC.app"
    "/Applications/ChatGPT.app"
    "/System/Applications/Messages.app"
    "/System/Applications/Reminders.app"
    "/Applications/Termius.app"
    "/Applications/Spotify.app"
    "/Users/${config.system.primaryUser}/Applications/Penumbra.app"
    "/Applications/Element.app"
    "/Applications/Home Assistant.app"
  ];
}
