{ pkgs, ... }:

{
  home.username      = "rouvenheck";
  home.homeDirectory = "/home/rouvenheck";
  home.stateVersion  = "24.11";
  programs.home-manager.enable = true;

  # ── Linux-specific dev tools ─────────────────────────────────────────────
  home.packages = with pkgs; [
    nodejs_22
    python312
    uv
    docker-compose
  ];
}
