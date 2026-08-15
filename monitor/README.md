# pythmon

Off-chain drift monitor for Pyth Pro feeds consumed on Cardano.

It answers one question with evidence: **when a Cardano protocol reads a price
on-chain, how far is that price from what Pyth was publishing at the time?**

That is not the same question as "how old is it". A five-minute-old price in a
flat tape is harmless; a five-second-old price during a move is not. The report
gives the joint distribution of age and drift rather than either margin.

## Install

```bash
cd monitor
pip install -e ".[dev]"
```

Python 3.11+. Two runtime dependencies: `websockets` and `httpx`.

## Try it without a key

```bash
python -m pythmon demo --check
```

Generates a random walk at 200 ms, samples it into the chain table with a
deliberate 8-second lag, and asserts the pipeline reports that lag back
exactly. It is a test, not a slideshow — CI runs this line. It writes to
`data/demo.sqlite`, never to the capture database.

## Record

```bash
export PYTH_LAZER_TOKEN=...
python -m pythmon stream --feeds 16,1
```

Holds all three Pyth endpoints open at once, because any one of them drops
during a deployment. Ticks are deduplicated by primary key, so the redundancy
costs bandwidth and nothing else.

Every tick stores three timestamps: when Pyth *generated* the price, when it
produced the *message*, and when we *received* it. The first two diverge
whenever a price is carried forward — that divergence is the staleness
question. The last two are the width of your own transport, and you cannot
measure anyone else's lag without knowing your own.

## Watch a protocol

```bash
python -m pythmon poll --targets targets.json --interval 20
```

`targets.json` names the addresses to watch and the decoder for each:

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

A decoder takes an inline datum and returns a `DecodedPrice`, or `None` when
the UTxO is not a price at all. **No protocol decoders ship with this
package.** Each one is a guess about somebody else's datum encoding, and a
wrong guess produces confident, meaningless drift figures. They belong next to
evidence that they are right. See [`docs/MONITORING.md`](../docs/MONITORING.md).

The raw datum is stored alongside every observation, so a decoder that turns
out to be wrong can be replayed over history instead of invalidating it.

## Report

```bash
python -m pythmon drift --source someprotocol-ada-usd --feed 16
```

```
someprotocol-ada-usd  channel=fixed_rate@200ms  (n=4213)
  |drift|  median 3.10 bp   p90 11.40   p99 48.20   max 191.30
           signed median -0.40 bp
  age      median 21400 ms   p90 44100   p99 61200   max 98300
  match    median 3 ms   p99 9   max 41   (staleness of our own Pyth reference)
```

Reading it:

- **`|drift|`** is the headline. Absolute, because a lending protocol is
  exposed to error in whichever direction favours the borrower.
- **`signed median`** sits next to it because a persistent one-sided bias is a
  different finding from symmetric noise, and the absolute value hides it. A
  large signed median usually means a decoder is wrong, not that an oracle is.
- **`age`** is an *upper bound*. It is measured to our poll, which happens some
  time after the price actually landed on chain.
- **`match`** is how stale *our own* Pyth reference was for each sample. It
  grades the measurement, not the protocol. If it is large, the drift figures
  are weakly supported.

Anything dropped is counted and printed — observations with no Pyth tick in
range, observations whose matched tick carried no price, samples beyond a
plausibility bound. A silently truncated sample reads as a clean result, which
is the opposite of what it is.

## How the join works

For each on-chain observation, the most recent tick whose **local receipt
time** precedes it.

Not its publish time. Those are different clocks, and matching Pyth's clock
against ours would fold our own skew into every figure — a host running two
seconds fast would compare each chain price against a Pyth price from its own
future. Matches are also bounded (`--max-lookback-ms`, default 60 s), so a gap
in coverage shows up as unmatched samples rather than as enormous invented
drift.

Prices are recombined from mantissa and exponent with `Decimal`. A statistic
quoted in basis points should not carry binary rounding error of the same
order.

## Layout

```
pythmon/store.py    SQLite schema and batched writes
pythmon/stream.py   Pyth Pro websocket client
pythmon/chain.py    Cardano UTxO polling, pluggable decoders
pythmon/drift.py    the as-of join and the statistics
pythmon/cli.py      command line
tests/              run with `pytest`
```

The join happens at analysis time, not ingest time, so a bug in the analysis
costs a re-run rather than the data.
