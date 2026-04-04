{ ... }:

{
  # ── Crypto wallet and portfolio apps ─────────────────────────────────────
  homebrew.casks = [
    "electrum"
    "ledger-live"
    "mycrypto"
    # exodus, keepkey — not in Homebrew
  ];

  # Note: ElectrumSV is not in Homebrew — manual install
}
