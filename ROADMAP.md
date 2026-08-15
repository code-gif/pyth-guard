# Roadmap

Two deliverables with one motivation: making Pyth Pro safe to consume on
Cardano, and measuring whether existing consumers are.

1. **`pyth_guard`** — an Aiken library wrapping `pyth.get_updates` with the
   checks the Pyth withdraw script deliberately leaves to the consumer.
2. **`pythmon`** — an off-chain monitor logging Pyth Pro and comparing it
   against prices Cardano protocols are actually reading on-chain.

## Why it is worth doing

The Pyth Cardano documentation says it outright: the withdraw script verifies
signature validity, but *does not enforce freshness of the update, nor does it
disallow verifying the same update multiple times.* Every integrator has to
implement those checks themselves, in Aiken, correctly. A validator that skips
them settles against an hour-old signed payload, because the signature is still
perfectly valid.

The freshness check is also more subtle than it looks. The obvious
implementation — bound the message timestamp — is wrong, and wrong in a way
that still looks right in testing, because Pyth carries prices forward under
fresh message timestamps whenever publishers go quiet. Getting that distinction
into one reviewed place is most of this library's value.

## Current state

Written, tested and building. Verified end to end against Aiken v1.1.23,
stdlib v3.0.0 and Plutus V3: `aiken fmt --check` clean, `aiken check` reporting
75 of 75 unit tests passing, and `aiken build` emitting `price_lock` at 8,504
bytes and `price_ratchet` at 8,850 bytes.

- **`lib/pyth_guard.ak`** — generation-time freshness, timestamp consistency,
  bounded validity, feed identity and uniqueness, confidence width, market
  session, publisher floor, channel assertion, replay and cooldown primitives,
  sign-correct decimal rescaling. Rejections are typed values, so a caller can
  branch on *why* a price was refused rather than only failing.
- **`lib/pyth_guard/tests.ak`** — 59 tests covering every rejection reason,
  both validity-bound encodings, the microsecond freshness boundary, and the
  carried-forward attack.
