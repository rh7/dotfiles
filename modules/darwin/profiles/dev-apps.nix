{ ... }:

{
  # ── Developer GUI apps ───────────────────────────────────────────────────
  homebrew.casks = [
    "cursor"
    "ghostty"
    "zed"
    "visual-studio-code"
    "orbstack"
    "utm"
    "wezterm"
    "termius"
    "pgadmin4"
    "commander-one"
    "parallels"
  ];

  homebrew.brews = [
    "direnv"     # per-project env/shells (nixpkgs build broken)
    "railway"    # Railway CLI
  ];
}
