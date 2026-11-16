{ config, lib, ... }:

let
  primary = config.system.primaryUser;
  # Who owns and runs Homebrew (nix-darwin's homebrew.user, default
  # primaryUser). On a household Mac whose daily user is a STANDARD account it
  # must be an admin (the host sets it): Homebrew moves a new cask's app into
  # /Applications as this user, and a standard user cannot write there —
  # Homebrew then falls back to its own `sudo cp`, asking for HER password.
  brewUser = config.homebrew.user;
  hm = config.home-manager.users.${primary} or null;
  # Files home-manager links into the primary user's home. The household home
  # profile (configurations/macos/home-household.nix) leaves only the two
  # empty xdg markers home-manager always writes.
  hmFiles = if hm == null then [ ]
    else map (f: f.target) (lib.filter (f: f.enable) (lib.attrValues hm.home.file));
  hmAllowedFiles = [ ".cache/.keep" ".local/state/.keep" ];
  # LaunchAgents the primary user's home-manager declares (none, asserted).
  hmAgents = if hm == null then [ ]
    else lib.attrNames (lib.filterAttrs (_: a: a.enable) hm.launchd.agents);
  postActivation = config.system.activationScripts.postActivation.text;
  sshdDropIns = lib.filter (n: lib.hasPrefix "ssh/sshd_config.d/" n
    && config.environment.etc.${n}.enable) (lib.attrNames config.environment.etc);
  # Homebrew belongs to homebrew.user (nix-darwin runs `brew bundle` as that
  # account, so /opt/homebrew must be its). For every OTHER account a plain
  # `brew` would fail on that prefix — or, worse, write files into it the
  # owner can no longer update. This shell function makes `brew` from another
  # ADMIN account run as the brew user (the same `sudo -u <user> -H` form
  # nix-darwin and rebuild.sh use; from / because that account may not read
  # the caller's home), and tells a non-admin account who manages it. The
  # brew user itself gets the plain command.
  # System-wide (/etc/zshrc, /etc/bashrc via interactiveShellInit), NOT
  # home-manager: nobody's own dotfiles are touched.
  brewShimMarker = "# household-mac: Homebrew on this Mac belongs to";
  brewShim = lib.optionalString config.homebrew.enable ''
    ${brewShimMarker} ${brewUser}
    if [ "$(id -un)" != ${lib.escapeShellArg brewUser} ]; then
      if id -Gn | grep -qw admin; then
        brew() { (cd / && exec sudo -u ${lib.escapeShellArg brewUser} -H ${lib.escapeShellArg "${config.homebrew.prefix}/bin/brew"} "$@"); }
      else
        brew() { echo ${lib.escapeShellArg "Homebrew on this Mac is managed by ${brewUser}; ask an admin."} >&2; return 1; }
      fi
    fi
  '';
  compInitMarker = "# household-mac: compinit skips directories other accounts own";
  compInit = lib.optionalString config.programs.zsh.enableCompletion ''
    ${compInitMarker}
    autoload -U compinit && compinit -i
  '';
  zshrc = config.environment.etc."zshrc".text;
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
  #     /Applications) instead of adding anything new — apart from the
  #     fleet-wide disk tools every Mac gets (profiles/disk-tools.nix);
  #   - a MINIMAL home-manager (mkMac homeProfile = "household"): nothing but
  #     its own state — the user's own dotfiles stay.
  #
  # nix-darwin's system.primaryUser (mkMac `username`) is the person who uses
  # the Mac DAILY, and the audit reports her account. The daily audit
  # (com.rh7.collector-runner) is a SYSTEM LaunchDaemon that runs as her
  # (services.rh7.fleetAudit.scheduler = "system-daemon", modules/darwin/
  # fleet-audit.nix) — not her gui-domain LaunchAgent, which ran only while
  # she was logged in and left days without an audit. Activation does not
  # need her logged in either: her home-manager declares no LaunchAgent
  # (asserted below), so there is nothing to load into a gui domain that may
  # not exist (the owner adopting the Mac from his account, the nightly
  # fleet-update while she is logged out). Other accounts (e.g. the
  # maintainer's) get nothing per-user from nix.
  #
  # homebrew.user — who owns and runs Homebrew — is separate from her: it
  # defaults to primaryUser, but when the daily user is a STANDARD account the
  # host must set it to an admin (kassie-mbp-m1: rouven). A standard user
  # cannot write /Applications, so Homebrew installing a new cask as her falls
  # back to its own `sudo cp` and asks for HER password — attended or not.
  #
  # ── What FIRST activation changes ────────────────────────────────────────
  # Derived from what mkMac (flake.nix) imports for EVERY Mac: modules/darwin/
  # {defaults,homebrew,mas,xcode-license,fleet-update,restic-backup,
  # fleet-launcher,profiles/disk-tools}.nix, this role, and home-manager for
  # the primary user (configurations/macos/home-household.nix +
  # modules/home/profiles/fleet-audit.nix).
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
  #     ignored (macOS: 2000/1000), emacs keymap, `compinit -i` (below);
  #   - root LaunchDaemon org.rh7.fleet-update (nightly unattended switch from
  #     the host's channel), /usr/local/libexec/rh7-fleet-launcher, and the
  #     nix system profile in /run/current-system;
  #   - LaunchDaemon com.rh7.collector-runner (/Library/LaunchDaemons): the
  #     daily audit, 08:17 (on wake if the Mac slept through it), run AS the
  #     primary user through the fleet launcher whether or not anybody is
  #     logged in. Reads her home like the old agent did, uploads to the
  #     config service; no window, no prompt (modules/darwin/fleet-audit.nix);
  #   - disk tools for every account (profiles/disk-tools.nix): dust, dua and
  #     ncdu on the system PATH (nixpkgs), the `mole` formula and the
  #     grandperspective, pearcleaner and puremac casks via Homebrew (below).
  #     Nothing runs them; they are on hand for a human;
  #   - Homebrew `brew bundle` (run as homebrew.user) installs the host's
  #     declared casks into /Applications — so that account must be able to
  #     write /Applications (an admin), and /opt/homebrew plus the app
  #     bundles of installed casks must be owned by it (rebuild.sh offers the
  #     chown, and stops before activation when the brew user cannot write
  #     /Applications). In every OTHER account's interactive zsh/bash, `brew`
  #     is a function from /etc/zshrc|bashrc: admins run it as
  #     `sudo -u <brew user> -H brew …` (from /; Touch ID), non-admins get
  #     "managed by <brew user>; ask an admin". Only MISSING casks are
  #     installed, never
  #     upgraded (homebrew.nix: upgrade = false) and NOTHING is ever removed
  #     (cleanup = "none", asserted below). Hand-installed apps stay as they
  #     are unless the host declares their cask — then rebuild.sh replaces
  #     the bundle with the Homebrew copy, owned by the brew user
  #     (rh7/dotfiles#116). Per-user app data in ~/Library is not touched.
  #   - NOT changed: Remote Login, Screen Sharing, SSH host keys and sshd
  #     config (asserted below); no Finder / Dock relaunch.
  #
  # (b) PRIMARY USER (the daily user):
  #   - NO user defaults: Dock, Finder, keyboard, trackpad, screenshots stay
  #     as she set them (asserted below — nothing is written);
  #   - home-manager writes no dotfile: ~/.zshrc, ~/.zshenv, ~/.zprofile,
  #     git/editor config are not linked, moved or rewritten (asserted below).
  #     It adds NO LaunchAgent: it removes ~/Library/LaunchAgents/
  #     com.rh7.collector-runner.plist (the audit agent of earlier
  #     generations; the system daemon above replaces it) and retires a
  #     legacy com.rh7.audit agent if present, creates the empty
  #     ~/.cache/.keep and ~/.local/state/.keep, and its own state under
  #     ~/.local/state/{home-manager,nix} and /etc/profiles/per-user/<user>
  #     (no tools on PATH);
  #   - declared casks' bundles are owned by homebrew.user, which is her only
  #     when the host leaves homebrew.user at its default.
  #
  # (c) OTHER ACCOUNTS (e.g. the maintainer): no per-user change. They see the
  #   system-wide effects above only (including the `brew` function, unless
  #   the account IS homebrew.user — then `brew` is the plain command).
  imports = [
    ../darwin/firewall.nix          # application firewall (client Macs only, #93)
    ../darwin/software-update.nix   # macOS update policy
  ];

  # Apps every household Mac gets (owner decision 2026-11-16). Plain `app`
  # casks only, so the unattended nightly fleet-update needs no password
  # (homebrew.user must still be able to write /Applications).
  homebrew.casks = [
    "superwhisper"   # dictation (self-updating)
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

  # The daily audit runs whether or not the daily user is logged in.
  services.rh7.fleetAudit.scheduler = "system-daemon";

  # Keep the stock macOS zsh look for every account: nix-darwin's /etc/zshrc
  # would otherwise switch the default prompt to `prompt suse` and drop the
  # Terminal.app integration (/etc/zshrc_Apple_Terminal: per-tab history,
  # working-directory restore). Both lines are copied from macOS's /etc/zshrc.
  programs.zsh.promptInit = ''PS1="%n@%m %1~ %# "'';
  programs.zsh.interactiveShellInit = ''
    [ -r "/etc/zshrc_$TERM_PROGRAM" ] && . "/etc/zshrc_$TERM_PROGRAM"
  '' + brewShim + compInit;
  programs.bash.interactiveShellInit = brewShim;

  # compinit with -i instead of nix-darwin's bare `compinit`. /opt/homebrew
  # belongs to homebrew.user, and `brew shellenv` (in an account's own
  # ~/.zprofile) puts $prefix/share/zsh/site-functions on fpath — so for every
  # OTHER account compaudit finds directories owned by neither root nor the
  # account, and a bare compinit asks "Ignore insecure directories and files
  # and continue [y] or abort compinit [n]?" in EVERY new shell (kassie-mbp-m1,
  # rouven's account). -i silently skips the insecure directories (it does not
  # trust them, unlike -u); for the brew user they are its own, i.e. secure,
  # so its Homebrew completions still load. A compinit in an account's own
  # ~/.zshrc is that account's business.
  programs.zsh.enableGlobalCompInit = false;

  # SSH server config stays macOS's. nix-darwin's services/openssh.nix and
  # programs/ssh.nix act even with services.openssh.enable = null (the
  # default, "let macOS manage it"): an `openssh` activation step runs
  # ssh-keygen for /etc/ssh/ssh_host_{rsa,ecdsa,ed25519}_key whenever they are
  # missing — i.e. on any Mac where Remote Login was never on, which printed
  # "Generating public/private … key pair" on kassie-mbp-m1's first activation
  # — and it links sshd_config.d drop-ins (099-host-keys, 100-nix-darwin,
  # 101-authorized-keys). Neither turns Remote Login on, but this role leaves
  # the SSH server entirely to the owner: no host keys, no sshd config. If
  # Remote Login is switched on later, macOS's own sshd-keygen-wrapper creates
  # the keys and sshd's built-in HostKey defaults find them. (The keys already
  # created on kassie-mbp-m1 are not removed — sshd is off, they are unused.)
  services.openssh.hostKeys = lib.mkForce [ ];
  environment.etc."ssh/sshd_config.d/100-nix-darwin.conf".enable = false;
  environment.etc."ssh/sshd_config.d/101-authorized-keys.conf".enable = false;

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
    # No SSH host key generation and no sshd_config.d drop-in (see above).
    {
      assertion = config.system.activationScripts.openssh.text == ""
        && sshdDropIns == [ ];
      message = "household-mac: nix-darwin must not generate SSH host keys or link "
        + "sshd config (got: ${lib.concatStringsSep ", " sshdDropIns}) — is "
        + "services.openssh.hostKeys set, or users.users.*.openssh.authorizedKeys?";
    }
    # The daily user's own dotfiles stay: home-manager may link nothing into
    # her home beyond the empty xdg markers (mkMac homeProfile = "household").
    {
      assertion = lib.all (f: lib.elem f hmAllowedFiles) hmFiles;
      message = "household-mac: home-manager for ${primary} must not manage files "
        + "in her home (got: ${lib.concatStringsSep ", " hmFiles}) — use mkMac "
        + "homeProfile = \"household\" and no file-writing extraHomeModules.";
    }
    # No home-manager LaunchAgent for her: activation often runs while she has
    # no GUI login session, and home-manager's bootstrap into gui/<uid> then
    # fails (nix-community/home-manager#9629) and aborts the whole switch.
    # A scheduled job on this role is a system LaunchDaemon instead (see
    # modules/darwin/fleet-audit.nix: UserName runs it as her).
    {
      assertion = hmAgents == [ ];
      message = "household-mac: home-manager for ${primary} must not declare "
        + "LaunchAgents (got: ${lib.concatStringsSep ", " hmAgents}) — they cannot "
        + "load while she is logged out; declare a launchd.daemons job with "
        + "UserName instead.";
    }
    {
      assertion = config.services.rh7.fleetAudit.scheduler == "system-daemon";
      message = "household-mac: the daily audit must be the system daemon "
        + "(services.rh7.fleetAudit.scheduler = \"system-daemon\").";
    }
    # The brew shim must reach both system-wide shell files (a disabled
    # programs.zsh/bash or an override would silently drop it, and other
    # accounts' `brew` would write into the brew user's prefix).
    {
      assertion = !config.homebrew.enable
        || (lib.hasInfix brewShimMarker zshrc
          && lib.hasInfix brewShimMarker config.environment.etc."bashrc".text);
      message = "household-mac: the Homebrew shell function for non-${brewUser} "
        + "accounts is missing from /etc/zshrc or /etc/bashrc — are programs.zsh "
        + "and programs.bash enabled?";
    }
    # /etc/zshrc runs compinit as `compinit -i` and not ALSO as nix-darwin's
    # bare one (see above): that one prompts other accounts about the brew
    # user's Homebrew directories in every new shell.
    {
      assertion = !config.programs.zsh.enableCompletion
        || (!config.programs.zsh.enableGlobalCompInit
          && lib.hasInfix "${compInitMarker}\nautoload -U compinit && compinit -i\n" zshrc
          && !lib.hasInfix "compinit && compinit\n" zshrc);
      message = "household-mac: /etc/zshrc must run compinit only as "
        + "`compinit -i` — is programs.zsh.enableGlobalCompInit back on?";
    }
  ];
}
