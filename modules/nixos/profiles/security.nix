{ ... }:

{
  # ── 1Password (native, not Flatpak) ─────────────────────────────────────
  # Runs unsandboxed on purpose: the Flatpak build declares `fallback-x11`,
  # so on a Wayland session Flatpak withholds the X11 socket entirely and
  # 1Password's X11-only clipboard backend fails with "Failed to open
  # clipboard" on every copy. Native gets a DISPLAY from XWayland and works.
  #
  # The module also installs the `1Password-BrowserSupport` setgid wrapper
  # that browser unlock needs — see modules/home/profiles/browser.nix, which
  # wires _1password-gui as a Firefox native messaging host.
  programs._1password-gui = {
    enable = true;
    # Backs `security.authenticatedUnlock` (unlock via system authentication).
    polkitPolicyOwners = [ "rouven" ];
  };

  # ── 1Password CLI (`op`) ────────────────────────────────────────────────
  # Matches the macOS side (modules/darwin/profiles/core.nix).
  programs._1password.enable = true;
}
