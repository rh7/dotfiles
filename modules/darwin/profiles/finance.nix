{ ... }:

{
  # ── Finance apps ─────────────────────────────────────────────────────────
  homebrew.casks = [
    "quicken"
    # finanzguru, starmoney — Mac App Store only
  ];

  # Mac App Store apps — best-effort install via postActivation (not brew bundle).
  # See rh7/rh-device-management#50.
  system.activationScripts.postActivation.text = ''
    /opt/homebrew/bin/mas install 980888073 2>/dev/null || true  # Crypto Pro
  '';
}
