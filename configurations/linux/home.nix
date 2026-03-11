{ pkgs, ... }:

{
  home.username = "rouvenheck";
  home.homeDirectory = "/home/rouvenheck";
  home.stateVersion = "24.11";
  programs.home-manager.enable = true;
}
