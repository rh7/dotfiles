{ ... }:

{
  # ── Homebrew scaffold (managed declaratively by nix-darwin) ──────────────
  # App lists have been moved to modules/darwin/profiles/ and modules/roles/.
  # This file only configures Homebrew behavior.
  homebrew = {
    enable = true;

    onActivation = {
      autoUpdate = true;
      upgrade = true;
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
}
