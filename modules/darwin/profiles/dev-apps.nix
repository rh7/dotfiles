{ ... }:

{
  # ── Developer GUI apps ───────────────────────────────────────────────────
  homebrew.casks = [
    "obsidian"
    # "raycast"  # optional, evaluate later
    "claude-code"
    "cursor"
    "ghostty"
    "zed"
    "visual-studio-code"
    "orbstack"
    "utm"
    "cmux"
    "termius"
    # "pgadmin4"  # run in Docker if needed: dpage/pgadmin4
    "commander-one"
    # "wezterm"  # replaced by ghostty
    # "parallels"  # needs FDA, install manually if needed
  ];

  homebrew.brews = [
    "direnv"     # per-project env/shells (nixpkgs build broken)
    "railway"    # Railway CLI
  ];
}
