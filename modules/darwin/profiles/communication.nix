{ ... }:

{
  # ── Communication apps ───────────────────────────────────────────────────
  homebrew.casks = [
    "telegram"
    "franz"
    "signal"
    "discord"
    "element"
    # "wire"  # deprecated cask, fails Gatekeeper (disabled 2026-09-01)
    "proton-mail"
    # canary-mail, element-x, telegram-lite — Mac App Store only
  ];

  # Mac App Store apps — mas_install helper defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    mas_install 539883307 "LINE"
  '';
}
