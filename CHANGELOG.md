# Changelog

Notable changes to `pyth-guard`. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[semantic versioning](https://semver.org/), and is pre-1.0, so the public API
may still change.

## [Unreleased]

## [0.1.0]

First release.

### On-chain

- `pyth_guard` — freshness, confidence, feed-identity, market-session,
  publisher-count and channel checks over `pyth.get_updates`, plus replay and
  decimal-rescaling primitives.
- **Staleness is measured against `feed_update_timestamp`**, the time the price
  was generated, rather than the message timestamp. Pyth carries prices forward
  under fresh message timestamps when publishers go quiet or a market closes; a
  guard written against the message timestamp accepts an arbitrarily old price
  in a fresh envelope. The property is required, and a feed lacking it is
  refused rather than falling back.
- **Rejections are typed values.** `check` returns `Outcome` —
  `Accepted(Price)` or `Rejected(Rejection)`, one variant per condition — so
  callers can branch on the reason and tests can assert *which* check fired.
  `read` and `validate` wrap it for callers that want the transaction to fail.
  Aiken's prelude has no `Result`, so `Outcome` is defined by the library.
- `select` reads one feed out of several updates, permitting multi-protocol
  batching while refusing two updates that disagree about the same feed.
- Confidence bounds are **mandatory** in `new`; opting out requires the
  separately named `new_without_confidence_bound`.
- `with_sessions` constrains market sessions, needed for anything that is not a
  24/7 market.
- `with_strict_future_dating` checks future-dating against the ledger-enforced
  validity lower bound instead of the caller-chosen deadline. Opt-in, because
  it constrains how the transaction is built.
- `newer_by` supplies a per-position cooldown, the residual defence against an
  adversary choosing among the signed updates inside the freshness window.
- `scaled` / `scaled_up` round in explicit, opposite directions and stay
  directional for negative mantissas, which `at_confidence_floor` can produce.
  `decimals` is bounded, since it commonly arrives in a datum.
- Two reference consumers: `price_lock` (stateless, one-shot, no replay
  surface) and `price_ratchet` (stateful, demonstrating the full
  check-and-advance obligation).

### Off-chain

- `pythmon` — Pyth Pro websocket client across all three documented endpoints,
  Cardano UTxO poller with pluggable decoders, drift analysis, CLI.
- The as-of join matches on the **local receipt clock**, not Pyth's publish
  clock, so host clock skew cannot leak into the drift figures. Matches are
  bounded by a lookback window, and prices are recombined with `Decimal`.
- Everything dropped is counted and reported: unmatched observations, matches
  whose tick carried no price, and samples beyond a plausibility bound.
- `demo --check` runs the whole pipeline on synthetic data with a known
  injected lag and asserts it is reproduced exactly. CI runs it.

[Unreleased]: https://github.com/pyth-guard/pyth-guard/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pyth-guard/pyth-guard/releases/tag/v0.1.0
