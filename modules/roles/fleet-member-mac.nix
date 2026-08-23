{ lib, ... }:

{
  # ── Fleet member: nix owns the toolchain, nothing else ────────────────────
  #
  # For a Mac whose actual workloads are managed by OTHER repos (the Studio:
  # mac-studio-services owns inference/serving/monitoring, rh-device-management
  # owns the config service via service.sh, agent-memory and home-automation own
  # their agents). On such a host, nix-darwin's app/dock/Homebrew management is
  # not merely redundant — it is a hazard: an activation-time
  # `brew bundle --upgrade` restarts the serving stack (ollama, llama.cpp, mlx,
  # tailscale) as a side effect of an unrelated config change, and app lists
  # declared here drift silently from a machine that is really administered
  # imperatively (rh-device-management#312: the tailscale-app cask was declared
  # and receipted while /Applications/Tailscale.app did not exist — tailscaled
  # actually runs from the brew formula, installed by hand).
  #
  # What this role deliberately KEEPS is exactly what the host's services
  # resolve from nix and nothing else provides:
  #   - the home-manager CLI toolchain (node, sops, age, git, jq via
  #     /etc/profiles/per-user/<user>/bin) — rh-device-management's service.sh
  #     pins its PATH there for the better-sqlite3 ABI guarantee (#203), the
  #     backup/notify agents decrypt with that sops/age, and 10+
  #     mac-studio-services plists reference nix profile paths;
  #   - zsh/session config (~/.zshrc is a store symlink);
  #   - sops-nix secrets wiring (via needsSecrets in mkMac);
  #   - the fleet-audit schedule (via extraHomeModules in flake.nix).
  #
  # What it deliberately DROPS, and who owns it instead:
  #   - Homebrew casks/brews/taps + activation-time upgrades → brew is
  #     imperative on this host, by declaration rather than by neglect;
  #   - GUI app installs (Dia postActivation, MAS apps), dock layout → manual;
  #   - the desktop/dev/ai profiles a workstation gets → not this machine's job.
  #
  # A rebuild on a fleet-member host is therefore boring by construction: it
  # updates the toolchain and touches nothing that serves.
  #
  # NOTE: mkMac imports modules/darwin/homebrew.nix unconditionally, so the
  # disable must be forced here rather than by omitting an import.
  homebrew.enable = lib.mkForce false;
}
