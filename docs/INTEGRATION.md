# Integration guide

Everything needed to consume a guarded Pyth Pro price on Cardano: what the
transaction must contain, how to size `max_age_ms`, and which subscription
properties are not optional.

## 1. Parameterise your validator with `pyth_id`

```aiken
validator my_protocol(pyth_id: PolicyId) {
  spend(datum, redeemer, own_ref, self) {
    let guard = pyth_guard.new(16, 60_000, 50)
    let price = pyth_guard.read(guard, pyth_id, self)
    ...
  }
}
```

`pyth_id` is the policy id of the Pyth state NFT for your network. Get it from
Pyth's [contract addresses][addr] page and **apply it at compile time**. It is
the root of the entire trust chain; a runtime-supplied value hands price
control to whoever supplies it. See [THREAT_MODEL.md](THREAT_MODEL.md).

Publish the resulting parameterised script hash so integrators can check which
`pyth_id` you built against.

[addr]: https://docs.pyth.network/price-feeds/pro/contract-addresses

## 2. Subscribe to the right properties

The guard needs `price`, `exponent`, and `feedUpdateTimestamp`. It refuses a
feed without the last one, because a price whose generation time is unknown has
unknown age — see the README.

Add `confidence` unless you built the guard with
`new_without_confidence_bound`, `publisherCount` if you set a floor, and
`marketSession` if you set one.

```json
{
  "type": "subscribe",
  "subscriptionId": 1,
  "priceFeedIds": [16],
  "properties": ["price", "exponent", "confidence",
                 "publisherCount", "feedUpdateTimestamp"],
  "formats": ["cardano"],
  "deliveryFormat": "json",
  "channel": "fixed_rate@200ms",
  "jsonBinaryEncoding": "hex"
}
```

You need the binary payload, not the parsed JSON, to put on chain. The parsed
fields are for your own logging.

## 3. Build the transaction

Four things must be present together:

1. **The Pyth state UTxO as a reference input.**
2. **A zero withdrawal from the Pyth withdraw script**, with the list of signed
   update messages as its redeemer.
3. **Your consuming script**, spending in the same transaction.
4. **A finite `invalid_hereafter`.** Without it the script has no notion of
   "now" and rejects the transaction outright as `UnboundedValidity`.

Set the deadline from the price you are presenting:

```
invalid_hereafter = feed_update_timestamp_ms + max_age_ms
```

and, if the guard uses `with_strict_future_dating()`:

```
invalid_before    = message_timestamp_us / 1000
```

Both bounds are POSIX milliseconds. Note that the ledger's `invalid_hereafter`
is **exclusive**, so the last acceptable instant is one millisecond earlier —
`pyth_guard` accounts for this, and both readings are covered by the test
suite.

### Sharing a transaction with another protocol

Permitted. Updates that do not carry your feed id are ignored. What is refused
is *two* updates both carrying your feed, or one update carrying it twice:
those are validly signed prices that disagree, and choosing between them is a
decision the transaction author would otherwise be making on your behalf.

## 4. Size `max_age_ms` for inclusion, not for freshness

This is the parameter integrators most often get wrong, and the failure is not
a security failure — it is transactions that never land.

Because freshness is measured at the deadline, `max_age_ms` is also the window
in which your transaction must reach a block. Cardano has 1-second slots and an
active slot coefficient of 0.05, so the probability of at least one block in a
window of *W* seconds is `1 − 0.95^W`:

| `max_age_ms` | chance of inclusion before expiry |
|---:|---:|
| 2 000 | ~10% |
| 20 000 | ~64% |
| 30 000 | ~79% |
| 60 000 | ~95% |
| 120 000 | ~99.8% |

And that is before subtracting the time to fetch the update, build, sign and
propagate — all of which comes out of the same budget.

**Start at 60 000 ms.** Go lower only with a measured reason and an appetite
for retries.

The instinct to shrink this for safety is understandable and mostly wrong. A
tight window does not make the price more current; it makes the transaction
more likely to expire. Worse, it is asymmetric: a liquidator retries at
leisure, while a borrower racing to post collateral loses their attempt on
every expiry.

Manage the width you are left with by valuing collateral at
`at_confidence_floor`, debt at `at_confidence_ceiling`, and using `newer_by`
for a per-position cooldown. See the residual-risk section of
[THREAT_MODEL.md](THREAT_MODEL.md).

## 5. Choose a rounding direction deliberately

`scaled` rounds down and `scaled_up` rounds up. Where the rescale is lossy they
differ by one unit in the last place, and which one you want is not a matter of
taste:

- Valuing **collateral**, or deciding a position is **solvent**: round down,
  and use `at_confidence_floor`. Both err toward "less than you hoped".
- Valuing **debt**, or sizing a **margin requirement**: round up, and use
  `at_confidence_ceiling`.

The rule is to pick the direction that costs an attacker money rather than the
one that costs you money.

`decimals` is bounded to `max_decimals` (32). It commonly comes from a datum,
and an unbounded power of ten is an execution-budget denial of service.

## 6. If you keep state, advance the timestamp

`newer_than` is a comparison, not a mechanism. A stateful consumer must persist
the price's `generated_us` and require it to advance — and must write the new
value into its continuing output in the same spend. Copy
[`validators/price_ratchet.ak`](../validators/price_ratchet.ak), which pins all
four conditions: advance, persist, immutable configuration, exactly one
continuing output.

A one-shot consumer that is fully spent has no replay surface and needs none of
this; [`validators/price_lock.ak`](../validators/price_lock.ak) is the example,
and says so explicitly rather than performing a check it does not need.

## Troubleshooting

| symptom | cause |
|---|---|
| `aiken build` exits non-zero with **no message at all** | stdlib version conflict. `pyth-lazer-cardano` requires `aiken-lang/stdlib` v3.0.0; a v2.x pin fails silently. Check first, always. |
| `transaction has no finite upper validity bound` | no `invalid_hereafter`. Some builders omit it by default. |
| `feed carries no feedUpdateTimestamp` | the property was not in your subscription. Add it; the guard will not fall back. |
| `price was generated more than max_age_ms before the deadline` on a live feed | either the deadline is too far ahead of the price, or the feed is being carried forward and is genuinely stale. Log `delivered_us` and `generated_us` separately to tell which. |
| `requested feed appears more than once` | two updates in the transaction carry your feed. Present one. |
| transactions expire before inclusion | `max_age_ms` too small. See §4. |
| `confidence bound required but update carries no confidence` | subscribe to `confidence`, or use `new_without_confidence_bound` deliberately. |
| `market session is not one this contract prices in` | the market is shut. Expected outside trading hours. |
