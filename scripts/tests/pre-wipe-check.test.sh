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

# Tests set globals that the sourced script's functions read.
# shellcheck disable=SC2034
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
check "Apple utility"         apple  "$(classify_app /Applications/Utilities/Terminal.app com.apple.Terminal 0 0)"
check "Xcode download listed" manual "$(classify_app /Applications/Xcode.app com.apple.dt.Xcode 0 0)"
check "Apple app via cask"    brew   "$(classify_app '/Applications/Safari Technology Preview.app' com.apple.SafariTechnologyPreview 0 1)"
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
check "partly unreadable small → AMBER"      AMBER "$(level standard 10 1 0 Downloads 1)"
check "partly unreadable repo dir → AMBER"   AMBER "$(level other "$BIG" 1 1 code 1)"
check "partly unreadable big stays RED"      RED   "$(level other "$BIG" 1 0 Archive 1)"
check "partly unreadable cache stays quiet"  NONE  "$(level cache "$BIG" 1 0 .cache 1)"
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
check "iPhone backups: judged in cleanup (AMBER), not as a VM" NONE "$(flag MobileSync)"
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
check "legacy ~/Dropbox root"      1 "$(cloud "$HOME/Dropbox/vault" 0)"
check "legacy ~/OneDrive root"     1 "$(cloud "$HOME/OneDrive - Acme/vault" 0)"
check "legacy ~/Google Drive root" 1 "$(cloud "$HOME/Google Drive/vault" 0)"
check "iCloud archive is local"    0 "$(cloud "$HOME/iCloud Drive (Archive)/vault" 1)"
check ".local is not a cache"      other "$(home_entry_kind .local)"

echo "== table_get =="
T=$'\nArc.app\tarc\nGoogle Chrome.app\tgoogle-chrome\n'
check "hit"               "google-chrome" "$(table_get "$T" 'Google Chrome.app')"
check "no prefix match"   ""              "$(table_get "$T" 'Chrome.app')"
check "miss returns 1"    1               "$(table_get "$T" 'Nope.app' >/dev/null; echo $?)"

# ── stubs shared by the multi-user / cleanup / wallet tests ─────────────────
# Commands run through run_timeout would exec the real binary; make it call
# the (stubbed) function instead.
run_timeout() { shift; "$@"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Tests that change global state run in a subshell; these carry the tally out.
sub_save() { printf 'pass=%s; fail=%s\n' "$pass" "$fail" > "$TMP/sub.counts"; }
sub_load() { . "$TMP/sub.counts"; }
USERS_ROOT="$TMP/Users"
mkdir -p "$USERS_ROOT/rouven" "$USERS_ROOT/kassie" "$USERS_ROOT/ft-viewer"

# dscl as it really answers (IsHidden as dsAttrTypeNative:, spaced values on
# their own line, "No such key" for absent attributes).
dscl() {
  case "$*" in
    ". -list /Users UniqueID")
      printf '%-24s %s\n' _mbsetupuser 248 daemon 1 nobody -2 Guest 201 rouven 501 kassie 502 \
        ft-viewer 503 sharer 504 ghost 505 ;;
    ". -read /Users/rouven NFSHomeDirectory IsHidden") printf 'No such key: IsHidden\nNFSHomeDirectory: %s\n' "$USERS_ROOT/rouven" ;;
    ". -read /Users/kassie NFSHomeDirectory IsHidden") printf 'NFSHomeDirectory:\n %s\nNo such key: IsHidden\n' "$USERS_ROOT/kassie" ;;
    ". -read /Users/ft-viewer NFSHomeDirectory IsHidden") printf 'dsAttrTypeNative:IsHidden: 1\nNFSHomeDirectory: %s\n' "$USERS_ROOT/ft-viewer" ;;
    ". -read /Users/sharer NFSHomeDirectory IsHidden") printf 'NFSHomeDirectory: /dev/null\n' ;;
    ". -read /Users/ghost NFSHomeDirectory IsHidden") printf 'NFSHomeDirectory: %s\n' "$USERS_ROOT/ghost" ;;
    ". -read /Users/rouven NFSHomeDirectory") printf 'NFSHomeDirectory: %s\n' "$USERS_ROOT/rouven" ;;
    ". -read /Groups/admin GroupMembership") printf 'GroupMembership: root rouven _mbsetupuser\n' ;;
    *) return 1 ;;
  esac
}
du() { local a; for a in "$@"; do :; done; printf '2048\t%s\n' "$a"; }

