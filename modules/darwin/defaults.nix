{ ... }:

{
  # ── Dock ─────────────────────────────────────────────────────────────────
  system.defaults.dock = {
    autohide = true;
    autohide-delay = 0.0;
    autohide-time-modifier = 0.3;
    show-recents = false;
    tilesize = 34;
    orientation = "bottom";
    mru-spaces = false;  # don't rearrange Spaces based on recent use
    wvous-tl-corner = 13;  # Lock Screen
    wvous-tr-corner = 2;   # Mission Control
    wvous-br-corner = 3;   # Application Windows
    # Dock apps are set per-role in modules/roles/*.nix
  };

  # ── Finder ───────────────────────────────────────────────────────────────
  system.defaults.finder = {
    AppleShowAllExtensions = true;
    AppleShowAllFiles = true;
    ShowPathbar = true;
    ShowStatusBar = true;
    _FXShowPosixPathInTitle = true;
    FXDefaultSearchScope = "SCcf";  # search current folder
    FXPreferredViewStyle = "Nlsv";  # list view
  };

  # ── Desktop stacks ──────────────────────────────────────────────────────
  system.defaults.CustomUserPreferences."com.apple.finder" = {
    DesktopViewSettings = {
      GroupBy = "Kind";
      IconViewSettings = {
        arrangeBy = "dateAdded";
      };
    };
  };

  # ── Keyboard ─────────────────────────────────────────────────────────────
  system.defaults.NSGlobalDomain = {
    AppleShowAllExtensions = true;
    InitialKeyRepeat = 15;
    KeyRepeat = 2;
    NSAutomaticCapitalizationEnabled = false;
    NSAutomaticSpellingCorrectionEnabled = false;
    NSAutomaticPeriodSubstitutionEnabled = false;
    NSAutomaticDashSubstitutionEnabled = false;
    NSAutomaticQuoteSubstitutionEnabled = false;
    "com.apple.swipescrolldirection" = true;  # natural scrolling
  };

  # ── Trackpad ─────────────────────────────────────────────────────────────
  system.defaults.trackpad = {
    Clicking = true;  # tap to click
    TrackpadRightClick = true;
    TrackpadThreeFingerDrag = false;  # off so 3-finger swipe between Spaces works
  };

  # ── Screenshots ──────────────────────────────────────────────────────────
  system.defaults.screencapture = {
    location = "~/Desktop/Screenshots";
    type = "png";
    disable-shadow = true;
  };

  # ── Login window ─────────────────────────────────────────────────────────
  system.defaults.loginwindow.GuestEnabled = false;

  # ── Activation ──────────────────────────────────────────────────────────
  system.activationScripts.postActivation.text = ''
    # Enable Remote Login (sshd) for fleet management.
    # systemsetup -setremotelogin requires Full Disk Access, which launchd
    # activation scripts don't have — loading the plist directly avoids TCC.
    if ! /bin/launchctl print system/com.openssh.sshd &>/dev/null; then
      /bin/launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
    fi

    # Enable Screen Sharing (ARD). ARDAgent's kickstart binary requires TCC
    # privileges that launchd activation scripts don't have. Drive launchd
    # directly via enable + kickstart — no FDA required, both are idempotent
    # (enable is a no-op if already enabled, kickstart is a no-op if running).
    /bin/launchctl enable system/com.apple.screensharing 2>/dev/null || true
    /bin/launchctl kickstart system/com.apple.screensharing 2>/dev/null || true

    killall Finder || true

    # Keep automatic timezone on as the default. Replaces the hardcoded
    # `time.timeZone` declaration in flake.nix that used to override the
    # user's physical location on every rebuild. Requires Location Services;
    # if LS is off, this is a no-op (user can enable in System Settings).
    /usr/bin/defaults write /Library/Preferences/com.apple.timezone.auto Active -bool true 2>/dev/null || true
  '';

  # ── System ───────────────────────────────────────────────────────────────
  security.pam.services.sudo_local.touchIdAuth = true;

  # Determinate Nix manages its own daemon — don't let nix-darwin conflict
  nix.enable = false;

  # Required for nix-darwin (primaryUser is set per-host in mkMac)
  system.stateVersion = 6;
  nixpkgs.hostPlatform = "aarch64-darwin";
}
