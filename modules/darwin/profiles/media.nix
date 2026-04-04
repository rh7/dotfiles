{ ... }:

{
  # ── Media and reading apps ────────────────────────────────────────────────
  homebrew.casks = [
    "spotify"
    "pocket-casts"
    "vlc"
    # amazon-kindle removed from Homebrew — install via App Store
    "audible"
  ];

  # Note: BookWright, MKPlayer, Headway — not in Homebrew, manual install
}
