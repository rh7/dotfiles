#!/usr/bin/env bash
# Eval-level check for the household `brew` shell function
# (modules/roles/household-mac.nix).
#
# On a household Mac Homebrew belongs to homebrew.user (default
# system.primaryUser; kassie-mbp-m1 sets an admin, because its daily user is a
# standard account); /etc/zshrc and /etc/bashrc define `brew` for every OTHER
# account: admins run it as the brew user (`sudo -u <brew user> -H
# <prefix>/bin/brew`), non-admins are told who manages it, the brew user is
# unaffected. This gate pins:
#   - household hosts: both files carry it, built from the EVALUATED
#     homebrew.user and homebrew.prefix (no hard-coded name or path);
#   - every other darwinConfiguration: neither file carries it;
#   - the generated function behaves as above (run in bash and, when present,
#     zsh, with `id`/`sudo` stubbed) — including for the primary user when
#     she is not the brew user.
#
# Run from the repo root (flake-check.yml). Exit 0 ok, 1 any failure.
set -euo pipefail

# Hosts with role = ./modules/roles/household-mac.nix in flake.nix. A new
# household host fails the "others carry no shim" check until listed here.
HOUSEHOLD_HOSTS="kassie-mbp-m1"
MARKER="# household-mac: Homebrew on this Mac belongs to"

fail=0
bad() { echo "::error::$*"; fail=1; }

etc_text() {  # <host> <file> — text of environment.etc.<file>, "" when disabled
  nix eval --raw ".#darwinConfigurations.\"$1\".config.environment.etc" \
    --apply "etc: if etc ? \"$2\" && etc.\"$2\".enable then etc.\"$2\".text else \"\""
}

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# behave <shell> <rcfile> <owner> <prefix> <primary> — runs the shim from
# <rcfile> as another admin, a non-admin, the primary user (when she is not
# the owner, as a non-admin) and the brew user.
behave() {
  local sh="$1" rc="$2" owner="$3" prefix="$4" primary="$5" out
  mkdir -p "$W/bin"
  cat >"$W/bin/id" <<'EOF'
#!/bin/sh
case "$1" in
  -un) echo "$STUB_USER" ;;
  -Gn) echo "$STUB_GROUPS" ;;
esac
EOF
  cat >"$W/bin/sudo" <<'EOF'
#!/bin/sh
echo "sudo $* (cwd=$PWD)"
EOF
  chmod +x "$W/bin/id" "$W/bin/sudo"
  # Only the shim: the full rc file sources macOS/nix paths a runner lacks.
  awk -v m="$MARKER" 'index($0, m) == 1 { on = 1 } on { print } on && /^fi$/ { exit }' "$rc" >"$W/shim"
  [[ -s "$W/shim" ]] || { bad "$sh: no shim block in $rc"; return; }
  run() { STUB_USER="$1" STUB_GROUPS="$2" PATH="$W/bin:/usr/bin:/bin" "$sh" -c ". '$W/shim'; brew install foo" 2>&1; }

  out=$(run otheradmin "staff everyone admin") || true
  [[ "$out" == "sudo -u $owner -H $prefix/bin/brew install foo (cwd=/)" ]] \
    || bad "$sh: admin non-owner should run brew as $owner from /, got: $out"
  if out=$(run guest "staff everyone _lpadmin"); then
    bad "$sh: non-admin brew should fail (rc 1), got rc 0: $out"
  fi
  [[ "$out" == "Homebrew on this Mac is managed by $owner; ask an admin." ]] \
    || bad "$sh: non-admin message wrong: $out"
  if [[ "$primary" != "$owner" ]]; then
    if out=$(run "$primary" "staff everyone"); then
      bad "$sh: $primary (standard, not the brew user) should be refused, got rc 0: $out"
    fi
    [[ "$out" == "Homebrew on this Mac is managed by $owner; ask an admin." ]] \
      || bad "$sh: $primary's message wrong: $out"
  fi
  out=$(STUB_USER="$owner" STUB_GROUPS="staff admin" PATH="$W/bin:/usr/bin:/bin" \
    "$sh" -c ". '$W/shim'; type brew" 2>&1) || true
  [[ "$out" != *function* ]] || bad "$sh: $owner must keep the real brew, got: $out"
  echo "$sh: shim behaves (admin → sudo -u $owner, non-admin → refused, $owner untouched)"
}

hosts=$(nix eval --json '.#darwinConfigurations' --apply 'builtins.attrNames' | jq -r '.[]')
[[ -n "$hosts" ]] || { bad "no darwinConfigurations found"; exit 1; }

for h in $hosts; do
  zshrc=$(etc_text "$h" zshrc); bashrc=$(etc_text "$h" bashrc)
  if [[ " $HOUSEHOLD_HOSTS " == *" $h "* ]]; then
    owner=$(nix eval --raw ".#darwinConfigurations.\"$h\".config.homebrew.user")
    primary=$(nix eval --raw ".#darwinConfigurations.\"$h\".config.system.primaryUser")
    prefix=$(nix eval --raw ".#darwinConfigurations.\"$h\".config.homebrew.prefix")
    for f in zshrc bashrc; do
      text=$([[ $f == zshrc ]] && printf '%s' "$zshrc" || printf '%s' "$bashrc")
      [[ "$text" == *"$MARKER $owner"* ]] || bad "$h: /etc/$f lacks the brew shim for $owner"
      [[ "$text" == *"sudo -u $owner -H $prefix/bin/brew"* ]] \
        || bad "$h: /etc/$f shim is not built from homebrew.user=$owner / homebrew.prefix=$prefix"
      printf '%s\n' "$text" >"$W/$f"
    done
    behave bash "$W/bashrc" "$owner" "$prefix" "$primary"
    if command -v zsh >/dev/null; then behave zsh "$W/zshrc" "$owner" "$prefix" "$primary"; fi
    echo "$h: household brew shim present (homebrew.user=$owner, primaryUser=$primary, prefix=$prefix)"
  else
    [[ "$zshrc$bashrc" != *"$MARKER"* ]] || bad "$h: not a household host but carries the brew shim"
    echo "$h: no brew shim (not household)"
  fi
done

[[ $fail -eq 0 ]] || exit 1
echo "household brew shim: OK"
