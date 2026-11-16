#!/usr/bin/env bash
# Eval-level check for owner remote maintenance (modules/darwin/remote-maintenance.nix,
# services.rh7.remoteMaintenance): key-only, tailnet-only SSH to ONE account on
# exactly the hosts listed below, and on no other darwinConfiguration.
#
# Per listed host:
#   - enabled, with the expected login account;
#   - sshd_config.d/000-rh7-remote-maintenance.conf carries every hardened line
#     and sorts FIRST among the host's drop-ins (macOS's sshd_config starts with
#     `Include /etc/ssh/sshd_config.d/*` and sshd keeps the first value it reads);
#   - /etc/ssh/nix_authorized_keys.d holds keys for that account only, every key
#     restricted to tailnet source addresses (from="100.64.0.0/10,fd7a:115c:a1e0::/48");
#   - activation turns Remote Login on; on a household host, not Screen Sharing;
#   - when an `sshd` binary is available: `sshd -T` over the host's drop-ins in
#     macOS's layout (plus macOS's own 100-macos.conf and the main file's
#     AuthorizedKeysFile) yields the hardened values — the include order really wins.
# Every other host: disabled, no such drop-in, no nix authorized keys.
#
# Run from the repo root (flake-check.yml). Exit 0 ok, 1 any failure.
set -euo pipefail

# The hosts that enable services.rh7.remoteMaintenance in flake.nix / their host
# files, as `host` or `host:user`. A new host fails the "nobody else" check until
# listed here. `:user` pins the login account: kassie-mbp-m1 must use the admin
# maintainer account, never Kassie's. Kassie-M5-Air13 is unpinned on purpose:
# it uses kassie today and moves to a separate admin account later with a
# one-line host change (the checks below follow the evaluated user).
RM_HOSTS="kassie-mbp-m1:rouven Kassie-M5-Air13"
HOUSEHOLD_HOSTS="kassie-mbp-m1"
DROPIN="ssh/sshd_config.d/000-rh7-remote-maintenance.conf"
FROM='from="100.64.0.0/10,fd7a:115c:a1e0::/48" '

