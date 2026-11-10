{ ... }:

{
  # ── macOS Software Update policy — CLIENT Macs only ─────────────────────────
  # Imported by the workstation-mac and personal-mac roles, NOT fleet-member-mac:
  # the Mac Studio is the control plane (config service, inference stack), and an
  # OS install there is a scheduled, attended event, never a background one.
  #
  # Policy (owner decision):
  #   check for updates automatically ............. yes
  #   download every available update ............. yes
  #   install Background Security Improvements /
  #     Rapid Security Responses + system data
  #     files (XProtect, Gatekeeper, MRT config) .. yes, automatically
  #   install regular macOS updates (26.x → 26.y) . NO — downloaded, staged, a
  #                                                 human clicks install
  #   install major upgrades (26 → 27) ............ NO — never automatic; macOS
  #                                                 itself requires consent for
  #                                                 a major upgrade without MDM
  #   App Store app updates ....................... yes (see below)
  #
  # Every key below is the backing preference of a System Settings → General →
  # Software Update → Automatic Updates toggle, in /Library/Preferences (the
  # machine domain nix-darwin writes to as root during activation). Key names
  # were checked against a macOS 26.5 host's live
  # /Library/Preferences/com.apple.SoftwareUpdate.plist and
  # /Library/Preferences/com.apple.commerce.plist.
  #
  # WHAT macOS 26+ HONORS WITHOUT MDM — read this before trusting the policy:
  #   * Honored: AutomaticCheckEnabled, AutomaticDownload, CriticalUpdateInstall,
  #     ConfigDataInstall, AutomaticallyInstallMacOSUpdates (com.apple.SoftwareUpdate)
  #     and AutoUpdate (com.apple.commerce). softwareupdated / appstored read these
  #     exact keys; they are the same values the Settings toggles write.
  #   * Best-effort, all of them, in one specific sense: without an MDM
  #     (managed preferences / Declarative Device Management
  #     `com.apple.configuration.softwareupdate.settings`) nothing is ENFORCED.
  #     The user can flip any toggle back in System Settings and macOS will obey
  #     until the next activation re-writes it. Settings may also show the old
  #     value until it is reopened (cfprefsd caching), and softwareupdated may
  #     not act on a change before its next scheduled background check.
  #   * Not controllable here at all: major upgrades. AutomaticallyInstallMacOSUpdates
  #     governs minor updates only; without MDM macOS never installs a major
  #     version unattended, whatever these keys say. There is no local key that
  #     defers or hides a major upgrade (that is an MDM-only restriction) — it is
  #     downloaded under AutomaticDownload and then waits for a human.
  #   * Rapid Security Responses / Background Security Improvements ride
  #     CriticalUpdateInstall (+ ConfigDataInstall for the data-file half); they
  #     may still need a restart, which macOS schedules itself.
  #
  # Verify on a device after a switch:
  #   defaults read /Library/Preferences/com.apple.SoftwareUpdate
  #   defaults read /Library/Preferences/com.apple.commerce AutoUpdate
  #
  # App Store AutoUpdate = true, deliberately: those updates are performed by
  # Apple's own appstored, not by `mas`, so they do NOT carry the sudo-timestamp
  # risk that keeps `mas upgrade` out of the unattended weekly agent (see
  # scripts/rebuild.sh, declared_outdated_mas). It closes the "declared App Store
  # apps never upgrade" gap between attended rebuilds. An Xcode auto-update resets
  # its license; modules/darwin/xcode-license.nix re-accepts it on every activation.

  # Native nix-darwin option (the only SoftwareUpdate option the pinned
  # nix-darwin defines); writes /Library/Preferences/com.apple.SoftwareUpdate.
  system.defaults.SoftwareUpdate.AutomaticallyInstallMacOSUpdates = false;

  # The rest have no typed nix-darwin option. CustomSystemPreferences writes each
  # domain with `defaults write <domain>` as root, so the domains are given as
  # absolute /Library/Preferences paths — a bare "com.apple.SoftwareUpdate" would
  # land in root's ~/Library/Preferences, which softwareupdated never reads.
  system.defaults.CustomSystemPreferences = {
    "/Library/Preferences/com.apple.SoftwareUpdate" = {
      AutomaticCheckEnabled = true;
      AutomaticDownload = true;
      CriticalUpdateInstall = true;
      ConfigDataInstall = true;
    };
    "/Library/Preferences/com.apple.commerce" = {
      AutoUpdate = true;
    };
  };
}
