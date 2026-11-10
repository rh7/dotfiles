{ config, lib, ... }:

{
  # Packages that scripts/rebuild.sh upgrades on a default run
  # (`--upgrade=critical`). Everything else that is outdated waits for an
  # explicit `rebuild.sh --upgrade=all`. Homebrew has no notion of a security
  # or "critical" update, so this curated list stands in for one: software that
  # faces the network or holds credentials, where staying current matters.
  #
  # Names are Homebrew formula/cask names, or Mac App Store ids as strings.
  # Listing something a host does not declare is harmless — rebuild.sh only
  # upgrades the intersection with what the host actually declares. Profiles
  # may append (lists merge).
  options.dotfiles.homebrew.criticalUpgrades = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Declared packages that rebuild.sh upgrades by default.";
  };

  # Casks that scripts/rebuild.sh UNINSTALLS wherever they are still present.
  # This is the fleet's removal path: cleanup = "none" (below) means dropping a
  # cask from a profile never removes it from a machine, so retirements used to
  # be hand-run `brew uninstall`s — each its own unexplained Touch ID prompt.
  # Listed here, the removal shows in the rebuild plan and runs inside that
  # run's single authentication. Profiles may append (lists merge).
  options.dotfiles.homebrew.retiredCasks = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Casks rebuild.sh uninstalls if installed. Must not also be declared.";
  };

  config = {
    dotfiles.homebrew.criticalUpgrades = [
      # Browsers
      "google-chrome" "firefox" "arc" "brave-browser"
      # Passwords / encryption
      "1password" "1password-cli" "cryptomator" "gpg-suite-no-mail"
      # VPN / network
      "tunnelblick" "protonvpn" "tailscale-app"
      # Messengers
      "signal" "whatsapp" "element" "telegram" "slack" "zoom"
    ];

    # Record the reason and date with each entry; archive.nix keeps the
    # long-form history of why an app was dropped.
    dotfiles.homebrew.retiredCasks = [
      "session"   # onion-routing messenger, NOT Session Pomodoro (MAS). 2026-11-09
      "stremio"   # never opened. 2026-11-09
    ];

    # A cask both declared and retired would be installed by activation and
    # then uninstalled by rebuild.sh on every run. Fail the build instead.
    assertions =
      let
        declared = map (c: c.name) config.homebrew.casks;
        both = lib.filter (c: lib.elem c declared) config.dotfiles.homebrew.retiredCasks;
      in [{
        assertion = both == [ ];
        message = "dotfiles.homebrew.retiredCasks also declared in homebrew.casks: ${lib.concatStringsSep ", " both}";
      }];

    # ── Homebrew scaffold (managed declaratively by nix-darwin) ──────────────
    # App lists have been moved to modules/darwin/profiles/ and modules/roles/.
    # This file only configures Homebrew behavior.
    homebrew = {
      enable = true;

      onActivation = {
        autoUpdate = true;
        # Activation only INSTALLS missing packages; it never upgrades.
        # Upgrades happen in scripts/rebuild.sh after activation, selected by
        # --upgrade=critical|all|none. Two reasons they cannot live here:
        #   - this flag is baked into the activation script, and brew runs
        #     there under `sudo --preserve-env=PATH`, which strips any env var
        #     (HOMEBREW_BUNDLE_NO_UPGRADE) a runtime flag could pass through;
        #   - one failed download (flaky network) made `brew bundle` exit
        #     nonzero, failing the whole activation and everything after it.
        upgrade = false;
        # "zap" removes anything not listed — uncomment once you're confident
        # cleanup = "zap";
        # cleanup = "uninstall";  # disabled: brew now refuses --cleanup without
        # --force / HOMEBREW_ASK, and sudo strips the env in nix-darwin's activate
        # script. audit-config-drift.sh catches unlisted casks anyway.
        cleanup = "none";
      };

      taps = [
      ];
    };
  };
}
