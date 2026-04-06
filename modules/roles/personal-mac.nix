{ ... }:

{
  # ── Personal: lighter macOS setup for non-developers ─────────────────────
  # For family members who don't need dev tools.
  imports = [
    ../darwin/profiles/core.nix
    ../darwin/profiles/productivity.nix
    ../darwin/profiles/ai-tools.nix
    ../darwin/profiles/media.nix
  ];

  # Personal-specific apps (not in shared profiles)
  homebrew.casks = [
    "signal"
    "discord"
  ];

  # ── Dock apps (personal Macs — lighter than workstation) ────────────────
  system.defaults.dock.persistent-others = [];
  system.defaults.dock.persistent-apps = [
    "/Applications/Arc.app"
    "/Applications/Google Chrome.app"
    "/Applications/Claude.app"
    "/Applications/Superhuman.app"
    "/Applications/Telegram.app"
    "/Applications/Signal.app"
    "/Applications/Discord.app"
    "/System/Applications/Messages.app"
    "/System/Applications/Reminders.app"
    "/Applications/Spotify.app"
    "/Applications/Obsidian.app"
  ];
}
