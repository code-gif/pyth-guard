# Threat model

What `pyth_guard` assumes, what it guarantees given those assumptions, and what
remains your problem. Read the third section even if you skip the others: the
residual risks are the ones most likely to be mistaken for solved.

## Trust chain

A guarded read depends on four things, in order of how badly it fails:

1. **`pyth_id` names the genuine Pyth state NFT policy for your network.**
2. **The Pyth withdraw script executes in the transaction.** Guaranteed by
   construction — the redeemer `get_updates` reads exists only if the
   withdrawal exists, and a withdrawal runs its script.
3. **Pyth's publishers and signing infrastructure behave.** Outside anyone's
   control here.
4. **`pyth_guard`'s own logic is correct.** What the test suite is for.

### 1 is the one that matters

`pyth.get_updates` finds the Pyth state by scanning reference inputs for an NFT
under `pyth_id` named `"Pyth State"`, reads the withdraw script hash out of
that UTxO's inline datum, and then parses the update **without verifying its
signature** — because verification is a side effect of the real withdraw script
running.

If `pyth_id` is a policy the attacker controls, they:

1. mint a token under it named `"Pyth State"`;
2. park it at an always-succeeds script with an inline datum naming their own
   always-succeeds staking script;
3. include it as a reference input;
4. zero-withdraw from that staking script with a redeemer of their choosing;
5. write whatever price they like.

Every check in `pyth_guard` then passes, because every check operates on a
payload the attacker authored. No signature is verified anywhere in the
transaction.

**Therefore:** `pyth_id` must be a validator parameter, applied at compile time
and baked into the script hash. Never take it from a datum, a reference input,
or any other runtime source, and never make it upgradable without
understanding that whoever can change it can set your prices. The library
cannot detect a wrong value — from inside the script, an attacker's state UTxO
is indistinguishable from the real one.

Publish the parameterised script hash alongside your addresses so integrators
can verify which `pyth_id` you compiled against.

## Guarantees

Given the assumptions above, a `Price` returned by `read` satisfies:

- It was **generated** no earlier than `max_age_ms` before the last instant the
  ledger could have accepted the transaction — measured on
  `feed_update_timestamp`, not on the message timestamp. See "Carried-forward
  prices" below.
- It is the only price for the requested feed id in the transaction. Two
  updates carrying that feed, or one update carrying it twice, is a rejection
  rather than a silent choice.
- Its confidence is within `max_confidence_bps` of the price, unless the guard
  was built with `new_without_confidence_bound`.
- Optionally: it came from an allowed market session, from at least
  `min_publishers` publishers, on the expected channel.

### Carried-forward prices

Pyth carries a price forward when its publishers stop producing — a quiet feed,
a closed market, a holiday. The stream continues; `timestamp_us` stays current;
`feed_update_timestamp` does not move. Publisher count does not necessarily
drop, and confidence reflects the last real disagreement rather than the
current one.

A guard measuring age on `timestamp_us` accepts these indefinitely. `pyth_guard`
measures on `feed_update_timestamp` and requires the property to be present,
failing closed if it is absent, because silently falling back to the message
timestamp would reinstate the defect.

For markets with trading hours, add `with_sessions([Regular])`. The age check
and the session check overlap but are not the same: a market can close moments
after a genuinely fresh print, and the age check alone would wave that through
for a full `max_age_ms`.

**Evidential status.** The carry-forward behaviour and the meaning of
`feedUpdateTimestamp` are taken from Pyth's payload reference, not from
observation: every message in the test vector this project uses reports the two
timestamps as equal, so no captured payload here exhibits the divergence. The
guard's *handling* of it is tested directly; the frequency and duration of
carry-forward on any particular feed are not known and would need a live
subscription to characterise. Nothing in the design depends on that frequency —
measuring generation time is correct whether carry-forward is common or rare —
but a claim about how exposed a specific protocol is today would need the
measurement.

## Residual risks

These are real, they are not bugs, and no amount of checking inside a validator
removes them.

### The submitter picks the price inside the window