echo "== dscl parsing + user enumeration =="
check "dscl: plain home, no IsHidden"  "/Users/a"$'\t'"0" "$(printf 'No such key: IsHidden\nNFSHomeDirectory: /Users/a\n' | parse_dscl_user)"
check "dscl: native IsHidden"          "/Users/b"$'\t'"1" "$(printf 'dsAttrTypeNative:IsHidden: 1\nNFSHomeDirectory: /Users/b\n' | parse_dscl_user)"
check "dscl: spaced value on next line" "/Users/C D"$'\t'"0" "$(printf 'NFSHomeDirectory:\n /Users/C D\n' | parse_dscl_user)"
check "only real visible accounts (no system/_/hidden/sharing-only/missing home)" \
  "rouven 501 $USERS_ROOT/rouven|kassie 502 $USERS_ROOT/kassie|" \
  "$(list_real_users | tr '\t\n' ' |' | sed 's/ |/|/g')"
adm() { if user_is_admin "$1"; then echo yes; else echo no; fi; }
check "rouven is admin"               yes "$(adm rouven)"
check "kassie is not admin"           no  "$(adm kassie)"
check "no substring admin match"      no  "$(adm rou)"
last() { printf 'kassie    console                   Tue Nov 10 09:14 - 18:02  (08:47)\n\nwtmp begins Fri Feb 27 02:41:58 AST 2026\n'; }
check "last login parsed"             "Tue Nov 10 09:14" "$(last_login kassie)"
last() { printf '\nwtmp begins Fri Feb 27 02:41:58 AST 2026\n'; }
check "never logged in → empty, not the wtmp date" "" "$(last_login ghost)"
unset -f last

echo "== Full Disk Access probe =="
mkdir -p "$TMP/tcc" "$TMP/Users/kassie/Library/Mail"
ls() { case "$*" in *"/Library/Mail"*) return 1 ;; *) return 0 ;; esac; }
check "blocked folder reported"  "$TMP/Users/kassie/Library/Mail" "$(fda_probe "$TMP/tcc" "$TMP/Users/kassie/Library/Mail")"
check "blocked → rc 1"           1 "$(fda_probe "$TMP/tcc" "$TMP/Users/kassie/Library/Mail" >/dev/null; echo $?)"
check "all readable → rc 0"      0 "$(fda_probe "$TMP/tcc" >/dev/null; echo $?)"
check "nothing to probe → rc 2"  2 "$(fda_probe "$TMP/none1" "$TMP/none2" >/dev/null; echo $?)"
unset -f ls
msg="$(TERM_PROGRAM=Apple_Terminal fda_help /Users/kassie/Library/Mail /opt/pwc.sh)"
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }
check "FDA help names the pane"          yes "$(has 'Privacy & Security → Full Disk Access' "$msg")"
check "FDA help has the settings URL"    yes "$(has 'Privacy_AllFiles' "$msg")"
check "FDA help names Terminal.app"      yes "$(has '/System/Applications/Utilities/Terminal.app' "$msg")"
check "FDA help says restart terminal"   yes "$(has 'Quit the terminal completely' "$msg")"
check "FDA help gives the re-run line"   yes "$(has 'sudo /opt/pwc.sh --all-users' "$msg")"
check "FDA help names the blocked path"  yes "$(has '/Users/kassie/Library/Mail' "$msg")"

