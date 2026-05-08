{ lib, ... }:

{
  # ── Shared mas_install helper for postActivation MAS installs ──────────
  # Defined ahead of every caller via lib.mkBefore so role/profile modules
  # can just call `mas_install ID "Name"` without redefining the helper.
  #
  # Behaviour:
  #   1. `mas list` reads local App Store receipts — no network or auth
  #      required, safe under root activation. Skip if app already installed.
  #   2. On failure, surface the actual `mas install` error instead of a
  #      generic "sign in manually" so transient failures can be diagnosed.
  system.activationScripts.postActivation.text = lib.mkBefore ''
    mas_install() {
      local id="$1" name="$2" err
      if /opt/homebrew/bin/mas list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; then
        return 0
      fi
      err=$(/opt/homebrew/bin/mas install "$id" 2>&1) || \
        echo "[WARN] mas install $id ($name) failed: $err — sign in manually if needed"
    }
  '';
}
