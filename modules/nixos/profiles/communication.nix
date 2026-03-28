{ pkgs, ... }:

{
  # ── Communication apps (NixOS) ───────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    telegram-desktop
    slack
    signal-desktop
    discord
    element-desktop
    zoom-us
  ];
}
