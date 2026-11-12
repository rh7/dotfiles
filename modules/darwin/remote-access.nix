{ lib, ... }:

{
  # ── Remote Login (sshd) + Screen Sharing for fleet management ────────────
  # Imported by the workstation / server / fleet-member / personal roles. NOT
  # imported by household-mac.nix: on a shared household Mac both stay exactly
  # as the owner set them in System Settings → General → Sharing (the role
  # asserts that no module turns them on).
  #
  # mkOrder 998: just ahead of every default-priority block, i.e. the slot
  # this had when it lived in defaults.nix.
  system.activationScripts.postActivation.text = lib.mkOrder 998 ''
    # Enable Remote Login (sshd) for fleet management.
    # systemsetup -setremotelogin requires Full Disk Access, which launchd
    # activation scripts don't have — loading the plist directly avoids TCC.
    if ! /bin/launchctl print system/com.openssh.sshd &>/dev/null; then
      /bin/launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
    fi

    # Enable Screen Sharing (ARD). ARDAgent's kickstart binary requires TCC
    # privileges that launchd activation scripts don't have. Drive launchd
    # directly via enable + kickstart — no FDA required, both are idempotent
    # (enable is a no-op if already enabled, kickstart is a no-op if running).
    /bin/launchctl enable system/com.apple.screensharing 2>/dev/null || true
    /bin/launchctl kickstart system/com.apple.screensharing 2>/dev/null || true
  '';
}
