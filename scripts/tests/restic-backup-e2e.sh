#!/usr/bin/env bash
# End-to-end check of scripts/restic-backup.sh against a REAL restic REST
# server, configured like the Studio's (append-only, private repos, htpasswd),
# on 127.0.0.1 with a throwaway data dir and HOME. Not a *.test.sh: it needs
# nix to fetch restic / rest-server / htpasswd from this flake's pinned
# nixpkgs, which the shell-tests CI job does not have. Run it by hand after
# changing the script or bumping restic:
#
#   bash scripts/tests/restic-backup-e2e.sh        (macOS or Linux, needs nix + jq)
#
# Asserts: setup inits the repo from a token; a run backs up only the existing
# policy paths minus the excludes; status.json follows the contract; a second
# run adds ~0 bytes; the client cannot delete a snapshot (append-only); another
# REST user cannot read this host's repo (private repos).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/restic-backup.sh"
PORT="${E2E_PORT:-18765}"
HOSTNAME_E2E="e2e-host"

command -v nix >/dev/null 2>&1 || { echo "FATAL: nix is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1: got [$2] want [$3]"; fi; }

echo "== tools from the flake's nixpkgs =="
paths="$(nix build --no-link --print-out-paths --inputs-from "$REPO_ROOT" \
  nixpkgs#restic nixpkgs#restic-rest-server nixpkgs#apacheHttpd)" || { echo "FATAL: nix build failed" >&2; exit 1; }
pick() { for p in $paths; do [ -x "$p/bin/$1" ] && { echo "$p/bin/$1"; return; }; done; }
RESTIC="$(pick restic)"; REST_SERVER="$(pick rest-server)"; HTPASSWD="$(pick htpasswd)"
for v in RESTIC REST_SERVER HTPASSWD; do [ -n "${!v}" ] || { echo "FATAL: $v not found in: $paths" >&2; exit 1; }; done
"$RESTIC" version; "$REST_SERVER" --version 2>&1 | head -1

T="$(mktemp -d "${TMPDIR:-/tmp}/rrb-e2e.XXXXXX")"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

echo "== rest-server on 127.0.0.1:$PORT (append-only, private repos) =="
DATA="$T/data"; mkdir -p "$DATA"
pw="$(head -c 32 /dev/urandom | base64 | tr -d '\n/+=' | cut -c1-32)"
"$HTPASSWD" -B -b -c "$DATA/.htpasswd" "$HOSTNAME_E2E" "$pw" 2>/dev/null
"$HTPASSWD" -B -b "$DATA/.htpasswd" intruder intruderpw 2>/dev/null
"$REST_SERVER" --path "$DATA" --listen "127.0.0.1:$PORT" --append-only --private-repos \
  --htpasswd-file "$DATA/.htpasswd" >"$T/rest-server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done

echo "== HOME fixtures =="
H="$T/home"
mkdir -p "$H/code/proj/node_modules/dep" "$H/code/proj/.venv" "$H/.ssh" "$H/.config/app/Caches" "$H/Projects/models"
echo "print('hi')" >"$H/code/proj/main.py"
echo "module.exports = 1" >"$H/code/proj/node_modules/dep/index.js"
echo "venv" >"$H/code/proj/.venv/pyvenv.cfg"
echo "-----FAKE KEY-----" >"$H/.ssh/id_e2e"
echo "setting=1" >"$H/.config/app/settings.ini"
echo "cache" >"$H/.config/app/Caches/blob"
dd if=/dev/zero of="$H/Projects/models/big.gguf" bs=1048576 count=0 seek=101 2>/dev/null   # sparse 101 MiB
echo "small weights" >"$H/Projects/models/lora.safetensors"
mkdir -p "$T/bin"; printf '#!/bin/sh\necho %s.local\n' "$HOSTNAME_E2E" >"$T/bin/hostname"; chmod +x "$T/bin/hostname"

ENVV=(env -i PATH="$T/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" TMPDIR="$T"
  RH7_RESTIC_BIN="$RESTIC" RH7_RESTIC_REPO_HOST=127.0.0.1 RH7_RESTIC_PORT="$PORT"
  RH7_RESTIC_PATHS=$'~/.ssh\n~/.config\n~/.gnupg\n~/code\n~/Projects\n~/localtesting\n~/dotfiles'
  RH7_RESTIC_EXCLUDES=$'node_modules\n.venv\nvenv\n__pycache__\ntarget\ndist\nbuild\n.next\n.cache\n*.tmp\n.DS_Store\n~/.config/**/Cache*')
