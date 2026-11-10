#!/usr/bin/env bash
# Fixture tests for the pure helpers in scripts/pre-wipe-check.sh.
#
# Run: bash scripts/tests/pre-wipe-check.test.sh
#
# The script itself is macOS-only (osascript, du on APFS, tmutil…), but its
# judgement calls are plain bash and run anywhere, including Linux CI. These
# cover the ones whose failure is silent: a classifier that calls local-only
# data "re-installable", or a git check that calls unpushed work safe, prints a
# reassuring report and exits 0.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pre-wipe-check.sh"
# shellcheck source=../pre-wipe-check.sh
PRE_WIPE_CHECK_SOURCE_ONLY=1 source "$SCRIPT"

pass=0; fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   — $1"; pass=$((pass + 1))
  else echo "  FAIL — $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi
}
level() { local r; r="$(home_entry_level "$@")"; printf '%s' "${r%%$'\t'*}"; }

echo "== sourcing has no side effects =="
check "main did not run (no report buffered)" "" "$BODY"

echo "== canonical_host matches the registry key =="
check "lowercases"              "kassie-m5-air13" "$(canonical_host Kassie-M5-Air13)"
check "strips .local"           "rouvens-mac-studio" "$(canonical_host Rouvens-Mac-Studio.local)"
check "strips trailing dot"     "box" "$(canonical_host 'box.local.')"
check "trims whitespace"        "air" "$(canonical_host ' Air ')"
check "keeps FQDN"              "vps.example.com" "$(canonical_host vps.example.com)"

echo "== human_kb =="
check "KB"             "512 KB" "$(human_kb 512)"
check "MB"             "1.0 MB" "$(human_kb 1024)"
check "GB"             "1.5 GB" "$(human_kb 1572864)"
check "unknown"        "?"      "$(human_kb '?')"

echo "== verdict_word =="
check "any RED → no"          "no"     "$(verdict_word 1 0)"
check "RED wins over AMBER"   "no"     "$(verdict_word 2 5)"
check "AMBER only → check"    "check"  "$(verdict_word 0 3)"
check "clean → likely"        "likely" "$(verdict_word 0 0)"

echo "== classify_app =="
check "nix-darwin app"        nix    "$(classify_app '/Applications/Nix Apps/Foo.app' org.foo 0 0)"
check "home-manager app"      nix    "$(classify_app "$HOME/Applications/Home Manager Apps/Foo.app" org.foo 0 1)"
check "MAS receipt"           mas    "$(classify_app /Applications/Things3.app com.culturedcode.ThingsMac 1 0)"
check "Apple MAS app is MAS"  mas    "$(classify_app /Applications/Keynote.app com.apple.iWork.Keynote 1 0)"
check "iOS wrapper is MAS"    mas    "$(classify_app /Applications/Foo.app com.foo.ios 2 0)"
check "Apple system app"      apple  "$(classify_app /Applications/Safari.app com.apple.Safari 0 0)"
check "cask"                  brew   "$(classify_app /Applications/Arc.app company.thebrowser.Browser 0 1)"
check "Setapp by path"        setapp "$(classify_app /Applications/Setapp/CleanShot.app pl.maketheweb.cleanshotx 0 0)"
check "Setapp by bundle id"   setapp "$(classify_app /Applications/Bartender.app com.surteesstudios.Bartender-setapp 0 0)"
check "manual"                manual "$(classify_app /Applications/zoom.us.app us.zoom.xos 0 0)"

echo "== cask_token_guess =="
check "spaces → dashes"  "google-chrome"      "$(cask_token_guess 'Google Chrome.app')"
check "keeps dots"       "zoom.us"            "$(cask_token_guess 'zoom.us.app')"
check "strips odd chars" "superhuman"         "$(cask_token_guess 'Superhuman™.app')"

