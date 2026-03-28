{ ... }:

{
  # username and homeDirectory are set by the flake
  home.stateVersion = "24.11";
  programs.home-manager.enable = true;

  # ── Profiles (shared, deduplicated) ──────────────────────────────────────
  imports = [
    ../../modules/home/profiles/development.nix
    ../../modules/home/profiles/editor.nix
    ../../modules/home/profiles/docker.nix
  ];
}