STATUS="$H/.local/state/rh7-restic/status.json"

echo "== setup (token on stdin) =="
printf 'rh7-restic:%s:%s\n' "$HOSTNAME_E2E" "$pw" | "${ENVV[@]}" bash "$SCRIPT" setup; rc=$?
check "setup exit 0" "$rc" 0
check "repo created under the user's path" "$([ -f "$DATA/$HOSTNAME_E2E/config" ] && echo y)" y
printf 'rh7-restic:%s:%s\n' "$HOSTNAME_E2E" "$pw" | "${ENVV[@]}" bash "$SCRIPT" setup >/dev/null 2>&1
check "setup is idempotent (existing repo, same key)" "$?" 0

echo "== run 1 =="
"${ENVV[@]}" bash "$SCRIPT" run; rc=$?
check "run exit 0" "$rc" 0
jq . "$STATUS"
check "ok" "$(jq -r .last_result "$STATUS")" ok
check "paths = existing policy paths" "$(jq -c .paths "$STATUS")" '["~/.ssh","~/.config","~/code","~/Projects"]'
check "snapshot_id 8 hex" "$(jq -r '.snapshot_id | test("^[0-9a-f]{8}$")' "$STATUS")" true
check "files_new = 4 (main.py, id_e2e, settings.ini, lora.safetensors)" "$(jq -r .files_new "$STATUS")" 4
first_bytes="$(jq -r .bytes_added "$STATUS")"

export RESTIC_REPOSITORY="rest:http://127.0.0.1:$PORT/$HOSTNAME_E2E/" RESTIC_REST_USERNAME="$HOSTNAME_E2E" \
  RESTIC_REST_PASSWORD="$pw" RESTIC_PASSWORD_FILE="$H/.config/rh7-restic/repo-password"
listing="$("$RESTIC" ls latest 2>/dev/null)"
echo "$listing" | sed 's/^/    /'
for gone in node_modules .venv Caches big.gguf rh7-restic; do
  check "excluded: $gone" "$(grep -c "$gone" <<<"$listing")" 0
done
for kept in main.py id_e2e settings.ini lora.safetensors; do
  check "included: $kept" "$(grep -c "/$kept\$" <<<"$listing")" 1
done

echo "== run 2 (nothing changed) =="
"${ENVV[@]}" bash "$SCRIPT" run; rc=$?
check "run 2 exit 0" "$rc" 0
second_bytes="$(jq -r .bytes_added "$STATUS")"
echo "    bytes_added: run 1 = $first_bytes, run 2 = $second_bytes; files_new run 2 = $(jq -r .files_new "$STATUS")"
check "run 2 adds ~0 bytes (< 1 KiB)" "$([ "$second_bytes" -lt 1024 ] && echo y)" y
check "run 2 has no new files" "$(jq -r .files_new "$STATUS")" 0
check "two snapshots" "$("$RESTIC" snapshots --json 2>/dev/null | jq length)" 2

echo "== append-only: the client cannot delete =="
snap="$(jq -r .snapshot_id "$STATUS")"
"$RESTIC" forget "$snap" >"$T/forget.out" 2>&1; frc=$?
sed 's/^/    /' "$T/forget.out" | grep -v '^    \s*\(runtime\|/\|\t\)' | head -8
check "restic forget fails" "$([ "$frc" -ne 0 ] && echo y)" y
check "both snapshots still there" "$("$RESTIC" snapshots --json 2>/dev/null | jq length)" 2

echo "== private repos: another user cannot read this repo =="
RESTIC_REST_USERNAME=intruder RESTIC_REST_PASSWORD=intruderpw "$RESTIC" cat config >"$T/intr.out" 2>&1; irc=$?
head -2 "$T/intr.out" | sed 's/^/    /'
check "intruder refused" "$([ "$irc" -ne 0 ] && echo y)" y

echo "== restore round-trip =="
"$RESTIC" restore latest --target "$T/restore" --include "$H/code/proj/main.py" >/dev/null 2>&1
check "restored file matches" "$(cat "$T/restore$H/code/proj/main.py" 2>/dev/null)" "print('hi')"

echo "== status / offline skip =="
"${ENVV[@]}" bash "$SCRIPT" status
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
"${ENVV[@]}" bash "$SCRIPT" run 2>/dev/null; rc=$?
check "server down -> exit 0, skipped offline" "$rc/$(jq -r '"\(.last_result)/\(.reason)"' "$STATUS")" "0/skipped/offline"
check "snapshot carried forward" "$(jq -r .snapshot_id "$STATUS")" "$snap"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
