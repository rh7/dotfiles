{ pkgs, ... }:

{
  # ── Media apps (NixOS) ───────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    spotify
    vlc
  ];
}
