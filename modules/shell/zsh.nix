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

      # Nix (uses hostname to pick the right flake config)
      nrs = if isDarwin
        then "sudo darwin-rebuild switch --flake ~/dotfiles#$(hostname)"
        else "sudo nixos-rebuild switch --flake ~/dotfiles";
      nup = "nix flake update ~/dotfiles";

      # Quick access
      dots = "cd ~/dotfiles && zed .";
    };

    initContent = ''
      # zoxide init
      eval "$(zoxide init zsh)"

      # direnv hook
      eval "$(direnv hook zsh)"
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