echo "== home folder judgement =="
BIG=$((BIG_KB + 1)); SMALLISH=$((SMALL_KB + 1))
check "Downloads is never synced"            RED   "$(level standard "$BIG" 1 0 Downloads)"
check "Desktop synced → GREEN"               GREEN "$(level dd "$BIG" 1 0 Desktop)"
check "Desktop NOT synced → RED"             RED   "$(level dd "$SMALLISH" 0 0 Desktop)"
check "empty unsynced Documents → nothing"   NONE  "$(level dd 4 0 0 Documents)"
check "big unknown folder → RED"             RED   "$(level other "$BIG" 1 0 Archive)"
check "repo folder → folded into Git"        REPO  "$(level other "$BIG" 1 1 code)"
check "cache never RED"                      NONE  "$(level cache "$BIG" 1 0 .cache)"
check "big VM dir → RED"                     RED   "$(level vm "$BIG" 1 0 .colima)"
check "unknown size → AMBER, never silent"   AMBER "$(level other '?' 1 0 Archive)"
check "unknown size even for caches"         AMBER "$(level cache '?' 1 0 .cache)"
check "kind: Library skipped"                skip  "$(home_entry_kind Library)"
check "kind: Dropbox is cloud"               cloud "$(home_entry_kind 'Dropbox (Personal)')"
check "kind: iCloud archive is NOT cloud"    other "$(home_entry_kind 'iCloud Drive (Archive)')"
check "kind: OrbStack mount is vm"           vm    "$(home_entry_kind OrbStack)"

echo "== app data flags =="
flag() { local r; r="$(appdata_flag "$1")"; printf '%s' "${r%%$'\t'*}"; }
check "Signal always RED"          RED   "$(flag Signal)"
check "WhatsApp AMBER"             AMBER "$(flag net.whatsapp.WhatsApp)"
check "UTM is a VM"                VM    "$(flag com.utmapp.UTM)"
check "OrbStack group container"   AMBER "$(flag HUAQ24HBR6.dev.orbstack)"
check "iPhone backups"             VM    "$(flag MobileSync)"
check "unflagged → nothing"        ""    "$(flag Google)"

echo "== git_at_risk =="
risk() { if git_at_risk "$@"; then echo 1; else echo 0; fi; }
check "clean + pushed"     0 "$(risk 0 0 0 0)"
check "dirty"              1 "$(risk 3 0 0 0)"
check "unpushed"           1 "$(risk 0 2 0 0)"
check "no remote"          1 "$(risk 0 0 1 0)"
check "stash"              1 "$(risk 0 0 0 1)"
check "unreadable is risk" 1 "$(risk '?' 0 0 0)"
check "unknown unpushed"   1 "$(risk 0 '?' 0 0)"

echo "== parsers =="
check "mas list" "$(printf '497799835\tXcode\n409183694\tKeynote')" \
  "$(printf '497799835  Xcode        (16.2)\n409183694  Keynote      (14.4)\n' | parse_mas_list)"
check "gpg: primary fingerprints only" "AAAA1111" \
  "$(printf 'sec:u:255:22:K1:1:::u:::scESC:::+:::ed25519:::0:\nfpr:::::::::AAAA1111:\nssb:u:255:18:K2:1::::::e:::+:::cv25519::\nfpr:::::::::BBBB2222:\n' | parse_gpg_fprs)"

echo "== paths =="
# shellcheck disable=SC2088  # the expected value is display text, not a path
check "tilde_path"           '~/code/x' "$(tilde_path "$HOME/code/x")"
check "tilde_path outside"   "/opt/x"   "$(tilde_path /opt/x)"
check "md_cell escapes pipe" 'a\|b'     "$(md_cell 'a|b')"
cloud() { if is_cloud_path "$@"; then echo 1; else echo 0; fi; }
check "iCloud Drive path"           1 "$(cloud "$HOME/Library/Mobile Documents/com~apple~CloudDocs/vault" 0)"
check "CloudStorage path"           1 "$(cloud "$HOME/Library/CloudStorage/Dropbox/vault" 0)"
check "Documents, synced"           1 "$(cloud "$HOME/Documents/vault" 1)"
check "Documents, NOT synced"       0 "$(cloud "$HOME/Documents/vault" 0)"
check "plain home folder"           0 "$(cloud "$HOME/vault" 1)"
check "Dropbox lookalike prefix"    0 "$(cloud "$HOME/DropboxOld/vault" 1)"

echo "== table_get =="
T=$'\nArc.app\tarc\nGoogle Chrome.app\tgoogle-chrome\n'
check "hit"               "google-chrome" "$(table_get "$T" 'Google Chrome.app')"
check "no prefix match"   ""              "$(table_get "$T" 'Chrome.app')"
check "miss returns 1"    1               "$(table_get "$T" 'Nope.app' >/dev/null; echo $?)"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
