# pyth-guard

Freshness, confidence and replay guards for [Pyth Pro][pro] price updates on
Cardano, plus an off-chain drift monitor.

The Pyth withdraw script verifies that a price update is validly signed. It
does **not** check that the update is recent, and it does **not** prevent the
same update being verified repeatedly. Pyth's own documentation says so
plainly. Those checks are the consumer's job, they are written in Aiken, and
getting one of them subtly wrong is the difference between a working protocol
and a drained one.

This library does them once, in one place, with the reasoning written down.

[pro]: https://docs.pyth.network/price-feeds/pro

## The check most integrations get wrong

A Lazer message carries two different timestamps, and only one of them means
"fresh":

| field | meaning |
|---|---|
| `timestamp_us` | when the **message** was produced |
| `feed_update_timestamp` | when that **price** was last generated |

They are usually equal. They diverge exactly when it matters. When publishers
go quiet or a market closes, Pyth keeps emitting messages that carry the last
price forward — validly signed, with a `timestamp_us` that is always current.

A guard written against `timestamp_us` therefore accepts an arbitrarily old
price wearing a fresh envelope. That is the same failure the withdraw script
warns about, reproduced one level down with a fresh signature on top.

`pyth_guard` measures staleness against `feed_update_timestamp`, which is
strictly stronger: a message is never delivered before the price inside it was
generated, so bounding the generation age bounds the delivery age too.

```aiken
test rejects_a_price_carried_forward_in_a_fresh_envelope() {
  pyth_guard.check(
    guard(),
    update(now_ms - 1_000, [ada_feed_at(now_ms - 21_600_000)]),
    window(now_ms - 10_000, now_ms),
  ) == Error(Stale)
}
```

One-second-old envelope, six-hour-old price. Refused, and refused *as stale*.

## On-chain

```aiken
use pyth_guard

let guard =
  pyth_guard.new(feed_id: 16, max_age_ms: 60_000, max_confidence_bps: 50)
    |> pyth_guard.with_min_publishers(8)

let price = pyth_guard.read(guard, pyth_id, self)
```

`read` fails unless all of the following hold:

| check | why |
|---|---|
| transaction has a finite upper validity bound | without one, "fresh" is meaningless |
| the **price** was generated no more than `max_age_ms` before the deadline | conservative over every acceptable inclusion time |
| the feed does not claim to predate the message carrying it | inconsistent payloads are not priced |
| the message is not dated after the deadline | a sanity bound; see [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md) |
| exactly one update, and one feed in it, carries the requested id | no guessing which of two prices was meant |
| confidence within `max_confidence_bps` of price | wide confidence means publishers disagree |
| market session is one you price in | optional; **required for anything with trading hours** |
| publisher count at or above the floor | optional |
| `channel_id` matches | optional |

Rejections are values, not just failures:

```aiken
pub fn check(guard, update, range) -> Result<Price, Rejection>
```

Every rejection has a distinct reason, so a test can assert *why* a price was
refused. `read` and `validate` wrap this for callers that want the transaction
to fail outright.

## What it does not do

Three things, stated here because a library that lists only its strengths is
harder to use safely than one that does not.

1. **It cannot validate `pyth_id`.** Every guarantee rests on that parameter
   naming the genuine Pyth state NFT policy. Supply an attacker's policy and
   they supply their own state UTxO and their own withdraw script, at which
   point no signature is verified anywhere in the transaction. Make it a
   compile-time validator parameter. Never read it from a datum.
2. **It cannot enforce replay protection.** `newer_than` is a comparison. It
   protects nothing unless your contract writes the new timestamp back into
   the state it will read next time. [`validators/price_ratchet.ak`](validators/price_ratchet.ak)
   demonstrates the complete pattern; `price_lock.ak` deliberately does not,
   and says why.
3. **It cannot deliver "the current price".** It bounds the price to a
   `max_age_ms`-wide window, and inside that window the transaction submitter
   chooses which signed tick to present. Sizing that window, and what to do
   about the residual, is [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md).

## Build

```bash
aiken check     # test suite
aiken build     # emits plutus.json
aiken fmt       # CI runs --check
```

Requires Aiken v1.1.21+. Dependencies are pinned exactly, including
`pyth-lazer-cardano` by commit hash — it publishes no tags and its manifest
version is permanently `0.0.0`, so nothing else identifies a release.

**Gotcha worth knowing:** `pyth-lazer-cardano` targets `aiken-lang/stdlib`
v3.0.0. Pinning a v2.x stdlib makes the compiler exit non-zero with *no error
message whatsoever*. If a build fails silently, check your stdlib version
first. This is also why there are no property-based tests: no released
`aiken-lang/fuzz` targets stdlib v3, so adding it reintroduces exactly that
conflict. See [ROADMAP.md](ROADMAP.md).

## Off-chain monitor

Measures how far Cardano protocols' on-chain prices sit from Pyth in practice.

```bash
cd monitor
pip install -e ".[dev]"
python -m pythmon demo --check      # full pipeline, synthetic data, no key
```

The demo injects a known 8-second lag and asserts the pipeline reports it back
exactly, so the join and the statistics are verifiable before a subscription
exists. See [`monitor/README.md`](monitor/README.md).

## Layout

```
lib/pyth_guard.ak            the library
lib/pyth_guard/tests.ak      test suite
validators/price_lock.ak     reference consumer: stateless, one-shot
validators/price_ratchet.ak  reference consumer: stateful, shows replay defence
docs/THREAT_MODEL.md         assumptions, and what breaks when they fail
docs/INTEGRATION.md          transaction construction and sizing max_age_ms
docs/MONITORING.md           writing a decoder for the off-chain monitor
monitor/                     the drift monitor
ROADMAP.md                   what is done, what is next, what is blocked
```

## License

Apache-2.0, matching `pyth-network/pyth-lazer-cardano`, to which this library
is offered as a contribution rather than a fork.
