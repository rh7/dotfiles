{ ... }:

{
  # ── Developer GUI apps ───────────────────────────────────────────────────
  homebrew.casks = [
    "cursor"
    "ghostty"
    "zed"
    "orbstack"
    "utm"
    "wezterm"
    "termius"
  ];

  homebrew.brews = [
    "direnv"     # per-project env/shells (nixpkgs build broken)
    "railway"    # Railway CLI
  ];
}
