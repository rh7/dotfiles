{ ... }:

{
  # ── Productivity apps ────────────────────────────────────────────────────
  homebrew.casks = [
    "slack"
    "zoom"
    "superhuman"
    "granola"
    "clockify"
    "notion"
    # "linear-linear"  # not in use
    "reader"  # Readwise Reader
    # ulysses, remarkable — Mac App Store only
    "grammarly-desktop"
    # TripMode: the CASK, not the Mac App Store build. Both exist and can be
    # installed at once (ch.tripmode.TripMode at /Applications/TripMode.app vs
    # com.alix-sarl.TripMode at /Applications/TripMode.localized/TripMode.app),
    # which is how this machine ended up with both.
    #
    # The cask is the one that works: it owns the activated network
    # FilterExtension (ch.tripmode.TripMode.FilterExtension), which is the whole
    # product — a MAS switch would mean tearing down an approved system
    # extension and re-approving another. The MAS copy had never been launched.
    #
    # It is an `auto_updates` cask, so Homebrew installs it once and Sparkle
    # keeps it current; brew will not upgrade it, and that is expected.
    "tripmode"
  ];

  # Mac App Store apps — mas_install helper defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    mas_install 1278508951 "Trello"
    mas_install 963034692  "Streaks"
    mas_install 1521432881 "Session Pomodoro"

    # Laptop/desktop-only utilities (moved out of core.nix so servers skip them)
    # TripMode is declared as a cask above — see the note there for why the
    # App Store build is not used. Do not re-add mas_install for it.
    mas_install 6714467650 "Perplexity"
    mas_install 1346247457 "Endel"
  '';
}
