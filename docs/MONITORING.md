# Writing a decoder

The monitor compares what Pyth published against what a Cardano protocol is
actually holding on-chain. To read the second half it needs a decoder for that
protocol's datum — a function from an inline datum to a price.

**No protocol decoders ship with this repository.** Each one is a claim about
somebody else's encoding, and a wrong claim produces confident, precise,
meaningless drift figures. A decoder belongs next to evidence that it is right.

## The interface

```python
from pythmon.chain import DecodedPrice

def ada_usd(datum: dict) -> DecodedPrice | None:
    """Decode one UTxO's inline datum, or return None if it is not a price."""
```

Returning `None` is normal, not an error: script addresses hold plenty of
UTxOs that are not prices, and the poller skips them quietly.

`DecodedPrice` carries three fields:

- `price` — the mantissa, already rescaled to `decimals`
- `decimals` — fixed-point places `price` is expressed in
- `stated_ts_us` — the timestamp the datum itself claims, if it carries one

Register it in a targets file:

```json
[
  {
    "source": "someprotocol-ada-usd",
    "address": "addr1...",
    "decoder": "mydecoders:ada_usd",
    "pyth_feed_id": 16
  }
]
```

```bash
python -m pythmon poll --targets targets.json --interval 20
```

`decoder` is a `module:function` reference resolved by import, so your decoders
live in your own package and are versioned with your evidence for them.

## Getting one right

A decoder is reverse-engineering. Three habits keep it honest:

**Verify against a known value first.** Find a UTxO whose price you can confirm
independently — the protocol's own UI, an explorer, a published figure — and
check your decoder reproduces it exactly before you trust a single drift
number.

**Watch the signed median, not the absolute one.** `pythmon drift` reports both
for this reason. Symmetric noise around zero is staleness. A persistent offset
of tens of basis points is almost always a decoder that is off by a factor, a
sign, or a decimal place. An oracle is rarely wrong in one direction all day; a
decoder usually is.

**Take the implausibility warning seriously.** Samples beyond 5,000 bp are
flagged rather than dropped. A decoder returning zero, or a feed paired with
the wrong `pyth_feed_id`, produces exactly 10,000 bp on every sample. That
warning has never once meant a real oracle failure.

## The raw datum is kept

Every observation stores the datum it was decoded from. When a decoder turns
out to be wrong — and a first version usually is — the fix can be replayed over
the whole history instead of invalidating it. This is also why the join lives
in `drift.py` rather than at ingest: a mistake in the analysis costs a re-run,
not the data.

## Choosing what to watch

Which Cardano protocols read a price feed on-chain today is an open question,
and an honest one: if very few do, the monitor's value is in the method and the
tooling rather than in a broad survey. See [ROADMAP.md](../ROADMAP.md).

A target is worth adding when three things hold: the protocol keeps its price
in an inline datum at a stable address, the price is denominated against a feed
Pyth publishes, and something on-chain actually depends on the value. A price
nobody consumes drifting by 50 bp is a curiosity; a liquidation threshold doing
so is a finding.

## Interpreting a report

```
someprotocol-ada-usd  channel=fixed_rate@200ms  (n=4213)
  |drift|  median 3.10 bp   p90 11.40   p99 48.20   max 191.30
           signed median -0.40 bp
  age      median 21400 ms   p90 44100   p99 61200   max 98300
  match    median 3 ms   p99 9   max 41   (staleness of our own Pyth reference)
```

- `age` is an **upper bound** — measured to our poll, which happens after the
  price landed. It overstates by up to one poll interval.
- `match` grades the measurement rather than the protocol. Large values mean
  our own Pyth coverage was thin at that moment and those drift figures are
  weakly supported.
- Every sample is weighted by **polling cadence**, not by on-chain updates. An
  unchanged UTxO polled 100 times contributes 100 samples. That is the right
  weighting for "how wrong is the price when someone reads it" and the wrong
  one for "how wrong is each update". Say which you are claiming.
- With fewer than ~100 samples, `p99` interpolates the top two order statistics
  and is the maximum wearing a percentile's name. The report says so.
