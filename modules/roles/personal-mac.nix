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
}
