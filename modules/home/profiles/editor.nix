{ ... }:

{
  # ── Zed editor config (shared across all machines) ───────────────────────
  home.file.".config/zed/settings.json".text = builtins.toJSON {
    ui_font_size       = 14;
    buffer_font_family = "JetBrainsMono Nerd Font";
    buffer_font_size   = 13;
    theme              = "One Dark";
    tab_size           = 2;
    format_on_save     = "on";
    autosave           = { after_delay = { milliseconds = 1000; }; };
    terminal.font_family = "JetBrainsMono Nerd Font";
    vim_mode           = false;
  };
}
