{ ... }:

{
  # ── Finance apps ─────────────────────────────────────────────────────────
  homebrew.casks = [
    "quicken"
    # finanzguru, starmoney — Mac App Store only
  ];

  # masApps disabled — see rh7/rh-device-management#50.
  # Crypto Pro is now a manual App Store install per the post-setup checklist.
  # homebrew.masApps = {
  #   "Crypto Pro" = 980888073;
  # };
}
