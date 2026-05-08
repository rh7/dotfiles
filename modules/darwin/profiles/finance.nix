{ ... }:

{
  # ── Finance apps ─────────────────────────────────────────────────────────
  homebrew.casks = [
    "quicken"
    # finanzguru, starmoney — Mac App Store only
  ];

  # Mac App Store apps — mas_install helper defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    mas_install 980888073 "Crypto Pro"
  '';
}