echo "== per-account re-invocation =="
( SKIP_PROTECTED=1; OFFLINE=1; SUGGEST_CASKS=1; HOST_OVERRIDE=""
  build_child_argv kassie "/Users/kassie" user
  check "user child argv" \
    "sudo -n -u kassie -H /usr/bin/env HOME=/Users/kassie USER=kassie LOGNAME=kassie /bin/bash -s -- --as-user kassie --part user --skip-protected --offline" \
    "${CHILD_ARGV[*]}"
  CONFIG_SERVICE_URL=http://studio:3456; HOST_OVERRIDE=kassie-mbp; SKIP_PROTECTED=0
  build_child_argv rouven "/Users/Rouven Heck" system
  check "system child argv (casks, pinned URL, host)" \
    "sudo -n -u rouven -H /usr/bin/env HOME=/Users/Rouven Heck USER=rouven LOGNAME=rouven CONFIG_SERVICE_URL=http://studio:3456 /bin/bash -s -- --as-user rouven --part system --offline --suggest-casks --host kassie-mbp" \
    "${CHILD_ARGV[*]}"
  check "home with a space stays one argument" "HOME=/Users/Rouven Heck" "${CHILD_ARGV[6]}"
  sub_save
)
sub_load

echo "== child fragment round trip =="
(
  BODY="## 4. Data"$'\n'"text"$'\n'; N_RED=1; N_AMBER=2; N_GREEN=3; CFG_URL=http://c:3456
  RED_ITEMS="- red one"$'\n'; AMBER_ITEMS="- amber one"$'\n'"- amber two"$'\n'
  PLAN_ROWS="kassie"$'\t'"RED"$'\t'"10"$'\t'"/Users/kassie/x"$'\t'"x"$'\n'
  frag="$(emit_fragment)"
  BODY=""; N_RED=5; N_AMBER=0; N_GREEN=0; RED_ITEMS=""; AMBER_ITEMS=""; PLAN_ROWS=""; CFG_URL=""
  parse_fragment "$frag" kassie; rc=$?
  check "parses"                 0 "$rc"
  check "counts are added"       "6 2 3" "$N_RED $N_AMBER $N_GREEN"
  check "items carry the account" "- [kassie] red one" "${RED_ITEMS%$'\n'}"
  check "body intact"            "## 4. Data"$'\n'"text"$'\n' "$FRAG_BODY"
  check "plan row kept"          "kassie"$'\t'"RED"$'\t'"10"$'\t'"/Users/kassie/x"$'\t'"x" "${PLAN_ROWS%$'\n'}"
  check "cfg url"                "http://c:3456" "$CFG_URL"
  check "truncated fragment rejected" 1 "$(parse_fragment "${frag%@@END}" k >/dev/null; echo $?)"
  check "garbage rejected"            1 "$(parse_fragment "hello" k >/dev/null; echo $?)"
  sub_save
)
sub_load
check "demote headings, not code" "### a"$'\n'"\`\`\`sh"$'\n'"# comment"$'\n'"\`\`\`"$'\n'"#### b" \
  "$(printf '## a\n```sh\n# comment\n```\n### b\n' | demote_headings)"

