{ ... }:

{
  # ── Mac Studio — AI inference lab ────────────────────────────────────────
  # Ollama must run natively for Metal/ANE GPU access — cannot be in a VM
  homebrew.brews = [ "ollama" ];
  homebrew.casks = [ "lm-studio" ];

  # Ollama as a managed launchd service
  launchd.user.agents.ollama = {
    serviceConfig = {
      Label           = "com.ollama.ollama";
      ProgramArguments = [ "/opt/homebrew/bin/ollama" "serve" ];
      RunAtLoad       = true;
      KeepAlive       = true;
      StandardOutPath = "/tmp/ollama.log";
      StandardErrorPath = "/tmp/ollama.error.log";
      EnvironmentVariables = {
        OLLAMA_HOST   = "0.0.0.0:11434";
        OLLAMA_MODELS = "/Users/rouvenheck/.ollama/models";
      };
    };
  };
}
