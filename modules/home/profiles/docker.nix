{ pkgs, ... }:

{
  # ── Docker tools (Linux only — macOS uses OrbStack) ──────────────────────
  home.packages = with pkgs; [
    docker-compose
  ];
}
