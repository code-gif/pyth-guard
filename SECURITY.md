# Security policy

## Scope

`pyth-guard` is a validation library for on-chain code that consumes Pyth Pro
price updates on Cardano. Defects in it can cause a consuming contract to act
on a price it should have rejected. Reports are taken seriously.

In scope:

- `lib/pyth_guard.ak` — any input that passes `validate` when it should fail,
  or fails when it should pass.
- `validators/price_lock.ak` — any spend that succeeds outside the documented
  conditions.
- `docs/THREAT_MODEL.md` — any assumption stated there that does not hold.

Out of scope:

- Upstream `pyth-network/pyth-lazer-cardano` and the Pyth withdraw script.
  Report those to Pyth.
- The off-chain monitor in `monitor/`. It reads public data, holds no keys and
  signs nothing. Bugs there are ordinary bugs — open an issue.

## Reporting

Open a [private security advisory][advisory] on this repository. That keeps the
report confidential until a fix is published.

Please include the transaction shape or the exact `Guard` and `PriceUpdate`
values that reproduce the issue. A failing test in `lib/pyth_guard/tests.ak` is
the ideal report and the fastest route to a fix.

[advisory]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability

## What this library does not protect you from

These are documented at length in [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md).
Summarised here because they are the failure modes most likely to be mistaken
for a library bug:

1. **A wrong `pyth_id`.** Every guarantee rests on that parameter identifying
   the genuine Pyth state NFT for your network. Pass an attacker's policy id
   and they choose your prices. The library cannot detect this.
2. **Replay across transactions.** `newer_than` is a comparison, not a
   mechanism. If your contract does not persist and advance the timestamp, you
   have no replay protection.
3. **A validity range you did not constrain.** Freshness is measured against
   the transaction deadline. The off-chain builder chooses that deadline.

## Supported versions

Pre-1.0. Fixes land on `main`; there is no backport branch yet.
