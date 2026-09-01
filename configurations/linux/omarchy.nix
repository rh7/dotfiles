{ lib, ... }:

# ── Omarchy 4 guest (Arch Linux ARM, aarch64, in UTM) ──────────────────────
# Layered on configurations/linux/home.nix. The division of labour matters:
# Omarchy owns the desktop — Hyprland's Lua config, quickshell, the themes and
# the 442 omarchy-* commands in /usr/bin, all of which `omarchy-update`
# rewrites. Home Manager owns the CLI environment and nothing else. Do not
# manage ~/.config/hypr or ~/.bashrc from here; they will be overwritten and
# you will be debugging a broken desktop.
{
  # nvim, not Zed. common.nix sets `zed --wait` for the Macs, and Zed has no
  # aarch64-linux build here; Omarchy ships neovim (as omarchy-nvim).
  programs.git.settings.core.editor = lib.mkForce "nvim";

  # Omarchy drives its desktop from bash: ~/.bashrc exports OMARCHY_PATH, and
  # the tree reads it to find bootstrap.lua and the theme data. A zsh started
  # from a terminal never sources that file, so re-export it here — guarded on
  # the directory so this is inert on OrbStack or a plain Arch box.
  #
  # Keep bash as the LOGIN shell regardless (do not chsh): the desktop session
  # itself comes up through it.
  programs.zsh.initContent = lib.mkAfter ''
    [[ -d /usr/share/omarchy ]] && export OMARCHY_PATH=/usr/share/omarchy
  '';
}
