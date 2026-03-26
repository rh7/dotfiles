{ pkgs, ... }:

{
  # ── GNOME desktop ───────────────────────────────────────────────────────
  services.xserver.enable = true;
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # ── Audio (PipeWire) ────────────────────────────────────────────────────
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # ── Fonts ───────────────────────────────────────────────────────────────
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-color-emoji
  ];

  # ── Desktop apps ────────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    firefox
    google-chrome
    gnome-tweaks
    wezterm
    ghostty
    zed-editor

    # Communication
    telegram-desktop
    slack
    signal-desktop
    discord
    element-desktop
    zoom-us

    # Productivity
    obsidian
    notion-app-enhanced

    # Media
    spotify
    vlc
  ];

  # ── Remove default GNOME bloat ─────────────────────────────────────────
  environment.gnome.excludePackages = with pkgs; [
    gnome-tour
    epiphany        # web browser
    geary           # email
    gnome-music
  ];
}
