{ config, lib, ... }:

let
  primary = config.system.primaryUser;
  hm = config.home-manager.users.${primary} or null;
  # Files home-manager links into the primary user's home. The household home
  # profile (configurations/macos/home-household.nix) leaves only the two
  # empty xdg markers home-manager always writes.
  hmFiles = if hm == null then [ ]
    else map (f: f.target) (lib.filter (f: f.enable) (lib.attrValues hm.home.file));
  hmAllowedFiles = [ ".cache/.keep" ".local/state/.keep" ];
  postActivation = config.system.activationScripts.postActivation.text;
  # Homebrew belongs to the primary user (nix-darwin runs `brew bundle` as
  # her, so /opt/homebrew must be hers). For every OTHER account a plain
  # `brew` would fail on her prefix — or, worse, write files into it she can
  # no longer update. This shell function makes `brew` from another ADMIN
  # account run as her (the same `sudo -u <primary> -H` form nix-darwin and
  # rebuild.sh use; from / because her account cannot read his home), and
  # tells a non-admin account who manages it. The primary user is unaffected.
  # System-wide (/etc/zshrc, /etc/bashrc via interactiveShellInit), NOT
  # home-manager: nobody's own dotfiles are touched.
  brewShimMarker = "# household-mac: Homebrew on this Mac belongs to";
  brewShim = lib.optionalString config.homebrew.enable ''
    ${brewShimMarker} ${primary}
    if [ "$(id -un)" != ${lib.escapeShellArg primary} ]; then
      if id -Gn | grep -qw admin; then
        brew() { (cd / && exec sudo -u ${lib.escapeShellArg primary} -H ${lib.escapeShellArg "${config.homebrew.prefix}/bin/brew"} "$@"); }
      else
        brew() { echo ${lib.escapeShellArg "Homebrew on this Mac is managed by ${primary}; ask an admin."} >&2; return 1; }
      fi
    fi
  '';
