{ ... }:

{
  # ── kassie-mbp-m1: shared household MacBook Pro (M1 Pro), ADOPTED in place ──
  # Not wiped. Two accounts: `kassie` (main day-to-day user, nix primaryUser —
  # minimal home-manager, no user defaults) and `rouven` (admin, maintainer —
  # nix touches nothing per-user there). See modules/roles/household-mac.nix
  # for exactly what activation changes.
  #
  # Casks below ADOPT apps that were already installed by hand in
  # /Applications and have an exact Homebrew cask (owner's pre-adoption audit).
  # Nothing new is added. rebuild.sh replaces each hand-installed bundle with
  # the Homebrew copy inside its single authentication (rh7/dotfiles#116);
  # without that, `brew bundle` stops at "It seems there is already an App at
  # '/Applications/X.app'". Every cask here is a plain `app` artifact — no pkg
  # installer — so the unattended nightly fleet-update never needs sudo for them.
  homebrew.casks = [
    # ── Browsers ──
    "arc"              # DEPRECATED upstream (discontinued; not disabled yet).
                       # Kept because it is installed and in use; Kassie is
                       # moving off Arc (rh7/dotfiles#98, #99) — drop it here
                       # once she has.
    "brave-browser"
    "firefox"
    "google-chrome"

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
  # `mas install` as the primary user (kassie), i.e. against whichever Apple ID
  # is signed in to her App Store — and an unattended run cannot install
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
