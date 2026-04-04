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
}
