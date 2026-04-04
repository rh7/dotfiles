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
    # "pgadmin4"  # run in Docker if needed: dpage/pgadmin4
    "commander-one"
    "parallels"  # grant Full Disk Access manually after install
  ];

  homebrew.brews = [
    "direnv"     # per-project env/shells (nixpkgs build broken)
    "railway"    # Railway CLI
  ];
}
