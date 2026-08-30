{ pkgs, lib, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in {
  # ── Zsh ──────────────────────────────────────────────────────────────────
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    history = {
      size = 50000;
      save = 50000;
      ignoreDups = true;
      ignoreAllDups = true;
      share = true;
    };
    shellAliases = {
      # Navigation
      ll  = "eza -la --icons --git";
      la  = "eza -a --icons";
      lt  = "eza --tree --level=2 --icons";
      cat = "bat";

      # Git
      gs  = "git status";
      gp  = "git push";
      gl  = "git pull";
      gd  = "git diff";
      gc  = "git commit";
      gca = "git commit -a";
      gco = "git checkout";
      gb  = "git branch";
      glog = "git log --oneline --graph --decorate -20";

      # Nix — guarded by default (build → drift audit → nvd diff → confirm →
      # switch). The guard is not a nicety: it holds ONE sudo authentication
      # open for the whole run, so `brew bundle`'s root-requiring casks reuse
      # it instead of re-prompting per cask (see modules/darwin/sudo-rebuild.nix),
      # and it pulls first so a host cannot silently drift weeks behind main.
      #
      # This used to be raw darwin-rebuild, with the guard parked on the
      # longer-to-type `nrsg`. That put the unguarded path in muscle memory and
      # the safe one behind a deliberate choice — exactly backwards. The raw
      # command is still here as `nrs-raw`, for when rebuild.sh is itself the
      # thing that is broken.
      nrs = "~/dotfiles/scripts/rebuild.sh";
      nrsg = "~/dotfiles/scripts/rebuild.sh";   # kept: prior name, same thing
      "nrs-raw" = if isDarwin
        then "sudo darwin-rebuild switch --flake ~/dotfiles#$(hostname)"
        else "sudo nixos-rebuild switch --flake ~/dotfiles";
      nup = "nix flake update ~/dotfiles";

      # Quick access
      dots = "cd ~/dotfiles && zed .";
    } // lib.optionalAttrs (!isDarwin) {
      # macOS muscle memory on Wayland (wl-clipboard, see modules/nixos/desktop.nix)
      pbcopy  = "wl-copy";
      pbpaste = "wl-paste";
    };

    initContent = ''
      # zoxide init
      eval "$(zoxide init zsh)"
    '' + lib.optionalString isDarwin ''
      # 1Password SSH Agent (macOS)
      export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock

      # Homebrew (Apple Silicon)
      eval "$(/opt/homebrew/bin/brew shellenv)"
    '';
  };

  # ── Starship prompt ──────────────────────────────────────────────────────
  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      character = {
        success_symbol = "[❯](bold green)";
        error_symbol   = "[❯](bold red)";
      };
      directory.truncation_length = 3;
      git_branch.symbol = " ";
      nix_shell.symbol = " ";
      nodejs.symbol = " ";
      python.symbol = " ";
      rust.symbol = " ";
    };
  };

  # ── mackup config (iCloud, macOS only) ─────────────────────────────────
  home.file = lib.mkIf isDarwin {
    ".mackup.cfg".text = ''
      [storage]
      engine = icloud

      [applications_to_sync]
      cursor
      zed
      terminal
      ssh
      git
      zsh
      telegram_macos
      franz
      spotify
      wezterm
      starship
      gnupg
      claude-code
      tripmode
    '';
  };
}
