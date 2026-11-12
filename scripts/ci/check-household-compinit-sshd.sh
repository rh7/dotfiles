#!/usr/bin/env bash
# Eval-level check for two household-mac choices (modules/roles/household-mac.nix):
#
#   compinit -i — /opt/homebrew belongs to system.primaryUser, so for every
#     other account compaudit finds directories owned by neither root nor the
#     account, and nix-darwin's bare `compinit` asked "Ignore insecure
#     directories and files and continue [y] or abort compinit [n]?" in every
#     new shell (kassie-mbp-m1). Household /etc/zshrc runs `compinit -i` and no
#     bare compinit; every other host keeps nix-darwin's bare one.
#   no sshd host keys / drop-ins — nix-darwin generates /etc/ssh/ssh_host_*_key
#     and links sshd_config.d/* even with services.openssh.enable = null.
#     Household hosts do neither; other hosts are unchanged.
#
# The compinit behaviour is exercised in a real zsh (when present) against a
# world-writable fpath directory — insecure to compaudit just like a directory
# owned by another account, and creatable without root.
#
# Run from the repo root (flake-check.yml). Exit 0 ok, 1 any failure.
set -euo pipefail

# Hosts with role = ./modules/roles/household-mac.nix in flake.nix (same list
# as check-household-brew-shim.sh).
HOUSEHOLD_HOSTS="kassie-mbp-m1"
MARKER="# household-mac: compinit skips directories other accounts own"
BARE="autoload -U compinit && compinit"

fail=0
bad() { echo "::error::$*"; fail=1; }

cfg() {  # <host> <attr path> <apply> — nix eval --json of the host's config
  nix eval --json ".#darwinConfigurations.\"$1\".config.$2" --apply "$3"
}

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# behave <zshrc> — the compinit lines of <zshrc>, run in zsh with two fpath
# directories: one the running user owns (the primary user's view of her own
# Homebrew site-functions) and one insecure (another account's view of them).
# Prints the shell's output, then which of the two completions got loaded.
behave() {
  grep -E '^autoload -U compinit && compinit' "$1" >"$W/compinit" || true
  [[ -s "$W/compinit" ]] || { echo "NO_COMPINIT"; return; }
  rm -rf "${W:?}/secure" "${W:?}/insecure" "${W:?}/home"
  mkdir -p "$W/secure" "$W/insecure" "$W/home"
  printf '#compdef rh7mine\n' >"$W/secure/_rh7mine"
  printf '#compdef rh7theirs\n' >"$W/insecure/_rh7theirs"
  chmod 0755 "$W/secure"
  chmod 0777 "$W/insecure"
  HOME="$W/home" ZDOTDIR="$W/home" zsh -f -c \
    "fpath=('$W/secure' '$W/insecure' \$fpath); . '$W/compinit'; echo \"DONE mine=\${_comps[rh7mine]-none} theirs=\${_comps[rh7theirs]-none}\"" \
    </dev/null 2>&1 || true
}

hosts=$(nix eval --json '.#darwinConfigurations' --apply 'builtins.attrNames' | jq -r '.[]')
[[ -n "$hosts" ]] || { bad "no darwinConfigurations found"; exit 1; }

for h in $hosts; do
  zshrc=$(nix eval --raw ".#darwinConfigurations.\"$h\".config.environment.etc" \
    --apply 'etc: if etc ? "zshrc" && etc."zshrc".enable then etc."zshrc".text else ""')
  printf '%s\n' "$zshrc" >"$W/zshrc"
  keygen=$(cfg "$h" system.activationScripts.openssh.text 't: t != ""')
  dropins=$(cfg "$h" environment.etc \
    'etc: builtins.filter (n: builtins.substring 0 18 n == "ssh/sshd_config.d/" && etc.${n}.enable) (builtins.attrNames etc)')
  if [[ " $HOUSEHOLD_HOSTS " == *" $h "* ]]; then
    [[ "$zshrc" == *"$MARKER"$'\n'"$BARE -i"$'\n'* ]] || bad "$h: /etc/zshrc lacks the household 'compinit -i'"
    [[ "$zshrc" != *"$BARE"$'\n'* ]] || bad "$h: /etc/zshrc still runs a bare compinit"
    [[ "$keygen" == false ]] || bad "$h: activation generates SSH host keys"
    [[ "$dropins" == "[]" ]] || bad "$h: sshd_config.d drop-ins linked: $dropins"
    if command -v zsh >/dev/null; then
      out=$(behave "$W/zshrc")
      [[ "$out" == "DONE mine=_rh7mine theirs=none" ]] \
        || bad "$h: compinit -i should load the user's own completions, skip the insecure dir, and stay silent; got: $out"
      echo "$h: compinit -i is silent, loads the user's own completions, skips the insecure directory"
    fi
    echo "$h: household compinit -i, no SSH host keys, no sshd drop-ins"
  else
    [[ "$zshrc" != *"$MARKER"* ]] || bad "$h: not a household host but carries the household compinit"
    [[ "$keygen" == true ]] || bad "$h: not a household host but its SSH host key step is gone"
    echo "$h: nix-darwin defaults (not household)"
  fi
done

# The bare compinit really is the one that stops on that directory — without a
# terminal it cannot ask, so it aborts — otherwise the check above proves nothing.
if command -v zsh >/dev/null; then
  printf '%s\n' "$BARE" >"$W/bare"
  out=$(behave "$W/bare")
  [[ "$out" == *"compinit: initialization aborted"* ]] \
    || bad "control: a bare compinit should stop on the insecure dir, got: $out"
fi

[[ $fail -eq 0 ]] || exit 1
echo "household compinit / sshd: OK"
