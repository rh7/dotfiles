{ lib, ... }:

{
  home.username      = lib.mkDefault "rouvenheck";
  home.homeDirectory = lib.mkDefault "/Users/rouvenheck";
  home.stateVersion  = "24.11";
  programs.home-manager.enable = true;

  # ── Profiles (shared, deduplicated) ──────────────────────────────────────
  imports = [
    ../../modules/home/profiles/development.nix
    ../../modules/home/profiles/editor.nix
    ../../modules/home/profiles/browser.nix
  ];
}
