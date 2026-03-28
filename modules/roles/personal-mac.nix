{ ... }:

{
  # ── Personal: lighter macOS setup for non-developers ─────────────────────
  # For family members who don't need dev tools.
  imports = [
    ../darwin/profiles/core.nix
    ../darwin/profiles/communication.nix
    ../darwin/profiles/media.nix
    ../darwin/profiles/security.nix
  ];

  # Personal-specific apps
  homebrew.casks = [
    "notion"
    "superhuman"
  ];
}
