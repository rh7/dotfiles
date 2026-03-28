{ pkgs, ... }:

{
  # ── Developer GUI apps (NixOS) ──────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    wezterm
    ghostty
    zed-editor
  ];
}