- **`lib/pyth_guard/e2e_tests.ak`** — 16 tests driving `try_read` over a real
  signed Pyth payload (upstream's own vector) inside a transaction carrying the
  Pyth state as a reference input and the update as a withdrawal redeemer. This
  is the path every consumer actually calls, and it exercises the upstream
  binary parser rather than a hand-built fixture. The payload carries neither
  `confidence` nor `publisher_count`, so the guard's fail-closed behaviour is
  demonstrated on real bytes.
- **`validators/price_lock.ak`** and **`validators/price_ratchet.ak`** — a
  stateless and a stateful consumer. The pair exists because replay protection
  is only meaningful in the second, and the first says so instead of
  demonstrating a check it does not need.
- **`monitor/`** — store, Pyth Pro websocket client, chain poller, drift
  analysis, CLI, with its own suite of 59 Python tests (`pytest`, `ruff`). `python -m pythmon demo --check` runs the full
  pipeline on synthetic data with a known injected lag and asserts the
  pipeline reproduces it, so the join and the statistics are verifiable
  without a subscription.

## Next

### M1 — `read_many`, because the parse dominates

Measured, on the real payload, against the Plutus V3 per-transaction budget of
14,000,000 mem / 10,000,000,000 cpu:

| | mem | cpu | share of mem budget |
|---|---:|---:|---:|
| guard logic alone (`check`) | 272,420 | 88,417,015 | 1.9% |
| one full `try_read` | 2,448,875 | 771,362,276 | 17.5% |
| two `try_read`s, same payload | 4,668,982 | 1,474,285,704 | 33.4% |

Two conclusions, neither of which was obvious beforehand:

**The parser costs about nine times the guard.** Optimising the checks would be
wasted effort; essentially all of the budget goes to `pyth.get_updates`.

**That cost is paid per read, not per transaction.** Two feeds cost 1.91x one
feed, because `get_updates` re-parses every signed message from scratch and
nothing memoises it. A consumer settling several markets therefore hits a
ceiling around **six feeds per transaction**, and it is the payload being
walked repeatedly rather than anything the consumer wrote.

So `read_many` is no longer a question of taste: it is the difference between
six feeds and a payload-bounded number of them. It should parse once and walk
the resulting update per feed, returning one `Outcome` each. Deferred rather
than done because it changes the public API shape and deserves its own
design pass — in particular, whether a partial failure rejects the whole read.

### M2 — preprod deployment

Deploy both reference validators to preprod and submit the real transaction:
validity window, Pyth state as reference input, zero withdrawal with the signed
update as redeemer, consuming script alongside.

`e2e_tests.ak` now covers the transaction *shape* offline, so what remains is
specifically what a synthetic transaction cannot reach:

- **Signature verification.** `get_updates` calls
  `message.parse_without_verification`; signatures are checked only because the
  genuine Pyth withdraw script executes. No offline test runs that script.
- **The real Pyth state.** The tests use a stand-in policy id and withdraw
  script hash. A deployment resolves the actual ones.
- **Ledger acceptance.** Fees, script size, the execution budget as the node
  enforces it, and whether the `max_age_ms` window really does get transactions
  included at the rate the arithmetic in `docs/INTEGRATION.md` predicts.

Requires a Pyth Pro key.

### M3 — monitor targets

Identify which Cardano protocols read a price feed on-chain today and write a
decoder for each. This carries the most uncertainty in the plan, and the
uncertainty is about the ecosystem rather than the code: if few protocols
consume an on-chain feed, the monitor's contribution is the method and the
tooling rather than a broad survey. Worth resolving before promising a drift
report to anyone. See [docs/MONITORING.md](docs/MONITORING.md).

### M4 — upstream

Offer the library to
[`pyth-network/pyth-lazer-cardano`](https://github.com/pyth-network/pyth-lazer-cardano)
as a contribution rather than maintaining a fork. It is Apache-2.0 to match and
adds no dependencies beyond `aiken-lang/stdlib` and that repository, so the
merge path stays open. The `feedUpdateTimestamp` distinction in particular
belongs upstream, where every integrator gets it by default.

## Blocked

**Property-based testing.** The natural next step for a library that is mostly
inequalities, and currently unavailable: no released `aiken-lang/fuzz` targets
`aiken-lang/stdlib` v3.0.0 — every version pins v2.x — while
`pyth-lazer-cardano` requires v3.0.0. Adding `fuzz` therefore forces a stdlib
version conflict into the build. Unblocked by a `fuzz` release targeting stdlib
v3; until then the suite uses explicit boundary cases, which cover the same
edges less generatively.

## Known risks

- **Upstream API churn.** `pyth-lazer-cardano` publishes no tags and its
  manifest version is permanently `0.0.0`, so the dependency is pinned by
  commit hash. The library decodes the upstream `Feed` type field by field; a
  field added or reordered upstream changes what it reads. Bumping the pin is a
  reviewed change, not a routine one.
- **Silent compiler failures on Windows.** Aiken v1.1.23 on Windows exits
  non-zero for a compile error and prints nothing at all — verified against a
  deliberately broken one-line project with no dependencies, in both Git Bash
  and PowerShell. It makes any Windows-side mistake expensive to diagnose, and
  is why CI builds on Linux. Documented in the README and the troubleshooting
  table because anyone integrating from Windows will hit it.
- **Ecosystem depth.** See M3.

## Not planned

- **Negative-price feeds.** Energy futures, calendar spreads and policy rates
  can quote below zero. Supporting them means revisiting the confidence
  comparison and the rescaling sign convention together; until there is a
  concrete consumer, a fail-closed rejection is the honest behaviour.
- **EMA prices** and the other feed properties the guard does not read.
- **Off-chain transaction building.** Out of scope; the shape a transaction
  must take is documented in
  [docs/INTEGRATION.md](docs/INTEGRATION.md) instead.
