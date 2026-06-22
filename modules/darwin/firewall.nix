{ ... }:

{
  # ── Application firewall — CLIENT Macs only ──────────────────────────────────
  # Imported by the workstation-mac and personal-mac roles, NOT server-mac. It is
  # deliberately kept OFF the Mac Studio (config-service host): enabling the macOS
  # application firewall there can block incoming tailnet connections to the
  # config service (the node process is unsigned). See rh7/rh-device-management#93.
  #
  # Uses the nix-darwin native `networking.applicationFirewall` option instead of a
  # postActivation `socketfilterfw --setglobalstate on` shellout. The old shellout
  # silently no-ops under macOS 15+ TCC (it ran on every rebuild yet left the
  # firewall OFF), so a `|| true` made activation look successful while the machine
  # stayed insecure. NOTE: the native option ultimately drives the same
  # socketfilterfw CLI — verify it actually flips ON after activation
  # (`/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`); if macOS
  # TCC still blocks it, escalate to a configuration profile (.mobileconfig).
  #
  # Gatekeeper is NOT managed here: `spctl --master-enable` was removed in macOS
  # 15+, so it can't be forced from code — it's a post-setup checklist item.
  networking.applicationFirewall = {
    enable = true;
    enableStealthMode = true;
  };
}
