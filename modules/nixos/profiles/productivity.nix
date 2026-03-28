{ pkgs, ... }:

{
  # ── Productivity apps (NixOS) ────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    obsidian
    notion-app-enhanced
  ];
}
