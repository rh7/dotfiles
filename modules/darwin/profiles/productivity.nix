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
    # NO "tripmode" cask here — deliberately. Its installer raises a system
    # extension approval dialog that hangs `brew bundle` during activation
    # (already hit once; see the note in core.nix). Declaring it would hang
    # activation on any host that does not already have it. TripMode is
    # provisioned via the App Store instead — mas_install below.
  ];

  # Mac App Store apps — mas_install helper defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    mas_install 1278508951 "Trello"
    mas_install 963034692  "Streaks"
    mas_install 1521432881 "Session Pomodoro"

    # Laptop/desktop-only utilities (moved out of core.nix so servers skip them)
    #
    # TripMode ships as TWO different builds that coexist happily, since they
    # have different bundle ids and paths:
    #   cask  ch.tripmode.TripMode     /Applications/TripMode.app
    #   MAS   com.alix-sarl.TripMode   /Applications/TripMode.localized/TripMode.app
    # This is provisioned from the App Store because the cask hangs activation
    # (see the casks list above). On a host where the cask was installed by hand
    # it may be the build actually in use — on rouven-m5-pro the cask owns the
    # activated network FilterExtension while the MAS copy has never been
    # launched — so an undeclared TripMode cask showing up in the drift audit is
    # expected and must NOT be "fixed" by declaring it.
    mas_install 1513400665 "TripMode"
    mas_install 6714467650 "Perplexity"
    mas_install 1346247457 "Endel"
  '';
}
