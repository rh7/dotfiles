{ lib, ... }:

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
