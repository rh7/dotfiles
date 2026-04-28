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
    mas_install() { /opt/homebrew/bin/mas install "$1" 2>/dev/null || echo "[WARN] Failed to install $2 from App Store — sign in manually and run: mas install $1"; }
    mas_install 980888073 "Crypto Pro"
  '';
}
