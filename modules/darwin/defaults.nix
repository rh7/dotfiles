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
    TrackpadThreeFingerDrag = true;
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
    killall Finder || true
  '';

  # ── System ───────────────────────────────────────────────────────────────
  security.pam.services.sudo_local.touchIdAuth = true;

  # Determinate Nix manages its own daemon — don't let nix-darwin conflict
  nix.enable = false;

  # Required for nix-darwin (primaryUser is set per-host in mkMac)
  system.stateVersion = 6;
  nixpkgs.hostPlatform = "aarch64-darwin";
}
