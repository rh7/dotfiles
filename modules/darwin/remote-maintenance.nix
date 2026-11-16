{ config, lib, ... }:

let
  cfg = config.services.rh7.remoteMaintenance;

  # Tailscale's address ranges (CGNAT IPv4 + the tailnet ULA). Every key below
  # is accepted ONLY from these source addresses, so a key works over the
  # tailnet and nowhere else — not from the LAN, even with the right key.
  tailnetSources = "100.64.0.0/10,fd7a:115c:a1e0::/48";

  # First in lexical order: macOS's /etc/ssh/sshd_config starts with
  # `Include /etc/ssh/sshd_config.d/*`, the glob expands sorted, and for (almost)
  # every keyword sshd keeps the FIRST value it reads. So this file wins over
  # nix-darwin's 099-host-keys/100-nix-darwin/101-authorized-keys, macOS's
  # 100-macos.conf and the main file's own `AuthorizedKeysFile` — on hosts that
  # also import remote-access.nix (Kassie-M5-Air13) as well.
  dropIn = "ssh/sshd_config.d/000-rh7-remote-maintenance.conf";
in
{
  # ── Owner remote maintenance over SSH (opt-in, key-only, tailnet-only) ───
  # Remote Login for exactly ONE login account, public-key only, with the
  # owner's keys accepted only from tailnet source addresses. Off by default;
  # a host turns it on with services.rh7.remoteMaintenance.enable. Screen
  # Sharing is not touched (out of scope). Reachability is the Tailscale ACL's
  # (rh7/tailscale-acl rule 11: owner devices → these Macs, TCP :22 only).
  #
  # When enabled:
  #   - Remote Login (sshd) is switched on (same launchctl path as
  #     remote-access.nix: systemsetup needs Full Disk Access, activation has none);
  #   - sshd_config.d/000-rh7-remote-maintenance.conf: AllowUsers <user>,
  #     publickey only (no password / keyboard-interactive / empty passwords),
  #     no root, no X11, MaxAuthTries 3, and AuthorizedKeysFile none — keys come
  #     ONLY from nix (/etc/ssh/nix_authorized_keys.d/<user>), so whatever sits
  #     in an account's ~/.ssh/authorized_keys is ignored;
  #   - users.users.<user>.openssh.authorizedKeys: the given keys, each prefixed
  #     with from="<tailnet ranges>".
  # Host keys are whatever sshd needs: nix-darwin's default
  # services.openssh.hostKeys generates the three standard ones if missing.
  options.services.rh7.remoteMaintenance = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Owner remote maintenance: key-only, tailnet-only SSH to one login account.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "rouven";
      description = "The single account allowed to log in (AllowUsers). Must be an admin for sudo.";
    };
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Public keys allowed to log in as `user`, WITHOUT options: each is
        prefixed with from="${tailnetSources}" here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.user != "" && cfg.user != "root";
        message = "services.rh7.remoteMaintenance.user must name one non-root login account.";
      }
      {
        assertion = cfg.authorizedKeys != [ ];
        message = "services.rh7.remoteMaintenance.authorizedKeys is empty — nobody could log in.";
      }
      {
        # A key that already carries options would get from= in front of them
        # (still valid), but a non-key line would be silently dropped by sshd.
        assertion = lib.all (k: builtins.match "(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/=]+( .*)?" k != null) cfg.authorizedKeys;
        message = "services.rh7.remoteMaintenance.authorizedKeys: every entry must be a bare public key "
          + "(`<type> <base64> [comment]`, no options — from= is added by the module).";
      }
    ];

    environment.etc.${dropIn}.text = ''
      # rh7 remote maintenance (modules/darwin/remote-maintenance.nix).
      # First drop-in on purpose: sshd keeps the first value it reads.
      AllowUsers ${cfg.user}
      AuthenticationMethods publickey
      PubkeyAuthentication yes
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitEmptyPasswords no
      PermitRootLogin no
      X11Forwarding no
      MaxAuthTries 3
      AuthorizedKeysFile none
      AuthorizedKeysCommand /bin/cat /etc/ssh/nix_authorized_keys.d/%u
      AuthorizedKeysCommandUser _sshd
    '';

    users.users.${cfg.user}.openssh.authorizedKeys.keys =
      map (k: ''from="${tailnetSources}" ${k}'') cfg.authorizedKeys;

    # Remote Login on. mkOrder 999: after remote-access.nix's 998 block (which
    # does the same where it is imported), so the drop-in above — linked by the
    # earlier etc step — is in place before sshd can accept a connection.
    system.activationScripts.postActivation.text = lib.mkOrder 999 ''
      # rh7 remote maintenance: Remote Login (com.openssh.sshd) on, key-only.
      if ! /bin/launchctl print system/com.openssh.sshd &>/dev/null; then
        /bin/launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
      fi
    '';
  };
}
