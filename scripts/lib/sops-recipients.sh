# shellcheck shell=bash
#
# Edit .sops.yaml to declare one more age recipient (rh7/rh-device-management#310).
#
# Sourced by scripts/sops-add-host.sh; pinned by scripts/tests/sops-recipients.test.sh.
#
# WHY A TEXT EDIT AND NOT yq: the fleet has no single YAML editor to rely on.
# modules/common.nix installs kislyuk's python `yq`, dev-apps installs mikefarah's
# Go `yq` via Homebrew — same name, different language — and mikefarah's also
# rewrites the whole file (anchor alignment, indentation) on every edit. So this
# is a deliberately NARROW edit of the one shape .sops.yaml has:
#
#   keys:
#     - &name   age1...        # one anchor per recipient
#   creation_rules:
#     - path_regex: ...
#       key_groups:
#         - age: [ *name, ... ] # ONE flow sequence of aliases
#
# Anything else — a second creation rule, a block-style age list, a literal key in
# the list — is REFUSED rather than guessed at. The predecessor (the old
# setup-secrets.sh) matched sed anchors that no longer existed, changed nothing,
# and printed success. Every outcome here is explicit:
#
#   0   edited: anchor and alias added (or the missing half of them)
#   10  already declared: file untouched
#   1   refused / error: message on stderr, file untouched
#
# The edit is re-checked after it is written (it must now read as "already
# declared"), and sops-add-host.sh then lets `sops updatekeys` — a real YAML
# parser — consume it and verifies the resulting recipient set.

SOPS_HOST_RE='^[A-Za-z0-9][A-Za-z0-9-]*$'
SOPS_AGE_PUB_RE='^age1[0-9a-z]{58}$'

# _sops_yaml_plan <file> <host> <pubkey>
# Prints the edited file on stdout and exits 0, or exits 10 (already declared,
# prints nothing), or exits 2 with a message on stderr.
_sops_yaml_plan() {
  awk -v host="$2" -v pub="$3" '
    function fail(msg) { print "refusing: " msg > "/dev/stderr"; failed = 1; exit 2 }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    {
      line[NR] = $0
    }
    /^[[:space:]]*keys:[[:space:]]*$/ { keys_hdr++; in_keys = 1; next }
    in_keys {
      if ($0 ~ /^[[:space:]]*-[[:space:]]+&[A-Za-z0-9._-]+[[:space:]]+age1[0-9a-z]+[[:space:]]*(#.*)?$/) {
        match($0, /&[A-Za-z0-9._-]+/); name = substr($0, RSTART + 1, RLENGTH - 1)
        match($0, /age1[0-9a-z]+/);    key  = substr($0, RSTART, RLENGTH)
        last_entry = NR
        if (name == host) { anchor_line = NR; anchor_key = key }
        if (key == pub)   { pub_owner = name }
        next
      }
      if ($0 ~ /^[[:space:]]*#/) next
      in_keys = 0
    }
    /^[[:space:]]*(-[[:space:]]+)?path_regex:/ { rules++ }
    /^[[:space:]]*(-[[:space:]]+)?age:/ {
      if ($0 ~ /^[[:space:]]*(-[[:space:]]+)?age:[[:space:]]*\[[^]]*\][[:space:]]*(#.*)?$/) { flows++; flow_line = NR }
      else { block_age++ }
    }
    END {
      if (failed) exit 2
      if (keys_hdr != 1)   fail("expected exactly one top-level \"keys:\" list, found " keys_hdr + 0)
      if (!last_entry)     fail("no \"- &name age1...\" entries under keys:")
      if (rules != 1)      fail("expected exactly one creation rule (path_regex), found " rules + 0 " — decide by hand which rule a new host belongs to")
      if (block_age)       fail("the creation rule age list is not a one-line flow sequence [ *a, *b ]")
      if (flows != 1)      fail("expected exactly one \"age: [ ... ]\" flow sequence, found " flows + 0)

      fl = line[flow_line]
      open = index(fl, "["); rel = index(substr(fl, open + 1), "]")
      inner = substr(fl, open + 1, rel - 1)
      n = split(inner, items, ",")
      has_alias = 0; kept = ""
      for (i = 1; i <= n; i++) {
        it = trim(items[i])
        if (it == "" && n == 1) continue
        if (it !~ /^\*[A-Za-z0-9._-]+$/) fail("age list item \"" it "\" is not an alias (*name)")
        if (it == "*" host) has_alias = 1
        kept = (kept == "" ? it : kept ", " it)
      }

      if (anchor_line && anchor_key != pub)
        fail("&" host " already exists with a DIFFERENT key (" anchor_key "). Rotating a recipient is a deliberate decision: remove the old key line and its alias by hand first.")
      if (pub_owner != "" && pub_owner != host)
        fail("this key is already declared as &" pub_owner " — one key, one name")
      if (!anchor_line && has_alias)
        fail("*" host " is in the age list but &" host " is not defined under keys:")
      if (anchor_line && has_alias) exit 10

      if (!anchor_line) {
        le = line[last_entry]
        match(le, /^[[:space:]]*-[[:space:]]+/); prefix = substr(le, 1, RLENGTH)
        entry = prefix "&" host
        pad = index(le, "age1") - 1 - length(entry)
        if (pad < 1) pad = 1
        for (i = 0; i < pad; i++) entry = entry " "
        entry = entry pub
      }
      if (!has_alias) {
        newlist = (kept == "" ? "*" host : kept ", *" host)
        line[flow_line] = substr(fl, 1, open) " " newlist " " substr(fl, open + rel)
      }
      for (i = 1; i <= NR; i++) {
        print line[i]
        if (!anchor_line && i == last_entry) print entry
      }
      exit 0
    }
  ' "$1"
}

# sops_yaml_add_recipient <file> <host> <age1pubkey>   → 0 edited | 10 present | 1 refused
sops_yaml_add_recipient() {
  local file="$1" host="$2" pub="$3" tmp rc=0
  if [[ ! "$host" =~ $SOPS_HOST_RE ]]; then
    echo "refusing: '$host' is not a valid host/anchor name (letters, digits, '-')" >&2; return 1
  fi
  if [[ ! "$pub" =~ $SOPS_AGE_PUB_RE ]]; then
    echo "refusing: '$pub' is not an age X25519 public key (age1 + 58 lowercase bech32 chars)" >&2; return 1
  fi
  [[ -f "$file" ]] || { echo "refusing: $file not found" >&2; return 1; }

  tmp=$(mktemp "${file}.XXXXXX") || return 1
  _sops_yaml_plan "$file" "$host" "$pub" > "$tmp" || rc=$?
  case "$rc" in
    0)  ;;
    10) rm -f "$tmp"; return 10 ;;
    *)  rm -f "$tmp"; return 1 ;;
  esac

  # The written file must now read as "already declared" — otherwise the edit
  # did not land the way the planner believes, and nothing downstream may run.
  rc=0
  _sops_yaml_plan "$tmp" "$host" "$pub" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 10 ]]; then
    rm -f "$tmp"
    echo "refusing: post-edit check failed (the edited file does not declare $host) — $file left untouched" >&2
    return 1
  fi
  cat "$tmp" > "$file" && rm -f "$tmp"
}

# sops_metadata_recipients <encrypted-file> — age recipients recorded in the
# file's sops metadata, one per line, sorted. Prints nothing if none.
sops_metadata_recipients() {
  grep -oE 'recipient: age1[0-9a-z]{58}' "$1" | awk '{print $2}' | sort -u || true
}
