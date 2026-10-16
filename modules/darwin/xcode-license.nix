{ ... }:

{
  # ── Accept the Xcode license before Homebrew runs ────────────────────────
  # Homebrew hard-refuses to do anything while the Xcode license is
  # unaccepted, so a single unaccepted license skips the ENTIRE `brew bundle`
  # step — no cask, no formula is processed (see #68, which first put Xcode on
  # a host). The fix has always been one root command; the problem is that it
  # had to be remembered, per machine, and again after every Xcode upgrade.
  #
  # This is a `preActivation` script, deliberately. nix-darwin runs
  # activationScripts in a fixed order:
  #
  #   preActivation → … → mas → homebrew → postActivation
  #
  # so preActivation is the only hook that lands BEFORE the Homebrew bundle
  # and can therefore unblock the same run. postActivation (where the rest of
  # this repo's shellouts live) would only help the run after next.
  #
  # Activation already runs as root, so no extra sudo and no extra prompt.
  #
  # Self-rearming on purpose: every Xcode upgrade — App Store auto-update, or
  # rebuild.sh's own `mas upgrade` in step 6b — resets the agreement, so this
  # is a cheap per-rebuild check rather than a one-shot bootstrap step.
  #
  # The probe is Homebrew's own license test (`MacOS::Xcode.license_approved?`
  # greps `xcrun clang` output for "license"), so this gate is true exactly
  # when Homebrew's gate is. It also means Command Line Tools-only hosts, where
  # there is nothing to accept, are a silent no-op: `xcrun clang` prints no
  # license text there, so `xcodebuild` is never invoked. Costs ~20ms.
  #
  # Matched on OUTPUT, never on exit status, and captured instead of piped:
  # `xcrun clang` exits 1 regardless (it is handed no input files), and the
  # activation script runs under `set -o pipefail`, so the obvious
  # `xcrun clang 2>&1 | grep -q license` would inherit that 1 and the gate
  # would never fire. Homebrew compares the text for the same reason.
  system.activationScripts.preActivation.text = ''
    xcode_probe=$(/usr/bin/xcrun clang 2>&1 || true)
    case "$xcode_probe" in *license*)
      echo "accepting the Xcode license (Homebrew refuses to run without it)..."
      # Never abort activation over this: a failure here degrades to the same
      # broken-Homebrew state we had before, and rebuild.sh already detects
      # that and prints the manual command.
      if /usr/bin/xcodebuild -license accept >/dev/null 2>&1; then
        echo "[OK]   Xcode license accepted."
      else
        echo "[WARN] Could not accept the Xcode license — Homebrew will be skipped."
        echo "[WARN] Run once by hand: sudo xcodebuild -license accept"
      fi
    ;; esac
  '';
}
