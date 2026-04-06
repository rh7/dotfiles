{ ... }:

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
    "/Applications/Slack.app"
    "/Applications/Telegram.app"
    "/Applications/Signal.app"
    "/Applications/Claude.app"
    "/System/Applications/Messages.app"
    "/System/Applications/Reminders.app"
    "/Applications/Termius.app"
    "/Applications/Spotify.app"
  ];
}
