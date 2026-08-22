{ ... }:

{
  # ── Communication apps ───────────────────────────────────────────────────
  homebrew.casks = [
    "telegram"
    "franz"
    "signal"
    "discord"
    "element"
    "whatsapp"
    # Session the onion-routing messenger (com.loki-project.messenger-desktop).
    # NOT the "Session Pomodoro Focus Timer" MAS app declared in
    # productivity.nix — different vendor, different bundle id
    # (com.philipyoungg.session), and it installs to
    # /Applications/Session.localized/Session.app, so the two do not collide
    # despite sharing a name.
    "session"
    # "wire"  # deprecated cask, fails Gatekeeper (disabled 2026-09-01)
    "proton-mail"
    # element-x, telegram-lite — Mac App Store only
  ];

  # Mac App Store apps — mas_install helper defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    mas_install 1236045954 "Canary Mail"
  '';
}
