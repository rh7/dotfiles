{ ... }:

{
  # ── macOS system defaults ─────────────────────────────────────────────────
  system.defaults = {
    dock = {
      autohide                  = true;
      autohide-delay            = 0.0;
      autohide-time-modifier    = 0.2;
      show-recents              = false;
      minimize-to-application   = true;
      tilesize                  = 48;
    };
    finder = {
      AppleShowAllFiles         = true;
      ShowPathbar               = true;
      ShowStatusBar             = true;
      FXPreferredViewStyle      = "Nlsv"; # list view
      FXDefaultSearchScope      = "SCcf"; # search current folder
      _FXShowPosixPathInTitle   = true;
    };
    trackpad = {
      Clicking                  = true;  # tap to click
      TrackpadThreeFingerDrag   = true;
    };
    keyboard = {
      KeyRepeat                 = 2;
      InitialKeyRepeat          = 15;
    };
    screensaver = {
      askForPassword            = true;
      askForPasswordDelay       = 5;
    };
    NSGlobalDomain = {
      AppleInterfaceStyle                   = "Dark";
      AppleShowAllExtensions                = true;
      NSAutomaticSpellingCorrectionEnabled  = false;
      NSAutomaticCapitalizationEnabled      = false;
      NSAutomaticDashSubstitutionEnabled    = false;
      NSAutomaticQuoteSubstitutionEnabled   = false;
      "com.apple.swipescrolldirection"      = false; # disable natural scroll
    };
    CustomUserPreferences = {
      "com.apple.screencapture" = {
        location        = "~/Screenshots";
        type            = "png";
        disable-shadow  = true;
      };
    };
  };

  system.stateVersion = 5;
  nixpkgs.hostPlatform = "aarch64-darwin";
}
