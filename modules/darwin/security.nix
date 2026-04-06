{ ... }:

{
  # ── Security hardening (enforced on every darwin-rebuild switch) ────────
  # Ensures firewall and Gatekeeper are always enabled, preventing drift.
  # See: rh7/rh-device-management#19, #29, #33

  system.activationScripts.postActivation.text = ''
    # Enable application firewall
    /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on >/dev/null 2>&1 || true
    # Enable Gatekeeper (app notarization enforcement)
    spctl --master-enable 2>/dev/null || true
  '';
}
