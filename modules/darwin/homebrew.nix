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
      cleanup = "uninstall";  # safe default: removes unlisted but doesn't zap
    };

    taps = [
    ];
  };
}
