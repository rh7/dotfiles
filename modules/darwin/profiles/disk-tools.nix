{ pkgs, ... }:

{
  # ── Disk usage + cleanup tools — EVERY Mac (imported by mkMac in flake.nix) ──
  #
  # Like homebrew.nix / fleet-audit.nix this is not a role profile: household
  # (kassie-mbp-m1), personal (Kassie-M5-Air13) and fleet-member (the Studio)
  # Macs get it too. What lands where:
  #   - CLI analysers from nixpkgs (environment.systemPackages) — on every Mac,
  #     including the Studio, whose role forces homebrew.enable = false:
  #       dust  — `dust ~`: tree of the biggest directories, at a glance
  #       dua   — `dua i ~`: interactive; marks and deletes only what you pick
  #       ncdu  — `ncdu ~`: the classic interactive browser
  #   - Homebrew (no-op where homebrew.enable = false, i.e. the Studio):
  #       mole (`mo`, tw93/Mole, GPL-3.0) — `mo analyze`, `mo clean --dry-run`.
  #         A brew FORMULA, not nixpkgs: nixpkgs' `mole` is an unrelated SSH
  #         tunnelling tool (davrodpin/mole).
  #       grandperspective — treemap of a disk/folder
  #       puremac          — caches / logs / leftovers cleaner
  #       pearcleaner      — app uninstaller that finds an app's leftovers
  #     Each cask is a plain `app` artifact (no pkg installer, no sudo), so the
  #     unattended nightly fleet-update can install it — given homebrew.user
  #     can write /Applications (fleet-update's own preflight checks that).
  #   - DevCleaner (Xcode DerivedData/simulators/archives) is declared next to
  #     Xcode in profiles/dev-apps.nix, not here: only Macs with Xcode want it.
  #
  # RULES (also in docs/device-guide.md "Disk cleanup tools"):
  #   - Never run a cleaner automatically or on a schedule. They are for a
  #     human, looking at the result. Nothing in this repo may add a LaunchAgent,
  #     cron job or activation step that runs one.
  #   - Always look first: `mo clean --dry-run`, `mo purge --dry-run`; in the
  #     GUIs, review the list before confirming.
  #   - Never `mo touchid`: it rewrites /etc/pam.d/sudo_local, which nix-darwin
  #     owns (security.pam.services.sudo_local in modules/darwin/defaults.nix;
  #     the one-auth-per-rebuild sudo setup in sudo-rebuild.nix builds on it).
  #   - Never `mo slim`: it thins the Mach-O binaries inside app bundles in
  #     place — one mistake breaks a bundle's code signature, and a Homebrew
  #     cask's app then no longer matches what Homebrew installed.
  #   - Never `mo update` / `mo remove`: Homebrew owns this mole (upgrade with
  #     `rebuild.sh --upgrade=all`).
  #   - Apps Homebrew manages are removed through the dotfiles config
  #     (drop the cask + add it to dotfiles.homebrew.retiredCasks,
  #     modules/darwin/homebrew.nix), not with `mo uninstall` or Pearcleaner —
  #     otherwise the next activation simply installs them again.
  environment.systemPackages = with pkgs; [ dust dua ncdu ];

  homebrew.brews = [ "mole" ];

  homebrew.casks = [
    "grandperspective"
    "pearcleaner"
    "puremac"
  ];
}
