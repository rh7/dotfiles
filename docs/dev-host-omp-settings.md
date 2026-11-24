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
- Retry: `fallbackOn: usage-limit`, `usageAwareFallback: true`.
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
global `retry.usageReservePct` (10 on this host) and, with
`retry.usageReservePolicy: confirm`, stops a lane at the "Coding-plan reserve
reached" menu once an account's remaining quota falls to that reserve. A
per-account `auth.accountPolicies[].reservePct` overrides the global value for
the matching stored OAuth account. With 0, the account stays eligible until it
is depleted; `retry.fallbackOn: usage-limit` then applies.

The manifest sets `reservePct: 0` for the xAI and Cursor accounts only.
Anthropic and OpenAI Codex accounts get no rule and keep the global 10%.
Neither `retry.usageReservePct` nor `retry.usageReservePolicy` is managed or
changed here.

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

Merge rules: the manifest owns **every** rule of each provider it names. Apply
drops other existing rules for `xai-oauth` and `cursor`, because two rules
matching the same stored account make OMP refuse credential selection for that
provider. Rules for other providers are kept unchanged. Before/after output
shows each rule's provider, selector field names and numbers, never the
selector values.

The manifest check mirrors OMP's rule parser (exact fields, at least one of
`email`/`accountId`/`projectId`, `reservePct` 0–100), because `omp config set`
stores any array and a bad rule only fails at credential selection.

A rule that matches no stored account is ignored by OMP. After a new login
replaces an xAI or Cursor account, update its selector and reapply; until then
that account falls back to the global reserve.

Post-apply evidence is OMP's own view, not the file:

```bash
omp usage --redact | grep -E '^[A-Z].* — |policy:'
omp config get retry.usageReservePct
```

Expect `policy: … reserve 0% (override)` under Xai Oauth and Cursor, no policy
line under Anthropic and Openai Codex, and `retry.usageReservePct` 10. Post only
these filtered lines; `--redact` still prints partial identities.

## Preview and apply

Requirements: Linux dev host, Python 3, and OMP with `config list --scope global
--json` support (verified with OMP 18.22.2). This entrypoint targets the existing
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
rewrite. Before/after output is limited to the managed keys from `omp config
list`; every managed value is read back. A failed write/read or mismatch exits
nonzero. A partial apply is not rolled back automatically: retain the printed
backup path and inspect the failure. Reapplying converges the managed values.

Serialize this operation with other global writers. The script serializes its
own apply/rollback invocations with `<profile>/.apply-omp-settings.lock`;
preview skips this lock. This is **not** OMP's lock. OMP locks each
individual setting write, not the whole multi-key operation. In particular, do
not concurrently change `task.agentCompactionThresholdOverrides` elsewhere.
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
exact bytes. It restores the **whole file**, not only managed keys, so it also undoes
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
