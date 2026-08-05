{ config, ... }:

{
  # ── Core macOS apps (every Mac gets these) ───────────────────────────────
  homebrew.casks = [
    "1password"
    "1password-cli"   # `op` — used by config-service secret reconciliation (rh-device-management#70)
    "google-chrome"
    "arc"
    "firefox"
    # "raycast"  # dev profile only, not for all users
    "dropbox"
    # "obsidian"  # moved to dev-apps profile
    # "expressvpn"  # install manually — cask installer helper needs GUI auth, fails under brew bundle
    # "tripmode"  # install from App Store — Homebrew cask version hangs on activation dialog
    "tailscale-app"
    # dia — no Homebrew cask / not on App Store; auto-installed from the official DMG in postActivation below
    # speedtest — Mac App Store only, not in Homebrew
  ];

  homebrew.brews = [
    "mas"        # Mac App Store CLI (kept for manual use)
    "mackup"     # settings sync
  ];

  # Note: laptop/desktop-only MAS apps (TripMode, Perplexity, Endel) live in
  # productivity.nix so they reach workstation + personal Macs but NOT servers.
  # See rh7/rh-device-management#50 for why masApps is disabled in brew bundle.
  # mas_install helper is defined in modules/darwin/mas.nix.
  system.activationScripts.postActivation.text = ''
    # ExpressVPN cask installer needs GUI auth — can't run under brew bundle.
    # Warn if missing so the user runs `brew install --cask expressvpn` once.
    [ -d "/Applications/ExpressVPN.app" ] || echo "[WARN] ExpressVPN.app missing — install once via: brew install --cask expressvpn"

    # Dia browser has no Homebrew cask and isn't on the Mac App Store, so
    # install the official DMG directly when it's missing. Guarded on Dia.app
    # so it only downloads (~800MB) on the first switch per machine. Wrapped so
    # a network failure warns instead of aborting activation.
    install_dia() {
      [ -d "/Applications/Dia.app" ] && return 0
      echo "[INFO] Installing Dia browser from diabrowser.com…"
      local dmg mnt app
      # Use the system BSD mktemp explicitly: the nixpkgs GNU mktemp on the
      # activation PATH rejects a template without XXXXXX.
      dmg="$(/usr/bin/mktemp -t dia)"; mnt="$(/usr/bin/mktemp -d -t dia-mnt)"
      if ! /usr/bin/curl -fsSL --max-time 900 -o "$dmg" \
             "https://releases.diabrowser.com/release/Dia-latest.dmg"; then
        echo "[WARN] Dia install: download failed — install once from https://www.diabrowser.com"
        /bin/rm -rf "$dmg" "$mnt"; return 0
      fi
      if ! /usr/bin/hdiutil attach -nobrowse -quiet -mountpoint "$mnt" "$dmg"; then
        echo "[WARN] Dia install: failed to mount DMG — install once from https://www.diabrowser.com"
        /bin/rm -rf "$dmg" "$mnt"; return 0
      fi
      app="$(/bin/ls -d "$mnt"/*.app 2>/dev/null | head -1)"
      if [ -n "$app" ] && /usr/bin/ditto "$app" "/Applications/Dia.app"; then
        /usr/sbin/chown -R ${config.system.primaryUser}:staff "/Applications/Dia.app"
        /usr/bin/xattr -dr com.apple.quarantine "/Applications/Dia.app" 2>/dev/null || true
        echo "[OK]   Dia installed."
      else
        echo "[WARN] Dia install: no .app found in DMG — install once from https://www.diabrowser.com"
      fi
      /usr/bin/hdiutil detach -quiet "$mnt" 2>/dev/null || true
      /bin/rm -rf "$dmg" "$mnt"
    }
    # `|| true` suspends set -e inside the function so a failure here can never
    # abort activation (postActivation runs under set -e).
    install_dia || true
  '';
}