echo "== cleanup classification =="
cls() { local r; r="$(cleanup_class "$1")"; printf '%s' "${r%%$'\t'*}"; }
check "caches safe"              SAFE-TO-DELETE "$(cls caches)"
check "DerivedData safe"         SAFE-TO-DELETE "$(cls deriveddata)"
check "simulators safe"          SAFE-TO-DELETE "$(cls coresimulator)"
check "DeviceSupport safe"       SAFE-TO-DELETE "$(cls devicesupport)"
check "installed installer safe" SAFE-TO-DELETE "$(cls installer-installed)"
check "Downloads review"         REVIEW "$(cls downloads)"
check "device backups review"    REVIEW "$(cls mobilesync)"
check "conda env review"         REVIEW "$(cls conda-env)"
check "Xcode archives review"    REVIEW "$(cls xcarchives)"
check "unknown installer review" REVIEW "$(cls installer)"
check "Photos library keep"      KEEP   "$(cls photos)"
check "unknown kind keep"        KEEP   "$(cls whatever)"
APPS=$'\nledgerlive\nexodus\nzoomus\nvlc\ngooglechrome\n'
check "Ledger installer matches app"   installer-installed "$(installer_kind 'Ledger-Live-2.80.0-mac.dmg' "$APPS")"
check "Exodus installer (arch suffix)" installer-installed "$(installer_kind 'exodus-macos-arm64-24.41.3.dmg' "$APPS")"
check "Zoom.pkg ↔ zoom.us.app"         installer-installed "$(installer_kind 'Zoom.pkg' "$APPS")"
check "short names never SAFE"         installer "$(installer_kind 'vlc-3.0.20-arm64.dmg' "$APPS")"
check "no matching app"                installer "$(installer_kind 'Electrum-4.5.dmg' "$APPS")"
check "zip is an archive, not an installer" archive "$(installer_kind 'GoogleChrome.zip' "$APPS")"

( H="$TMP/home-clean"; HOME="$H"; mkdir -p "$H/Library/Caches" "$H/Library/Developer/Xcode/DerivedData" \
    "$H/Library/Developer/Xcode/iOS DeviceSupport" "$H/miniconda3/envs/ml" "$H/miniconda3/pkgs" "$H/.cargo" \
    "$H/Library/Application Support/MobileSync/Backup/00008030-AAA" "$H/proj/node_modules"
  stat() { echo 1700000000; }
  PROTECTED_DONE=0; SKIP_PROTECTED=1; CLEANUP_BUDGET=100
  collect_cleanup 2>/dev/null; device_backups
  row() { printf '%s' "$CLEAN_ROWS" | awk -F'\t' -v l="$1" '$4 == l { print $1; exit }'; }
  check "cleanup: caches row"         SAFE-TO-DELETE "$(row 'App caches')"
  check "cleanup: DerivedData row"    SAFE-TO-DELETE "$(row 'Xcode DerivedData')"
  check "cleanup: DeviceSupport row"  SAFE-TO-DELETE "$(row 'Xcode iOS DeviceSupport')"
  check "cleanup: conda env row"      REVIEW "$(row 'conda env `ml`')"
  check "cleanup: conda pkgs row"     SAFE-TO-DELETE "$(row 'conda package cache')"
  check "cleanup: cargo row"          SAFE-TO-DELETE "$(row 'Rust (cargo)')"
  check "cleanup: node_modules found" SAFE-TO-DELETE "$(row 'node_modules (1 folders)')"
  check "cleanup: device backups REVIEW" REVIEW "$(row 'iPhone/iPad backups (1)')"
  check "device backups are an AMBER finding" "1 0" "$N_AMBER $N_RED"
  check "device backups go to the plan as AMBER" AMBER "$(printf '%s' "$PLAN_ROWS" | cut -f2)"
  sub_save
)
sub_load

