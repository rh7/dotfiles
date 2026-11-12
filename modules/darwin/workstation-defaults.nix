{ config, lib, ... }:

{
  # ── Opinionated per-user macOS preferences ───────────────────────────────
  # The maintainer's taste: Dock autohide/size/hot corners, Finder list view +
  # hidden files, fast key repeat, autocorrect off, tap-to-click, screenshots
  # folder. nix-darwin writes these into system.primaryUser's preferences.
  #
  # Imported by the workstation / server / fleet-member / personal roles. NOT
  # imported by household-mac.nix: on a Mac adopted in place, the person who
  # uses it daily keeps the preferences they already have (the role asserts
  # that no user default is written at all).

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

  # ── Activation ──────────────────────────────────────────────────────────
  # mkOrder 999: just ahead of every default-priority block, i.e. the slot
  # this had when it lived in defaults.nix (after remote-access.nix's 998).
  system.activationScripts.postActivation.text = lib.mkOrder 999 ''
    # Relaunch Finder for the primary user only — the user whose Finder
    # defaults were just written. A bare `killall Finder` (activation runs as
    # root) would also kill every OTHER logged-in account's Finder on a shared
    # Mac (modules/roles/household-mac.nix). Same scoping nix-darwin uses for
    # its own Dock restart.
    killall -u ${lib.escapeShellArg config.system.primaryUser} Finder 2>/dev/null || true
  '';
}