in
{
  # ── Household Mac: ADOPT an in-use, shared Mac without wiping it ───────────
  #
  # For a Mac that already has people living on it — several macOS accounts,
  # hand-installed apps, a Dock somebody arranged — brought under nix-darwin in
  # place. Every choice here is "change as little as possible for the people
  # who use it":
  #
  #   - firewall + macOS update policy (client-Mac security baseline);
  #   - NO per-user preferences: workstation-defaults.nix (Dock autohide/size/
  #     hot corners, Finder list view + hidden files, key repeat, autocorrect,
  #     tap-to-click, screenshots folder) is not imported, and no Dock list;
  #   - NO Remote Login / Screen Sharing management: remote-access.nix is not
  #     imported, so both stay as set in System Settings → General → Sharing;
  #   - NO desktop/dev/ai profiles and no role casks/MAS apps: the host file
  #     ADOPTS what is already installed (exact casks for apps already in
  #     /Applications) instead of adding anything new;
  #   - a MINIMAL home-manager (mkMac homeProfile = "household"): the daily
  #     audit agent, nothing else — the user's own dotfiles stay.
  #
  # nix-darwin's system.primaryUser (mkMac `username`) is the person who uses
  # the Mac DAILY: the daily audit (com.rh7.collector-runner) is a gui-domain
  # LaunchAgent that runs only while that account is logged in, which the
  # daily user is. Activation does NOT need her logged in: when she has no GUI
  # session (the owner adopting the Mac from his account, the nightly
  # fleet-update while she is logged out) home-household.nix's guard installs
  # the agent and launchd loads it at her next login. Other accounts (e.g. the
  # maintainer's) get nothing per-user from nix.
  #
  # ── What FIRST activation changes ────────────────────────────────────────
  # Derived from what mkMac (flake.nix) imports for EVERY Mac: modules/darwin/
  # {defaults,homebrew,mas,xcode-license,fleet-update,restic-backup,
  # fleet-launcher}.nix, this role, and home-manager for the primary user
  # (configurations/macos/home-household.nix + modules/home/profiles/
  # fleet-audit.nix).
  #
  # (a) SYSTEM-WIDE (affects every account on the Mac):
  #   - application firewall ON + stealth mode (firewall.nix), with built-in
  #     and downloaded SIGNED software allowed automatically (below) — no
  #     "accept incoming network connections?" prompt for signed apps;
  #   - software-update policy in /Library/Preferences: check + download
  #     automatically, security responses / XProtect data install
  #     automatically, macOS updates staged but NOT installed, and App Store
  #     app auto-update ON — for every account's App Store apps
  #     (software-update.nix);
  #   - Touch ID for sudo (pam sudo_local) — for every admin account;
  #   - guest login disabled; automatic time zone on (defaults.nix);
  #   - /etc/zshrc, /etc/zshenv, /etc/zprofile, /etc/bashrc become nix-darwin's
  #     (originals kept as *.before-nix-darwin): nix on PATH for every account.
  #     The zsh prompt and Terminal.app integration are kept as macOS ships
  #     them (below); what does change for a shell that does not override it
  #     in ~/.zshrc: history 2000/2000 shared across sessions with duplicates
  #     ignored (macOS: 2000/1000), emacs keymap, compinit;
  #   - root LaunchDaemon org.rh7.fleet-update (nightly unattended switch from
  #     the host's channel), /usr/local/libexec/rh7-fleet-launcher, and the
  #     nix system profile in /run/current-system;
  #   - Homebrew `brew bundle` (run as the primary user) installs the host's
  #     declared casks into /Applications. /opt/homebrew must therefore be
  #     owned by the primary user (rebuild.sh offers the chown). In every
  #     OTHER account's interactive zsh/bash, `brew` is a function from
  #     /etc/zshrc|bashrc: admins run it as `sudo -u <primary> -H brew …`
  #     (from /; Touch ID), non-admins get "managed by <primary>; ask an
  #     admin". Only MISSING casks are installed, never
  #     upgraded (homebrew.nix: upgrade = false) and NOTHING is ever removed
  #     (cleanup = "none", asserted below). Hand-installed apps stay as they
  #     are unless the host declares their cask — then rebuild.sh replaces
  #     the bundle with the Homebrew copy, owned by the primary user
  #     (rh7/dotfiles#116). Per-user app data in ~/Library is not touched.
  #   - NOT changed: Remote Login, Screen Sharing (asserted below); no
  #     Finder / Dock relaunch.
  #
  # (b) PRIMARY USER (the daily user):
  #   - NO user defaults: Dock, Finder, keyboard, trackpad, screenshots stay
  #     as she set them (asserted below — nothing is written);
  #   - home-manager writes no dotfile: ~/.zshrc, ~/.zshenv, ~/.zprofile,
  #     git/editor config are not linked, moved or rewritten (asserted below).
  #     It adds ~/Library/LaunchAgents/com.rh7.collector-runner.plist (daily
  #     audit 08:17), retires a legacy com.rh7.audit agent if present, creates
  #     the empty ~/.cache/.keep and ~/.local/state/.keep, and its own state
  #     under ~/.local/state/{home-manager,nix} and
  #     /etc/profiles/per-user/<user> (no tools on PATH);
  #   - declared casks replaced by rebuild.sh become owned by her.
  #
  # (c) OTHER ACCOUNTS (e.g. the maintainer): no per-user change. They see the
  #   system-wide effects above only (including the `brew` function).
  imports = [
    ../darwin/firewall.nix          # application firewall (client Macs only, #93)
    ../darwin/software-update.nix   # macOS update policy (client Macs only)
  ];

  # Signed software never triggers the firewall's "Do you want the application
  # to accept incoming network connections?" dialog — a prompt nobody in the
  # household should have to answer. Both are the macOS defaults; pinning them
  # keeps a stray toggle from bringing the prompts back. Unsigned apps still
  # ask. Workstations keep firewall.nix as is (household-only on purpose).
  networking.applicationFirewall = {
    allowSigned = true;      # socketfilterfw --setallowsigned on (built-in software)
    allowSignedApp = true;   # socketfilterfw --setallowsignedapp on (downloaded signed apps)
  };

  # Keep the stock macOS zsh look for every account: nix-darwin's /etc/zshrc
  # would otherwise switch the default prompt to `prompt suse` and drop the
  # Terminal.app integration (/etc/zshrc_Apple_Terminal: per-tab history,
  # working-directory restore). Both lines are copied from macOS's /etc/zshrc.
  programs.zsh.promptInit = ''PS1="%n@%m %1~ %# "'';
  programs.zsh.interactiveShellInit = ''
    [ -r "/etc/zshrc_$TERM_PROGRAM" ] && . "/etc/zshrc_$TERM_PROGRAM"
  '' + brewShim;
  programs.bash.interactiveShellInit = brewShim;

  assertions = [
    # Never let a household Mac lose an app to Homebrew cleanup: "zap" /
    # "uninstall" would remove every hand-installed cask the host does not
    # list, i.e. the other accounts' apps. homebrew.nix already sets "none";
    # this makes an override from a host file, profile or future role a build
    # failure.
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
    # No system.defaults.* user-domain setting at all (Dock, Finder,
    # NSGlobalDomain, trackpad, screencapture, CustomUserPreferences, …):
    # nix-darwin emits the userDefaults activation step only when one is set.
    {
      assertion = config.system.activationScripts.userDefaults.text == "";
      message = "household-mac: no per-user macOS defaults may be written — "
        + "is modules/darwin/workstation-defaults.nix (or another system.defaults "
        + "user domain) imported?";
    }
    # Remote Login and Screen Sharing stay as the owner set them.
    {
      assertion = config.services.openssh.enable != true
        && !(lib.hasInfix "com.openssh.sshd" postActivation)
        && !(lib.hasInfix "com.apple.screensharing" postActivation);
      message = "household-mac: Remote Login / Screen Sharing must not be enabled "
        + "— is modules/darwin/remote-access.nix imported?";
    }
    # The daily user's own dotfiles stay: home-manager may link nothing into
    # her home beyond the empty xdg markers (mkMac homeProfile = "household").
    {
      assertion = lib.all (f: lib.elem f hmAllowedFiles) hmFiles;
      message = "household-mac: home-manager for ${primary} must not manage files "
        + "in her home (got: ${lib.concatStringsSep ", " hmFiles}) — use mkMac "
        + "homeProfile = \"household\" and no file-writing extraHomeModules.";
    }
    # The brew shim must reach both system-wide shell files (a disabled
    # programs.zsh/bash or an override would silently drop it, and other
    # accounts' `brew` would write into the primary user's prefix).
    {
      assertion = !config.homebrew.enable
        || (lib.hasInfix brewShimMarker config.environment.etc."zshrc".text
          && lib.hasInfix brewShimMarker config.environment.etc."bashrc".text);
      message = "household-mac: the Homebrew shell function for non-${primary} "
        + "accounts is missing from /etc/zshrc or /etc/bashrc — are programs.zsh "
        + "and programs.bash enabled?";
    }
  ];
}
