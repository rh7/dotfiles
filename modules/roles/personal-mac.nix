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
    "whatsapp"
    "canva"
    "adobe-creative-cloud"   # includes Lightroom
    # "roomsketcher"         # not in Homebrew — manual install
    # "coldread"             # not in Homebrew — manual install
  ];

  # ── Dock apps (based on Kassie's M1 dock) ──────────────────────────────
  system.defaults.dock.persistent-others = [];
  system.defaults.dock.persistent-apps = [
    "/Users/kassie/Applications/CC.app"
    "/Applications/Google Chrome.app"
    "/Applications/Arc.app"
    "/System/Applications/Messages.app"
    "/Applications/Superhuman.app"
    "/System/Applications/Photos.app"
    "/System/Applications/FaceTime.app"
    "/System/Applications/Calendar.app"
    "/Applications/Trello.app"
    "/System/Applications/Notes.app"
    "/System/Applications/Reminders.app"
    "/Applications/Notion.app"
    "/Applications/ChatGPT.app"
    "/Applications/Slack.app"
    "/Applications/zoom.us.app"
    "/Applications/Spotify.app"
    "/Applications/WhatsApp.app"
    "/Applications/1Password.app"
    "/Applications/Discord.app"
  ];
}
