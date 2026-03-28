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
}
