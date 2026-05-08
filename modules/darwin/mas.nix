{ config, lib, ... }:

{
  # ── Shared mas_install helper for postActivation MAS installs ──────────
  # Defined ahead of every caller via lib.mkBefore so role/profile modules
  # can just call `mas_install ID "Name"` without redefining the helper.
  #
  # mas 7.0.0 refuses to run as root and bails with "Failed to get sudo uid"
  # — it needs the actual user's context to access their App Store creds.
  # postActivation runs as root, so we drop privileges via `sudo -u`.
  #
  # Behaviour:
  #   1. `mas list` reads local App Store receipts only — no network/auth
  #      required. Skip if app already installed.
  #   2. On failure, surface mas's actual stderr instead of a generic
  #      "sign in manually" so transient failures can be diagnosed.
  system.activationScripts.postActivation.text = lib.mkBefore ''
    _mas() { /usr/bin/sudo -u ${config.system.primaryUser} /opt/homebrew/bin/mas "$@"; }
    mas_install() {
      local id="$1" name="$2" err
      if _mas list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; then
        return 0
      fi
      err=$(_mas install "$id" 2>&1) || \
        echo "[WARN] mas install $id ($name) failed: $err — sign in manually if needed"
    }
  '';
}
