{ pkgs, ... }:

{
  # ── Communication apps (NixOS) ───────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    telegram-desktop
    slack
    signal-desktop
    discord
    vesktop         # alternative Discord client (Vencord)
    element-desktop
    zoom-us
  ];
}
