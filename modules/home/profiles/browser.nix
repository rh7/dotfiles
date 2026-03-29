{ pkgs, lib, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in {
  # ── Firefox ──────────────────────────────────────────────────────────────
  # Settings, extensions, bookmarks → managed by Firefox Sync (sign in once per device)
  # Nix only handles: installation + native messaging hosts (OS-level, not synced)
  programs.firefox = {
    enable = !isDarwin;  # macOS: installed via Homebrew
    nativeMessagingHosts = [
      pkgs.firefoxpwa
    ] ++ lib.optionals (!isDarwin) [
      pkgs._1password-gui
    ];
  };
}
