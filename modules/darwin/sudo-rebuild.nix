{ config, ... }:

{
  # ── One authentication per rebuild, instead of one per cask ──────────────
  #
  # THE PROBLEM: `rebuild.sh` calls sudo exactly once (`sudo darwin-rebuild
  # switch`). The repeated Touch ID prompts come from INSIDE that switch:
  # nix-darwin drops root back to the primary user to run `brew bundle`
  # (brew refuses to run as root), so every cask that needs root — pkg-based
  # installers invoking `installer`/`pkgutil`/`cp` — calls sudo again as the
  # user. macOS sudo defaults to tty-scoped timestamps, and those brew
  # children share no controlling tty, so each one re-authenticates. With a
  # couple dozen outdated casks that is a couple dozen prompts, none of which
  # say WHICH cask is asking or why.
  #
  # THE FIX: make the timestamp user-scoped rather than tty-scoped, so one
  # authentication covers brew's children too. rebuild.sh then authenticates
  # once up front (after printing the plan), refreshes the timestamp with a
  # keep-alive for the duration of the run, and calls `sudo -k` on exit to
  # close the window immediately rather than letting it linger.
  #
  # THE TRADEOFF (read before copying this anywhere else): while the window is
  # open, ANY process running as this user can call sudo without a prompt —
  # including the third-party formula/cask install scripts a rebuild downloads
  # and executes. Note those scripts already receive root today; the prompts
  # they trigger are unattributable, so they get approved reflexively. This
  # trades N unattributable taps for one tap shown after an explicit plan.
  #
  # Scoped deliberately:
  #   - to the primary user only (not `Defaults` globally, not %admin);
  #   - to the workstation-mac role, so interactive dev machines get it and
  #     personal-mac hosts (e.g. Kassie's Air) do not.
  #
  # NOT sufficient for unattended use. A launchd job with no human present
  # cannot satisfy the initial authentication at all — this only removes the
  # 2nd..Nth prompt, never the 1st. Scheduled updates need a design that
  # avoids root entirely; do NOT reach for NOPASSWD here to paper over that.
  #
  # `timestamp_timeout` is deliberately left at the macOS default of 5 minutes.
  # The keep-alive refreshes within that window, so a longer timeout would only
  # widen the exposure after the run ends without making the run smoother.
  security.sudo.extraConfig = ''

    # Let one authentication cover the whole rebuild, including the sudo calls
    # `brew bundle` makes as this user from within `darwin-rebuild switch`.
    # See modules/darwin/sudo-rebuild.nix for the full rationale + tradeoff.
    Defaults:${config.system.primaryUser} timestamp_type=global
  '';
}
