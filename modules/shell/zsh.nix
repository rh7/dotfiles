{ pkgs, ... }:

{
  programs.zsh = {
    enable = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;

    shellAliases = {
      # Better defaults
      ll    = "eza -la --git";
      ls    = "eza";
      cat   = "bat";
      cd    = "z";       # zoxide
      ".."  = "cd ..";
      "..." = "cd ../..";

      # Git
      gs  = "git status";
      ga  = "git add";
      gc  = "git commit";
      gp  = "git push";
      gl  = "git log --oneline -20";
      gd  = "git diff";
      gco = "git checkout";
      gbr = "git branch";

      # Nix / nix-darwin
      nrs  = "darwin-rebuild switch --flake ~/dotfiles";
      nrb  = "darwin-rebuild build --flake ~/dotfiles";
      nfu  = "nix flake update ~/dotfiles";
      ngc  = "nix-collect-garbage -d";
      nfmt = "nixpkgs-fmt ~/dotfiles/**/*.nix";

      # Docker / OrbStack
      d   = "docker";
      dc  = "docker compose";
      dps = "docker ps";
      dex = "docker exec -it";

      # Tailscale
      ts  = "tailscale";
      tss = "tailscale status";
    };

    initExtra = ''
      # zoxide (smarter cd)
      eval "$(zoxide init zsh)"

      # fzf
      eval "$(fzf --zsh)"

      # 1Password SSH Agent
      export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock

      # Homebrew (Apple Silicon path)
      eval "$(/opt/homebrew/bin/brew shellenv)"

      # Local scripts on PATH
      export PATH="$HOME/.local/bin:$PATH"

      # uv — fast Python package manager
      export UV_PYTHON_PREFERENCE=managed
    '';
  };

  # ── Starship prompt ───────────────────────────────────────────────────────
  programs.starship = {
    enable = true;
    settings = {
      format = "$directory$git_branch$git_status$nodejs$python$rust$nix_shell$cmd_duration$line_break$character";
      directory.truncation_length = 3;
      git_branch.symbol  = " ";
      nodejs.symbol      = " ";
      python.symbol      = " ";
      rust.symbol        = " ";
      nix_shell.symbol   = "❄️ ";
      cmd_duration = {
        min_time = 2000;
        format   = "took [$duration]($style) ";
      };
    };
  };

  # ── SSH ──────────────────────────────────────────────────────────────────
  programs.ssh = {
    enable = true;
    extraConfig = ''
      # 1Password SSH agent — handles all keys
      Host *
        IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        ServerAliveInterval 60
        ServerAliveCountMax 3

      # Tailscale hostnames
      Host mac-studio
        HostName rouvens-mac-studio
        User rouvenheck

      Host mac-mini
        HostName rouvens-mac-mini
        User rouvenheck

      Host jetson
        HostName jetson-rorin2
        User rouvenheck

      Host contabo
        HostName contabo-vps-rh7lab
        User root
    '';
  };

  # ── mackup (app settings sync via iCloud) ────────────────────────────────
  # To migrate to Dropbox: change engine to "dropbox" then run: mackup backup
  #
  # Only apps with mackup support listed here.
  # Unsupported (sync via their own account/iCloud): raycast, obsidian, slack, superhuman, clockify
  home.file.".mackup.cfg".text = ''
    [storage]
    engine = icloud
    directory = mackup

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
}
