{ ... }:

{
  # ── kassie-mbp-m1: shared household MacBook Pro (M1 Pro), ADOPTED in place ──
  # Not wiped. Two accounts: `kassie` (main day-to-day user, nix primaryUser —
  # minimal home-manager, no user defaults; a STANDARD account) and `rouven`
  # (admin, maintainer — nix touches nothing per-user there, but he owns
  # Homebrew, below). See modules/roles/household-mac.nix for exactly what
  # activation changes.
  #
  # Casks below mostly ADOPT apps that were already installed by hand in
  # /Applications and have an exact Homebrew cask (owner's pre-adoption audit).
  # rebuild.sh replaces each hand-installed bundle with the Homebrew copy
  # inside its single authentication (rh7/dotfiles#116); without that,
  # `brew bundle` stops at "It seems there is already an App at
  # '/Applications/X.app'". Entries marked NEW are the only software added
  # by THIS file. Like every Mac, it also gets the fleet-wide disk tools from
  # modules/darwin/profiles/disk-tools.nix (imported by mkMac): dust/dua/ncdu
  # (nixpkgs), the `mole` formula and the grandperspective, pearcleaner and
  # puremac casks — all NEW here, all plain `app` artifacts — plus `gh` in the
  # system profile (modules/darwin/profiles/base-cli.nix), and the household
  # role's superwhisper cask (modules/roles/household-mac.nix).
  # Every cask here is a plain `app` artifact — no pkg installer — so
  # installing or upgrading one needs no sudo PROVIDED homebrew.user can write
  # /Applications (an admin) and owns the existing bundle. Otherwise Homebrew
  # falls back to its own `sudo cp` and asks for the brew user's password —
  # which an unattended nightly fleet-update cannot answer at all.

  # Homebrew belongs to the ADMIN maintainer account, not to the daily user.
  # kassie is a standard user: she cannot write /Applications, so installing
  # a NEW cask as her (zen, ghostty) made Homebrew ask for HER password
  # (`sudo cp … /Applications/Zen.app`), from rebuild.sh run by rouven and
  # from the nightly fleet-update alike. With homebrew.user = rouven, nix-darwin
  # runs `brew bundle` as rouven, rebuild.sh from his account runs brew
  # directly, and its one-time chown hands /opt/homebrew and the installed
  # casks' app bundles to him. Kassie stays primaryUser (home-manager; the
  # daily audit runs as her); her `brew` says "managed by rouven; ask an admin".
  homebrew.user = "rouven";

  # Owner remote maintenance (modules/darwin/remote-maintenance.nix; the
  # household role allows it only in this hardened form and asserts it): SSH
  # over the tailnet as `rouven` ONLY — the admin maintainer account, so sudo
  # works for a rebuild — never as kassie. Public-key only, the owner's keys
  # accepted from tailnet addresses only. Screen Sharing stays off.
  services.rh7.remoteMaintenance = {
    enable = true;
    user = "rouven";
    authorizedKeys = import ../../keys/owner-ssh-keys.nix;
  };

  homebrew.casks = [
    # ── Browsers ──
    "arc"              # DEPRECATED upstream (discontinued; not disabled yet).
                       # Kept because it is installed and in use; Kassie is
                       # moving off Arc (rh7/dotfiles#98, #99) — drop it here
                       # once she has.
    "brave-browser"
    "firefox"
    "google-chrome"
    "zen"              # NEW — maintainer's browser (rouven's account)

    # ── Passwords / encryption ──
    "1password"
    "cryptomator"

    # ── Communication ──
    "discord"
    "proton-mail"
    "signal"
    "superhuman"
    "telegram"

    # ── Productivity / notes ──
    "cursor"
    "dropbox"
    "notion"
    "obsidian"
    "reader"           # Readwise Reader
    "roam-research"
    "setapp"           # Setapp itself only; apps inside it (e.g. Session)
                       # stay Setapp-managed
    "termius"
    "workflowy"

    # ── Finance ──
    "quicken"

    # ── Media / home ──
    "bookwright"
    "pocket-casts"
    "sonos"
    "spotify"

    # ── Maintainer's tools (NEW, for the rouven account) ──
    # /Applications is shared, so Kassie sees them too. No per-user config:
    # the household role links nothing into rouven's home.
    "ghostty"
    "claude"           # Claude desktop app (self-updating)
    "claude-code"      # Claude Code CLI → /opt/homebrew/bin/claude
  ];

  # ── Deliberately NOT declared (manual, by design) ──────────────────────────
  # Crypto wallets — installed and updated by hand, never by Homebrew: a wallet
  # must never auto-upgrade, and each release is verified by its owner before
  # it touches keys. (Wallet apps are intentionally not enumerated here.)
  #
  # Adobe / Maxon apps — licensed vendor installers (Creative Cloud, Maxon
  # App); Homebrew casks would fight the vendor's own updater and licensing.
  #
  # tailscale — network-critical. Replacing it mid-rebuild drops the tailnet
  # the maintainer is (possibly) connected over. Adopt later, deliberately,
  # with local access to the Mac.
  #
  # Candidates — installed by hand; owner decides whether to adopt, keep
  # manual, or remove:
  #   "expressvpn"      # pkg installer (needs root on install)
  #   "franz"
  #   "skype"           # cask DISABLED upstream (Skype discontinued 2025-05)
  #   "boxcryptor"      # cask DISABLED upstream (discontinued)
  #   "gotomeeting"
  #   "virtualbox"      # pkg installer + kernel extension
  #   "thunderbird"
  #   "topaz-video-ai"  # cask DISABLED upstream (discontinued 2025-09)
  #   "ollama-app"      # the Ollama.app cask (`ollama` is the CLI formula)

  # ── Mac App Store apps present (NOT declared) ──────────────────────────────
  # Installed under an Apple ID; declaring them would make activation run
  # `mas install` as homebrew.user (rouven, homebrew.masApps) or the primary
  # user (kassie, mas_install), i.e. against whichever Apple ID is signed in
  # to that account's App Store — and an unattended run cannot install
  # anyway (fleet-update.nix). Owner decides later. Present at adoption
  # (id  name):
  #   961632517  Be Focused Pro
  #   1500855883 CapCut
  #   1225393668 Code Reader - QR Reader
  #   1387167765 Diarly
  #   6474268307 Enchanted
  #   1099568401 Home Assistant
  #   1500678169 Hue Menu
  #   1349322557 HueMenu
  #   408981434  iMovie
  #   405399194  Kindle
  #   1357379892 Menu Bar Controller for Sonos
  #   462058435  Microsoft Excel
  #   462054704  Microsoft Word
  #   1483398136 Next2Do
  #   409203825  Numbers
  #   823766827  OneDrive
  #   409201541  Pages
  #   568494494  Pocket
  #   1593228108 QR Code
  #   1549370672 Save to Raindrop.io
  #   803453959  Slack
  #   963034692  Streaks
  #   1278508951 Trello
  #   1513400665 TripMode
  #   1225570693 Ulysses
  #   6444030605 VoiceAI
  #   1147396723 WhatsApp (Catalyst)
  #   310633997  WhatsApp
  #   931134707  Wire
  #   1451685025 WireGuard
  #   497799835  Xcode
  # Already auto-updated by the App Store (software-update.nix: AutoUpdate).
}
