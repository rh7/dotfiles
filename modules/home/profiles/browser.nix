{ pkgs, lib, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in {
  # ── Firefox (declarative config via Home Manager) ────────────────────────
  programs.firefox = {
    enable = !isDarwin;  # On macOS, Firefox is installed via Homebrew
    nativeMessagingHosts = [
      pkgs.firefoxpwa
    ] ++ lib.optionals (!isDarwin) [
      pkgs._1password-gui
    ];
    profiles.default = {
      isDefault = true;

      # Let Firefox keep user-installed extensions (don't wipe on rebuild)
      settings.extensions.autoDisableScopes = 0;

      # ── Privacy & UX settings ──────────────────────────────────────────
      settings = {
        # Privacy
        "privacy.trackingprotection.enabled" = true;
        "privacy.trackingprotection.socialtracking.enabled" = true;
        "privacy.donottrackheader.enabled" = true;
        "dom.security.https_only_mode" = true;

        # UX
        "browser.startup.homepage" = "about:blank";
        "browser.newtabpage.enabled" = false;
        "browser.tabs.warnOnClose" = false;
        "browser.shell.checkDefaultBrowser" = false;
        "browser.aboutConfig.showWarning" = false;

        # Performance
        "gfx.webrender.all" = true;
        "media.ffmpeg.vaapi.enabled" = true;

        # Disable telemetry
        "toolkit.telemetry.enabled" = false;
        "toolkit.telemetry.unified" = false;
        "datareporting.healthreport.uploadEnabled" = false;
        "datareporting.policy.dataSubmissionEnabled" = false;
        "browser.ping-centre.telemetry" = false;

        # Disable pocket
        "extensions.pocket.enabled" = false;

        # Disable sponsored content
        "browser.newtabpage.activity-stream.showSponsored" = false;
        "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;
      };

      # ── Search ─────────────────────────────────────────────────────────
      search = {
        default = "ddg";
        force = true;
      };
    };
  };

  # ── Chrome managed preferences (macOS only) ─────────────────────────────
  # Chrome is installed via Homebrew. These settings are applied via
  # managed preferences on macOS.
  home.file = lib.mkIf isDarwin {
    # Chrome bookmarks bar and settings via managed preferences
    "Library/Application Support/Google/Chrome/Default/Preferences".text = builtins.toJSON {
      # We don't force Chrome settings — use Chrome Sync for that.
      # This file is just a placeholder for future managed policies.
    };
  };
}