echo "== crypto wallets =="
( H="$TMP/home-wallet"; HOME="$H"; APPS_DIR="$TMP/Applications"; PART=all; PLAN_USER=kassie
  mkdir -p "$H/.electrum/wallets"; : > "$H/.electrum/wallets/default_wallet"
  mkdir -p "$H/Library/Application Support/Exodus" "$H/.electrum" "$APPS_DIR/Ledger Live.app" "$APPS_DIR/Exodus.app" \
    "$H/Library/Application Support/Google/Chrome/Profile 1/Extensions/nkbihfbeogaeaoehlefnkodbefgpgknn" \
    "$H/Library/Application Support/Google/Chrome/Profile 1/Local Extension Settings/nkbihfbeogaeaoehlefnkodbefgpgknn"
  section_wallets 2>/dev/null
  wrow() { printf '%s' "$WALLET_ROWS" | awk -F'\t' -v n="$1" '$1 == n { print $2 "/" $3 "/" ($6 != "" ? "data" : "nodata"); exit }'; }
  check "Exodus: local keys, app, data"      "local/1/data"      "$(wrow Exodus)"
  check "Electrum: data without the app"     "local/0/data"      "$(wrow Electrum)"
  check "Ledger Live: app only"              "hardware/1/nodata" "$(wrow 'Ledger Live')"
  check "absent wallets not listed"          ""                  "$(wrow KeepKey)"
  check "MetaMask extension in Chrome Profile 1" "MetaMask/Google Chrome/Profile 1" \
    "$(printf '%s' "$WALLET_EXT_ROWS" | awk -F'\t' '{ print $1 "/" $2 "/" $3 }')"
  check "one RED for the seed phrases"       1 "$N_RED"
  check "RED text" yes "$(has 'confirm the seed phrase / recovery for each wallet is stored offline before any change; local wallet files may hold keys' "$RED_ITEMS")"
  check "app-only wallet → AMBER (another account?)" 1 "$N_AMBER"
  check "local-key wallet data + extension go to the plan (not Ledger)" 3 "$(printf '%s' "$PLAN_ROWS" | grep -c RED)"
  check "never lists a wallet file name" no "$(has 'default_wallet' "$BODY")"
  sub_save
)
sub_load

echo "== backup plan =="
( PLAN_ROWS="kassie"$'\t'"RED"$'\t'"100"$'\t'"/Users/kassie/Documents"$'\t'"d"$'\n'
  PLAN_ROWS+="kassie"$'\t'"RED"$'\t'"?"$'\t'"/Users/kassie/Documents/repo"$'\t'"repo"$'\n'
  PLAN_ROWS+="kassie"$'\t'"RED"$'\t'"50"$'\t'"/Users/kassie/Documents 2"$'\t'"d2"$'\n'
  PLAN_ROWS+="kassie"$'\t'"AMBER"$'\t'"7"$'\t'"/Users/kassie/Library/Mail"$'\t'"m"$'\n'
  PLAN_ROWS+="rouven"$'\t'"RED"$'\t'"1"$'\t'"/Users/rouven/x"$'\t'"x"$'\n'
  check "child path folded into its ancestor" "150"$'\t'"2"$'\t'"0" "$(plan_summary kassie RED)"
  check "paths deduped, ancestors win" "/Users/kassie/Documents|/Users/kassie/Documents 2|" "$(plan_paths kassie RED | tr '\n' '|')"
  check "per account"                  "/Users/rouven/x" "$(plan_paths rouven RED)"
  check "shq quotes single quotes"     "'it'\\''s'" "$(shq "it's")"
  sub_save
)
sub_load

