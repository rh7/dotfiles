{ ... }:

{
  # ── Base macOS settings for EVERY Mac (mkMac imports this) ───────────────
  # Only system-level, security-relevant or harmless settings live here — no
  # per-user preference. The opinionated per-user defaults (Dock, Finder,
  # keyboard, trackpad, screenshots) are in workstation-defaults.nix and
  # Remote Login / Screen Sharing in remote-access.nix; both are imported by
  # the roles that want them, NOT by household-mac.nix.

  # ── Login window ─────────────────────────────────────────────────────────
  system.defaults.loginwindow.GuestEnabled = false;

  # ── Activation ──────────────────────────────────────────────────────────
  system.activationScripts.postActivation.text = ''
    # Keep automatic timezone on as the default. Replaces the hardcoded
    # `time.timeZone` declaration in flake.nix that used to override the
    # user's physical location on every rebuild. Requires Location Services;
    # if LS is off, this is a no-op (user can enable in System Settings).
    /usr/bin/defaults write /Library/Preferences/com.apple.timezone.auto Active -bool true 2>/dev/null || true
  '';

  # ── System ───────────────────────────────────────────────────────────────
  security.pam.services.sudo_local.touchIdAuth = true;

  # The official NixOS installer owns the org.nixos.nix-daemon LaunchDaemon (the
  # fleet migrated off Determinate); nix-darwin must NOT also manage the daemon or
  # the two conflict. setup.sh installs Nix + patches /etc/nix/nix.conf itself, so
  # keep nix.enable = false. (#49)
  nix.enable = false;

  # Required for nix-darwin (primaryUser is set per-host in mkMac)
  system.stateVersion = 6;
  nixpkgs.hostPlatform = "aarch64-darwin";
}