fail=0
bad() { echo "::error::$*"; fail=1; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

cfg() {  # <host> <attr path> <apply> — nix eval --json of the host's config
  nix eval --json ".#darwinConfigurations.\"$1\".config.$2" --apply "$3"
}
etc_names() {  # <host> <prefix> — enabled environment.etc names under <prefix>, sorted, one per line
  cfg "$1" environment.etc "etc: builtins.filter (n: builtins.substring 0 (builtins.stringLength \"$2\") n == \"$2\" && etc.\${n}.enable) (builtins.attrNames etc)" \
    | jq -r '.[]' | LC_ALL=C sort
}
etc_text() {  # <host> <name>
  nix eval --raw ".#darwinConfigurations.\"$1\".config.environment.etc" --apply "etc: etc.\"$2\".text"
}

# effective <host> <user> — sshd -T over the host's drop-ins in macOS's layout.
effective() {
  local d="$W/$1" n
  rm -rf "$d"; mkdir -p "$d/sshd_config.d"
  ssh-keygen -q -t ed25519 -N '' -f "$d/hostkey"
  while read -r n; do
    [[ -n "$n" ]] || continue
    if [[ "$n" == ssh/sshd_config.d/099-host-keys.conf ]]; then
      echo "HostKey $d/hostkey" >"$d/sshd_config.d/${n##*/}"   # the real keys need root
    else
      etc_text "$1" "$n" >"$d/sshd_config.d/${n##*/}"
    fi
  done < <(etc_names "$1" ssh/sshd_config.d/)
  [[ -e "$d/sshd_config.d/099-host-keys.conf" ]] || echo "HostKey $d/hostkey" >"$d/sshd_config.d/099-host-keys.conf"
  # macOS 26's own drop-in and main file, minus its crypto include (not on Linux).
  printf 'UsePAM yes\nAcceptEnv LANG LC_*\n' >"$d/sshd_config.d/100-macos.conf"
  printf 'Include %s/sshd_config.d/*\nAuthorizedKeysFile .ssh/authorized_keys\n' "$d" >"$d/sshd_config"
  "$SSHD" -T -f "$d/sshd_config" -C "user=$2,addr=100.100.1.1,host=owner,laddr=100.100.1.2,lport=22" 2>&1 \
    | tr 'A-Z' 'a-z'
}
SSHD=$(command -v sshd || ls /usr/sbin/sshd 2>/dev/null || true)

hosts=$(nix eval --json '.#darwinConfigurations' --apply 'builtins.attrNames' | jq -r '.[]')
[[ -n "$hosts" ]] || { bad "no darwinConfigurations found"; exit 1; }

for h in $hosts; do
  listed=false want_user=""
  for e in $RM_HOSTS; do
    [[ "${e%%:*}" == "$h" ]] || continue
    listed=true
    [[ "$e" == *:* ]] && want_user="${e#*:}"
  done
  rm=$(cfg "$h" services.rh7.remoteMaintenance 'r: { inherit (r) enable user; }')
  enabled=$(jq -r .enable <<<"$rm")
  dropins=$(etc_names "$h" ssh/sshd_config.d/)
  keyfiles=$(etc_names "$h" ssh/nix_authorized_keys.d/)

  if [[ "$listed" == false ]]; then
    [[ "$enabled" == false ]] || bad "$h: not listed but enables remoteMaintenance"
    grep -qx "$DROPIN" <<<"$dropins" && bad "$h: carries $DROPIN"
    [[ -z "$keyfiles" ]] || bad "$h: nix authorized keys present: $(tr '\n' ' ' <<<"$keyfiles")"
    echo "$h: no remote maintenance"
    continue
  fi

  [[ "$enabled" == true ]] || { bad "$h: remoteMaintenance not enabled"; continue; }
  user=$(jq -r .user <<<"$rm")
  if [[ -n "$want_user" && "$user" != "$want_user" ]]; then
    bad "$h: remoteMaintenance.user is $user, want $want_user"
  fi
  [[ -n "$user" && "$user" != root ]] || { bad "$h: remoteMaintenance.user must be one non-root account"; continue; }
  want_user="$user"
  [[ "$(head -1 <<<"$dropins")" == "$DROPIN" ]] || bad "$h: $DROPIN is not the first drop-in: $(tr '\n' ' ' <<<"$dropins")"

  text=$(etc_text "$h" "$DROPIN")
  for line in "AllowUsers $want_user" "AuthenticationMethods publickey" "PubkeyAuthentication yes" \
    "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PermitEmptyPasswords no" \
    "PermitRootLogin no" "X11Forwarding no" "MaxAuthTries 3" "AuthorizedKeysFile none" \
    "AuthorizedKeysCommand /bin/cat /etc/ssh/nix_authorized_keys.d/%u" "AuthorizedKeysCommandUser _sshd"; do
    grep -qxF "$line" <<<"$text" || bad "$h: drop-in lacks '$line'"
  done

  [[ "$keyfiles" == "ssh/nix_authorized_keys.d/$want_user" ]] \
    || bad "$h: nix authorized keys must be for $want_user only, got: $(tr '\n' ' ' <<<"$keyfiles")"
  keys=$(etc_text "$h" "ssh/nix_authorized_keys.d/$want_user" | sed '/^[[:space:]]*$/d')
  [[ -n "$keys" ]] || bad "$h: no authorized keys for $want_user"
  while IFS= read -r k; do
    [[ "$k" == "$FROM"ssh-* || "$k" == "$FROM"ecdsa-* || "$k" == "$FROM"sk-* ]] \
      || bad "$h: authorized key not restricted to tailnet sources: ${k:0:60}…"
  done <<<"$keys"

  post=$(nix eval --raw ".#darwinConfigurations.\"$h\".config.system.activationScripts.postActivation.text")
  [[ "$post" == *"launchctl print system/com.openssh.sshd"* ]] || bad "$h: activation does not turn Remote Login on"
  if [[ " $HOUSEHOLD_HOSTS " == *" $h "* && "$post" == *com.apple.screensharing* ]]; then
    bad "$h: household host turns Screen Sharing on"
  fi

  if [[ -n "$SSHD" ]]; then
    eff=$(effective "$h" "$want_user")
    grep -q '^port ' <<<"$eff" || { bad "$h: sshd -T failed: $(head -5 <<<"$eff")"; continue; }
    for kv in "allowusers $want_user" "authenticationmethods publickey" "passwordauthentication no" \
      "kbdinteractiveauthentication no" "permitemptypasswords no" "permitrootlogin no" \
      "x11forwarding no" "maxauthtries 3" "pubkeyauthentication yes" \
      "authorizedkeyscommand /bin/cat /etc/ssh/nix_authorized_keys.d/%u"; do
      grep -qxF "$kv" <<<"$eff" || bad "$h: sshd -T does not yield '$kv' (got: $(grep -i "^${kv%% *} " <<<"$eff" || echo "$eff" | head -3))"
    done
    grep -q '^authorizedkeysfile ' <<<"$eff" && bad "$h: sshd -T still reads an AuthorizedKeysFile: $(grep '^authorizedkeysfile ' <<<"$eff")"
    echo "$h: sshd -T over its drop-ins yields the hardened values"
  else
    echo "::notice::no sshd binary; effective-config check skipped for $h"
  fi
  echo "$h: remote maintenance for $want_user, hardened drop-in first, tailnet-only keys"
done

[[ $fail -eq 0 ]] || exit 1
echo "remote maintenance: OK"