Every signed update whose generation time falls inside `max_age_ms` passes.
Those updates have distinct, increasing timestamps, so `newer_than` accepts all
of them. An adversary subscribes to the public stream, buffers the window, and
presents whichever tick suits them — the low print of the last minute to
trigger a liquidation, the high one to borrow against.

**A guard bounds the price to a window. It does not deliver the current price.**

Mitigations, in rough order of effectiveness:

- **Cooldowns.** `newer_by(price, last_seen_us, min_advance_us)` requires a
  minimum advance between the updates a given position is acted on, capping how
  often the choice can be exercised against the same target.
- **Haircuts sized to the window.** Value collateral at
  `at_confidence_floor`, debt at `at_confidence_ceiling`, and size the margin
  against the plausible move over `max_age_ms` rather than over zero.
- **A second source** for large or irreversible actions — a TWAP, an EMA, or a
  cross-check against another feed.

Shrinking `max_age_ms` is the obvious answer and it is largely unavailable; see
below.

### `max_age_ms` cannot be small

Freshness is checked at the transaction deadline, so `max_age_ms` is also the
window in which the transaction must reach a block. Cardano produces a block
roughly every 20 seconds. A 2-second window means most submissions expire
unincluded, and the arithmetic is in [INTEGRATION.md](INTEGRATION.md).

That asymmetry has a direction. A liquidator retries at leisure; a borrower
racing to add collateral gets one attempt per expiry, and every failed attempt
is a free option for the liquidator. Choosing `max_age_ms` for freshness alone
produces exactly that.

Size it for inclusion, and manage the resulting window with cooldowns and
haircuts.

### Future-dated updates

By default the "not future-dated" check compares against the transaction
deadline — which whoever builds the transaction chooses. For an update claiming
a time five minutes ahead, they set the deadline to match and the check passes.
It catches accidents, not intent.

`with_strict_future_dating()` moves the comparison to the validity range's
lower bound, which the ledger does enforce. It is opt-in because it requires
the builder to set `invalid_before` to at least the update's own timestamp; a
contract that enables it without changing its off-chain side will reject good
prices. Enable both together.

The exposure without it is bounded: a future-dated price requires a Pyth-side
clock fault, and the damage is liveness — a persisted future timestamp freezes
a stateful consumer until real time catches up.

### Replay is yours

`newer_than` compares. It does not persist. A contract that checks it against a
datum it never advances has no replay protection at all: the same still-fresh
update satisfies the check every transaction, for as long as it stays inside
the window.

`validators/price_ratchet.ak` shows the whole obligation — check the timestamp,
*and* write it into the continuing output, *and* pin the configuration so a
spend cannot relax its own guard, *and* require exactly one continuing output
so state cannot be forked into a fresh copy and a stale one.

`validators/price_lock.ak` deliberately omits all of that, because it is spent
exactly once and has no surviving state. Copying it into a stateful contract
produces a contract with no replay protection. That is why both examples exist.

### Datum-supplied guard parameters

Both reference validators build their `Guard` from a datum, which is realistic
and worth being explicit about. `check` rejects a negative `max_age_ms` or
`max_confidence_bps` as `MalformedGuard`, and `scaled` bounds `decimals`, but
nothing stops a datum specifying a `max_age_ms` of a year or a
`max_confidence_bps` of 10,000. If your datum is written by someone other than
the party bearing the risk, validate it where it is created.

## Out of scope

- **Negative prices.** A zero or negative mantissa is rejected. Feeds that can
  legitimately quote negative — energy futures, calendar spreads, policy rates
  — are not supported, and the confidence comparison depends on that sign.
- **EMA prices** and other feed properties the guard does not read.
- **Upstream `pyth-lazer-cardano` and the withdraw script.** Report issues
  there to Pyth.
- **The off-chain monitor**, which reads public data, holds no keys and signs
  nothing.

## Reporting

See [SECURITY.md](../SECURITY.md). A failing test in
`lib/pyth_guard/tests.ak` is the ideal report.
