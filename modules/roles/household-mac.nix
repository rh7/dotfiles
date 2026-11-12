{ config, ... }:

{
  # ── Household Mac: ADOPT an in-use, shared Mac without wiping it ───────────
  #
  # For a Mac that already has people living on it — several macOS accounts,
  # hand-installed apps, a dock somebody arranged — and that the maintainer
  # brings under nix-darwin in place. Every choice here is "change as little as
  # possible for the people who use it":
  #
  #   - firewall + macOS update policy (client-Mac security baseline);
  #   - NO dock management: persistent-apps / persistent-others are never set,
  #     so nix-darwin never rewrites anybody's Dock;
  #   - NO desktop/dev/ai profiles and no role casks/MAS apps: the host file
  #     ADOPTS what is already installed (exact casks for apps already in
  #     /Applications) instead of adding anything new.
  #
  # nix-darwin's system.primaryUser is the MAINTAINER's account (mkMac
  # `username`). Every per-user setting below lands in that account only. The
  # other accounts get nothing per-user from nix (multi-user home-manager is a
  # deliberate later step).
  #
  # ── What FIRST activation changes ────────────────────────────────────────
  # Derived from what mkMac (flake.nix) imports for EVERY Mac: modules/darwin/
  # {defaults,homebrew,mas,xcode-license,fleet-update,restic-backup,
  # fleet-launcher}.nix, this role, and home-manager (configurations/macos/
  # home.nix + modules/common.nix + modules/home/profiles/fleet-audit.nix) for
  # the primary user.
  #
  # (a) SYSTEM-WIDE (affects every account on the Mac):
  #   - application firewall ON + stealth mode (firewall.nix);
  #   - software-update policy in /Library/Preferences: check + download
  #     automatically, security responses / XProtect data install
  #     automatically, macOS updates staged but NOT installed, and App Store
  #     app auto-update ON — which also auto-updates the OTHER accounts'
  #     App Store apps (software-update.nix);
  #   - Remote Login (sshd) and Screen Sharing enabled for fleet management;
  #     macOS allows every account through unless access is restricted in
  #     System Settings → General → Sharing (defaults.nix);
  #   - Touch ID for sudo (pam sudo_local) — for every admin account;
  #   - guest login disabled; automatic time zone forced on (defaults.nix);
  #   - root LaunchDaemon org.rh7.fleet-update (nightly unattended switch from
  #     the host's channel), /usr/local/libexec/rh7-fleet-launcher, and the
  #     nix system profile in /run/current-system;
  #   - Homebrew `brew bundle` (run as the primary user) installs the host's
  #     declared casks into /Applications. Only MISSING casks are installed,
  #     never upgraded (homebrew.nix: upgrade = false) and NOTHING is ever
  #     removed (cleanup = "none", asserted below). Apps the other accounts
  #     installed by hand stay as they are unless the host declares their
  #     cask — then rebuild.sh replaces the bundle with the Homebrew copy
  #     (rh7/dotfiles#116). Per-user app data in ~/Library is not touched.
  #     The replaced bundle is owned by the primary user, so an in-app
  #     updater run from ANOTHER account may now ask for an admin password
  #     [inference from ownership; confirm after the first adoption];
  #   - Finder is relaunched for the primary user only (defaults.nix).
  #
  # (b) PRIMARY USER (the maintainer's account):
  #   - home-manager takes over the shell: ~/.zshrc, ~/.zshenv and other
  #     managed dotfiles become nix store symlinks. Pre-existing files are
  #     MOVED to *.hm-backup (backupFileExtension) — e.g. a ~/.zshrc carrying
  #     a `conda init` block becomes ~/.zshrc.hm-backup and conda is no longer
  #     initialised in new shells; re-add it declaratively (extraHomeModules)
  #     if it is still wanted. Also managed: starship, git config, ~/.mackup.cfg,
  #     ~/.config/zed/settings.json, ~/Desktop/Update.command,
  #     ~/.local/bin/omp-coordinator;
  #   - nix CLI toolchain in the user profile (modules/common.nix +
  #     modules/home/profiles/development.nix via configurations/macos/home.nix:
  #     node, python, rustup, …) — CLI only, no GUI apps;
  #   - com.rh7.collector-runner LaunchAgent (daily fleet audit);
  #   - user defaults (nix-darwin writes system.defaults.* user domains as
  #     primaryUser ONLY): Dock autohide/size/hot corners (NOT the app list),
  #     Finder list view + show hidden files + path/status bar, fast key
  #     repeat, autocorrect/smart quotes OFF, tap-to-click, screenshots to
  #     ~/Desktop/Screenshots.
  #
  # (c) OTHER ACCOUNTS (e.g. the main day-to-day user): no per-user change.
  #   No dotfile, no default, no Dock, no LaunchAgent, no shell change. What
  #   they DO see is system-wide: declared apps appearing / being replaced
  #   by their Homebrew copy in /Applications, App Store apps auto-updating,
  #   the firewall, and the update policy above.
  imports = [
    ../darwin/firewall.nix          # application firewall (client Macs only, #93)
    ../darwin/software-update.nix   # macOS update policy (client Macs only)
  ];

  # Never let a household Mac lose an app to Homebrew cleanup: "zap" /
  # "uninstall" would remove every hand-installed cask the host does not list,
  # i.e. the other accounts' apps. homebrew.nix already sets "none"; this makes
  # an override from a host file, profile or future role a build failure.
  assertions = [
    {
      assertion = config.homebrew.onActivation.cleanup == "none";
      message = "household-mac: homebrew.onActivation.cleanup must stay \"none\" "
        + "(got \"${config.homebrew.onActivation.cleanup}\") — zap/uninstall would "
        + "remove other accounts' hand-installed apps.";
    }
    {
      assertion = config.system.defaults.dock.persistent-apps == null
        && config.system.defaults.dock.persistent-others == null;
      message = "household-mac: dock persistent-apps/persistent-others must stay "
        + "unset — this role never manages anybody's Dock.";
    }
  ];
}
