{ pkgs, lib, ... }:

{
  # ── Media apps (NixOS) ───────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    vlc
  ] ++ lib.optionals (pkgs.stdenv.hostPlatform.system != "aarch64-linux") [
    spotify  # not available on aarch64-linux
  ];
}
