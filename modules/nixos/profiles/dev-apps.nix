{ pkgs, ... }:

{
  # ── Developer GUI apps (NixOS) ──────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    wezterm
    ghostty
    zed-editor
  ];

  # ── Flatpak (for proprietary apps like Termius) ─────────────────────────
  services.flatpak.enable = true;
  services.flatpak.packages = [
    "com.termius.Termius"
  ];
}
