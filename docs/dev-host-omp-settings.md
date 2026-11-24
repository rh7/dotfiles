# Dev-host OMP global settings

Owns [dotfiles#145](https://github.com/rh7/dotfiles/issues/145), part of the
[approved token plan](https://github.com/rh7/repo-management/issues/1209).
The live apply is **after this change merges**, not an effect of merging.

## Ownership

`hosts/rhdevvps/omp-settings.json` is a flat setting-path manifest, not an OMP
startup overlay. JSON avoids an additional YAML parser dependency. It manages:

- Lane compaction: threshold 120,000 tokens; idle compaction enabled above
  60,000 tokens after 300 seconds.
- Tool artifacts: spill threshold 16 KB; tail 150 lines.
- Reviewer compaction: 120,000 tokens for `reviewer-openai`, `reviewer-claude`,
  `reviewer-grok`, `gate-reviewer`, `reviewer`, and `security-reviewer`.
- Retry: `fallbackOn: usage-limit`, `usageAwareFallback: true`,
  `usageReservePolicy: auto`.
- Composer: `predictions: false` (no post-turn ghost text in an empty composer).
- Account usage reserve: `auth.accountPolicies` rules with `reservePct: 0` for
  the logged-in `xai-oauth` and `cursor` accounts. See
  [Account usage reserve](#account-usage-reserve).

No `modelRoles`, `retry.fallbackChains`, credentials, `task.agentAccountPools`,
or seat overlays are managed. Model routing remains with repo-management's
`scripts/portfolio model-route`. Other `task`/`retry` keys and custom reviewer
threshold entries survive apply. The six managed reviewer names override their
old values; they do not replace unrelated reviewer names.

Repo-management's existing coordinator/planner/lead overlays remain at 400,000
tokens with `idleEnabled: false`. Do not change them to adopt this manifest.

## Account usage reserve

Owns [dotfiles#153](https://github.com/rh7/dotfiles/issues/153). OMP keeps a
global `retry.usageReservePct` (10 on this host). Once an account's remaining
quota falls to that reserve, `retry.usageReservePolicy` decides what happens:
`confirm` stops an interactive lane at the "Coding-plan reserve reached" menu;
`auto` applies an eligible fallback without asking. Every lane is interactive,
so the manifest manages `usageReservePolicy: auto` (owner decision on #153,
2026-11-24). `retry.usageReservePct` itself is not managed.

A per-account `auth.accountPolicies[].reservePct` overrides the global value
for the matching stored OAuth account. With 0, the account stays eligible until
it is depleted; `retry.fallbackOn: usage-limit` then applies. The manifest sets
`reservePct: 0` for the xAI and Cursor accounts only. Anthropic and OpenAI
Codex accounts get no rule and keep the global 10%.

Each rule selects one account by an identity field of its stored credential.
OMP compares the field exactly; it does not use the `account:` identity key from
`omp usage accounts`.

- `xai-oauth`: `accountId` (the stored credential carries one).
- `cursor`: `email`. The stored Cursor credential has no `accountId` or
  `projectId`, so its identity key comes from token claims and an `accountId`
  selector matches nothing. This address is already public as a commit author
  in this repository.

These selectors are account labels, not credentials. Never add tokens or other
credential fields.

The manifest owns the **whole** `auth.accountPolicies` list, like every other
managed key, and apply writes it as one value. Apply never reads the agent
database or matches selectors against stored accounts:

- Preview always lists the live rules and shows the manifest rules on change,
  as provider, selector field names and numbers, never selector values.
- A live rule is managed when a manifest rule equals it except for
  `reservePct`. Any other live rule makes dry-run and apply refuse before the
  backup, naming the rule's index and provider. Add it to the manifest in a
  reviewed PR (or remove it through OMP), then preview again. No rule is
  dropped silently.
- A second xAI or Cursor account needs its own manifest rule.

Before any backup or write, apply validates the live config the way OMP 19.1.1
parses it:

- Every live rule matches OMP's rule schema: known fields only, an `account`
  with at least one of `email`/`accountId`/`projectId`, a finite `priority`,
  `reservePct` 0–100, and `reclaimAbovePct` above the rule's reserve and at
  most 100.
- `retry.usageReservePolicy` is one of `RESERVE_POLICIES` in
  `scripts/apply-omp-settings`.
- Each managed key's parent (`auth`, `retry`, …) is a mapping or absent; an
  explicit `auth: null` is refused too. `omp config list` hides a scalar or
  list parent and `omp config set` silently replaces it. The check runs OMP's
  own YAML parser through its bundled Bun runtime (`BUN_BE_BUN=1 omp -e …`)
  and prints only kinds, never values.

The manifest check is stricter: each rule needs `provider`, `account` and an
integer `reservePct` (`priority` and `reclaimAbovePct` are optional), all
numbers are integers (OMP writes `1.0` back as `1`), and no two rules share a
selector, because `omp config set` stores any array and a bad rule only fails
at credential selection.

After the writes and the read-back, apply asks OMP itself: `omp usage --redact
--json` on the target profile. Credentials resolve as in a normal run, from
the caller's `HOME` and `XDG_DATA_HOME` (a migrated `agent.db`, a broker
token); config overlays and the project layer stay isolated. Every account it
lists for a manifest provider (Xai Oauth, Cursor)
must show that provider's manifest reserve as an override, which the text view
prints as `reserve 0% (override)`, and each manifest provider must list at
least one account. Otherwise, or when `omp usage` fails or its output is
unparsable, apply restores the backup and exits nonzero, naming the provider
and the redacted account label. After a new login replaces an xAI or Cursor
account, apply therefore fails until the manifest selector is updated.

Post-apply evidence is OMP's own view, not the file:

```bash
omp usage --redact | grep -E '^[A-Z].* — |policy:'
omp config get retry.usageReservePct
omp config get retry.usageReservePolicy
```

Expect `policy: … reserve 0% (override)` under Xai Oauth and Cursor, no policy
line under Anthropic and Openai Codex, `retry.usageReservePct` 10 and
`retry.usageReservePolicy` auto. Post only these filtered lines; `--redact`
still prints partial identities.

## Preview and apply

Requirements: Linux dev host, Python 3, and OMP with `config list
--scope global --json` and bundled-Bun `BUN_BE_BUN=1 omp -e` support (verified
with OMP 19.1.1). This entrypoint targets the existing
regular `config.yml` in `PI_CODING_AGENT_DIR`, or `~/.omp/agent` when unset. It
is not a profile migration tool; use an explicit agent directory for a relocated
configuration.

From the reviewed, merged dotfiles revision:

```bash
PI_CODING_AGENT_DIR="$HOME/.omp/agent" ./scripts/apply-omp-settings --dry-run
PI_CODING_AGENT_DIR="$HOME/.omp/agent" ./scripts/apply-omp-settings
```

Preview reads a temporary copy with isolated profile/home/project settings. It
prints only the managed-key diff and does not create a DB, lock, backup, or
configuration in the target profile. Apply takes a private
`config.yml.bak-<UTC>` backup before the first write. Keep this backup outside
Git: it contains the **whole original config**, which may contain private data.

Writes use `omp config set <key> <value>` and OMP's settings lock, not a YAML
rewrite. `omp config set` republishes `config.yml` at 0600 with the default
group, so apply restores the mode and group it recorded before the backup, also
after a failed write; rollback does the same. Before/after output is limited to
the managed keys from `omp config list`; every managed value is read back. A
failed write/read or mismatch exits nonzero without an automatic rollback:
retain the printed backup path and inspect the failure. Reapplying converges the
managed values. Only a failed `omp usage` check restores the backup itself.

Quiesce OMP and every other global-config writer (`model-route`, interactive
`/settings`, logins, other apply processes) for the whole apply. The script
serializes its own apply/rollback invocations with
`<profile>/.apply-omp-settings.lock`; preview skips this lock. This is **not**
OMP's lock. OMP locks each individual setting write, not the whole multi-key
operation. Apply compares `config.yml` with its first read only once, just
before the backup: that catches a change while preparing, not one between that
check and the last write. A change made during the writes or the usage check is
not detected, and the usage-check rollback restores the backup over it.
Disjoint model-route keys are not written by this script.

## Rollback

Quiesce **all** global-config writers, including `model-route`, interactive
`/settings`, and other apply processes, before rollback:

```bash
PI_CODING_AGENT_DIR="$HOME/.omp/agent" \
  ./scripts/apply-omp-settings --rollback "$HOME/.omp/agent/config.yml.bak-<UTC>"
```

Use the exact backup path printed by apply. An empty path is refused before any
lock or OMP invocation. Rollback validates that backup,
not the current configuration: the "Before" display is best-effort. An existing
current file is backed up byte-for-byte even if malformed or outside this
script's managed-value schema. A missing current file is allowed, with no
recovery backup needed. Rollback then atomically restores the supplied backup's
exact bytes with the current file's mode and group (0600 when it was missing). It
restores the **whole file**, not only managed keys, so it also undoes
any routing/settings changes made since that backup. This full-file restore is
a maintenance-window operation, not an OMP per-key write. The script's own lock
does not exclude OMP's other writers. Missing, foreign, symlinked, or malformed
backups are refused. Do not paste backups or unfiltered configuration on GitHub.

## Adoption evidence

After merge, the dotfiles lane runs apply once and posts UTC, merged revision,
OMP version, backup path and filtered before/after on parent #1209. A code-only
PR uses `Refs #145`; the child remains open until these live gates pass:

1. Fresh lane effective settings: threshold 120,000, idle enabled, idle
   threshold 60,000, timeout 300, spill 16 KB.
2. Fresh seat launched through its unchanged overlay: threshold 400,000 and
   idle disabled. Check effective settings, not only raw global YAML.
3. `omp usage accounts` reports the owner's Anthropic identities. Report counts
   only; never publish account identifiers or credential material. If no usable
   provider account pool exists, prepare the owner step under parent #1209.

[repo-management#1210](https://github.com/rh7/repo-management/issues/1210) owns
cross-role docs and post-apply measured proof, including a real lane compaction
entry with reason `idle` after five idle minutes above 60,000 tokens. Coordinate
one writer: that lane must not also apply the global block. Neither successful
settings resolution nor dry-run proves a real idle-compaction event or measured
token savings. The parent's three-/seven-day re-measure remains separate.

Pre-merge account check on 2026-11-18, OMP 18.22.2: `omp usage accounts --json`
returned 5 visible identities, 2 Anthropic; the Anthropic-only usage query
returned 2 reports, 0 unreported accounts and 0 disabled credentials. No account
identifiers were retained here. An empty `task.agentAccountPools` is not an
absent provider pool: it sets optional per-agent restrictions, not the provider's
stored account inventory. No auth/account-pool change is part of this rollout.

## Verification

```bash
bash scripts/tests/apply-omp-settings.test.sh
```

The deterministic CLI fixture exercises the real entrypoint with temporary
profiles, including a read that writes a DB. CI discovers this test through
`scripts/tests/*.test.sh`; no installed OMP or provider credentials are required.
Real-OMP smoke checks use disposable profiles, never the live global file.
