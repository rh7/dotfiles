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
    # NOTE: do NOT add the "session" cask here. It is the onion-routing
    # messenger (com.loki-project.messenger-desktop), which is not wanted — see
    # archive.nix. The Session that IS wanted is "Session Pomodoro Focus Timer"
    # (com.philipyoungg.session), a MAS app declared in productivity.nix. They
    # share a name but are unrelated apps from different vendors.
    # "wire"  # deprecated cask, fails Gatekeeper (disabled 2026-09-01)
    "proton-mail"
    # element-x, telegram-lite — Mac App Store only
  ];

  # Mac App Store apps — mas_install helper defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    mas_install 1236045954 "Canary Mail"
  '';
}
