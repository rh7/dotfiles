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
}
