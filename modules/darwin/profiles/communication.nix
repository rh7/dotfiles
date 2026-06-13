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
    # "wire"  # deprecated cask, fails Gatekeeper (disabled 2026-09-01)
    "proton-mail"
    # element-x, telegram-lite — Mac App Store only
  ];

  # Mac App Store apps — mas_install helper defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    mas_install 1236045954 "Canary Mail"
  '';
}