echo "== --all-users harness (stubbed id/sudo/dscl/du/ls/last) =="
# sudo stub: a per-account child gets a canned fragment (and its argv is
# logged); the report write (sudo -u ADMIN /bin/sh -c …) really runs.
sudo() {
  local a
  for a in "$@"; do
    if [ "$a" = /bin/sh ]; then
      while [ "$1" != /bin/sh ]; do shift; done
      "$@"; return
    fi
  done
  cat >/dev/null   # the script text on stdin
  printf '%s\n' "$*" >> "$TMP/sudo.log"
  case "$*" in
    *"--part system"*)
      printf '@@PWC-FRAGMENT\t1\n@@COUNTS\t0\t1\t2\n@@AMBER\t3 manually installed app(s)\n@@BODY\n## 3. Apps to reinstall\n\napps here\n@@END\n' ;;
    *"--as-user kassie --part user"*)
      printf '@@PWC-FRAGMENT\t1\n@@COUNTS\t1\t0\t0\n@@RED\tCrypto wallets in this account (Exodus): confirm the seed phrase\n'
      printf '@@PLAN\tkassie\tRED\t2048\t%s\tExodus wallet data\n' "$USERS_ROOT/kassie/Library/Application Support/Exodus"
      printf '@@BODY\n## 5. Crypto wallets\n```sh\n# not a heading\n```\n@@END\n' ;;
    *"--as-user rouven --part user"*)
      printf '@@PWC-FRAGMENT\t1\n@@COUNTS\t0\t0\t1\n@@BODY\n## 4. Data that exists only on this Mac\n@@END\n' ;;
    *) return 1 ;;
  esac
}
id() { case "$1" in -u) echo 0 ;; -un) echo root ;; esac; }
last() { printf 'kassie    console                   Tue Nov 10 09:14 - 18:02  (08:47)\n'; }
ls() { return 0; }
out="$( HOST=kassie-mbp SUDO_USER=rouven ALL_USERS=1 OFFLINE=1; run_all_users 2>"$TMP/harness.err" )"; rc=$?
check "harness exits 1 (RED present)"      1 "$rc"
check "accounts table: rouven is you+admin" yes "$(has '| `rouven` (you) | yes | 2.0 MB |' "$out")"
check "accounts table: kassie, last login"  yes "$(has '| `kassie` | no | 2.0 MB | Tue Nov 10 09:14 |' "$out")"
check "hidden ft-viewer not listed"         no  "$(has 'ft-viewer' "$out")"
check "system part ran once, as the admin"  1   "$(grep -c -- '--part system' "$TMP/sudo.log")"
check "system child argv" "-n -u rouven -H /usr/bin/env HOME=$USERS_ROOT/rouven USER=rouven LOGNAME=rouven /bin/bash -s -- --as-user rouven --part system --offline" \
  "$(grep -- '--part system' "$TMP/sudo.log")"
check "each account ran as itself" "rouven kassie" "$(sed -n 's/.*--as-user \([a-z]*\) --part user.*/\1/p' "$TMP/sudo.log" | tr '\n' ' ' | sed 's/ $//')"
check "account section demoted"            yes "$(has $'## Account `kassie`\n\n### 5. Crypto wallets' "$out")"
check "code comment not demoted"           yes "$(has $'```sh\n# not a heading' "$out")"
check "child RED folded into the verdict"  yes "$(has '- [kassie] Crypto wallets' "$out")"
check "verdict counts summed"              yes "$(has '1 RED (will be lost) · 1 AMBER (check) · 3 GREEN' "$out")"
check "plan: restic line for kassie"       yes "$(has 'restic backup --tag pre-wipe --tag account:kassie' "$out")"
check "plan: restic repo URL"              yes "$(has "rest:http://kassie-mbp@rouvens-mac-studio:8000/kassie-mbp/" "$out")"
check "plan: sudo ditto for kassie's path" yes "$(has "sudo ditto '$USERS_ROOT/kassie/Library/Application Support/Exodus'" "$out")"
rep="$(printf '%s\n' "$USERS_ROOT"/rouven/pre-wipe-kassie-mbp-*.md | head -1)"
check "report saved in the admin's home"   yes "$( [ -f "$rep" ] && echo yes || echo no)"
check "report is mode 600"                 "-rw-------" "$(command ls -l "$rep" | cut -c1-10)"

ls() { case "$*" in *"/Library/Mail"*|*com.apple.TCC*) return 1 ;; *) return 0 ;; esac; }
mkdir -p "$USERS_ROOT/kassie/Library/Mail"
: > "$TMP/sudo.log"
out="$( HOST=kassie-mbp SUDO_USER=rouven ALL_USERS=1; run_all_users 2>&1 )"; rc=$?
check "no FDA → exit 2"                    2 "$rc"
check "no FDA → the grant steps"           yes "$(has 'Full Disk Access' "$out")"
check "no FDA → nothing ran as an account" 0 "$(grep -c . "$TMP/sudo.log")"
id() { case "$1" in -u) echo 501 ;; -un) echo rouven ;; esac; }
out="$( run_all_users 2>&1 )"; rc=$?
check "not root → exit 2 with the sudo line" "2 yes" "$rc $(has 'needs root' "$out")"
unset -f sudo id last ls

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
