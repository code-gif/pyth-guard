"""Drift analysis: how stale is an on-chain price when someone reads it?

The measurement is an as-of join. For each on-chain observation, find the Pyth
price we already held at that instant, and report two numbers:

  observed_age_ms  how old the on-chain price was, by its own stated timestamp
  drift_bp         how far the on-chain price sat from Pyth at that instant

Drift is the number that matters to a liquidation engine, and it is not implied
by age alone: a five-minute-old price in a flat tape is harmless, and a
five-second-old price during a move is not. Reporting the joint distribution
rather than either margin is the whole contribution.

Three details make the difference between a measurement and a number:

**The join runs on the local clock.** Each observation is matched against the
most recent tick whose *local receipt time* precedes it, not the most recent
Pyth *publish* time. Those are different clocks. Matching publish time against
our wall clock folds our own clock skew into every drift figure, and does it
invisibly — a host running two seconds fast would compare each chain price
against a Pyth price from its own future.

**Matches are bounded.** A tick from an hour before the observation is not an
answer to "what was the price then". Anything older than ``max_lookback``
is dropped and counted, so a gap in coverage shows up as unmatched samples
rather than as enormous fictitious drift.

**Prices are exact.** Mantissa and exponent are recombined with ``Decimal``,
not by multiplying a float by a negative power of ten. A statistic quoted in
basis points should not carry binary rounding error of the same order.
"""

from __future__ import annotations

import statistics
from dataclasses import dataclass
from decimal import Decimal

from .store import Store

DEFAULT_MAX_LOOKBACK_MS = 60_000

#: |drift| at or beyond this is almost certainly a decoder or feed-pairing
#: mistake rather than an oracle lagging the market: 50% is far outside what
#: staleness produces on any feed worth monitoring. Such rows are counted and
#: surfaced, never silently discarded — a suppressed outlier reads as a clean
#: result, which is the opposite of what it is.
IMPLAUSIBLE_DRIFT_BP = 5_000


@dataclass(slots=True)
class DriftRow:
    source: str
    observed_us: int
    chain_price: Decimal
    pyth_price: Decimal
    drift_bp: float
    #: Age of the on-chain price by its own stated timestamp. An upper bound:
    #: it is measured to our poll, which happens some time after the price
    #: actually landed on chain.
    observed_age_ms: float | None
    #: How stale our own Pyth reference was for this sample. Large values mean
    #: the drift figure is weakly supported, not that the chain was stale.
    match_age_ms: float


@dataclass(slots=True)
class DriftResult:
    rows: list[DriftRow]
    #: Observations with no Pyth tick inside the lookback window. Reported
    #: rather than silently dropped: they are gaps in our own coverage.
    unmatched: int
    #: Observations whose matched tick carried no price, or a zero price. The
    #: feed went quiet; the observation is not comparable and is not an error.
    no_reference: int
    channel: str


_AS_OF_SQL = """
WITH matched AS (
    SELECT
        o.source,
        o.observed_us,
        o.price     AS chain_price,
        o.decimals,
        o.stated_ts_us,
        (SELECT t.ts_us
           FROM pyth_ticks t
          WHERE t.feed_id = :feed_id
            AND t.channel = :channel
            AND t.recv_wall_us <= o.observed_us
            AND t.recv_wall_us >= o.observed_us - :max_lookback_us
          ORDER BY t.recv_wall_us DESC, t.ts_us DESC
          LIMIT 1) AS pyth_ts_us
      FROM chain_obs o
     WHERE o.source = :source
       AND o.price IS NOT NULL
)
SELECT
    m.source, m.observed_us, m.chain_price, m.decimals, m.stated_ts_us,
    t.price, t.exponent, t.recv_wall_us
  FROM matched m
  JOIN pyth_ticks t
    ON t.feed_id = :feed_id
   AND t.channel = :channel
   AND t.ts_us   = m.pyth_ts_us
 ORDER BY m.observed_us
"""

_UNMATCHED_SQL = """
SELECT COUNT(*)
  FROM chain_obs o
 WHERE o.source = :source
   AND o.price IS NOT NULL
   AND NOT EXISTS (
        SELECT 1 FROM pyth_ticks t
         WHERE t.feed_id = :feed_id
           AND t.channel = :channel
           AND t.recv_wall_us <= o.observed_us
           AND t.recv_wall_us >= o.observed_us - :max_lookback_us)
"""


def resolve_channel(store: Store, feed_id: int, channel: str | None = None) -> str:
    """Pick the channel to analyse, refusing to mix two of them.

    Channels are different sampling rates of the same feed. Pooling them makes
    the tick spacing — and therefore the as-of match quality — depend on which
    subscriptions happened to be running.
    """
    if channel is not None:
        return channel
    cur = store.db.execute(
        "SELECT DISTINCT channel FROM pyth_ticks WHERE feed_id = ? ORDER BY channel",
        (feed_id,),
    )
    found = [row[0] for row in cur]
    if not found:
        raise ValueError(f"no ticks stored for feed {feed_id}")
    if len(found) > 1:
        raise ValueError(
            f"feed {feed_id} has ticks on {len(found)} channels ({', '.join(found)}); "
            "pass --channel to choose one"
        )
    return found[0]


def compute(
    store: Store,
    source: str,
    feed_id: int,
    channel: str | None = None,
    max_lookback_ms: int = DEFAULT_MAX_LOOKBACK_MS,
) -> DriftResult:
    resolved = resolve_channel(store, feed_id, channel)
    params = {
        "source": source,
        "feed_id": feed_id,
        "channel": resolved,
        "max_lookback_us": max_lookback_ms * 1_000,
    }

    rows: list[DriftRow] = []
    no_reference = 0
    for (
        src,
        observed_us,
        chain_mantissa,
        decimals,
        stated_ts_us,
        pyth_mantissa,
        pyth_exponent,
        pyth_recv_wall_us,
    ) in store.db.execute(_AS_OF_SQL, params):
        if pyth_mantissa is None or pyth_exponent is None:
            # The tick exists but carries no price — the feed went quiet.
            # Recorded at ingest on purpose; not comparable here, but counted,
            # because "we had no reference" and "the chain matched Pyth" must
            # not look the same in a report.
            no_reference += 1
            continue
        pyth = Decimal(pyth_mantissa).scaleb(pyth_exponent)
        if pyth == 0:
            no_reference += 1
            continue
        chain = Decimal(chain_mantissa).scaleb(-decimals)
        drift_bp = float((chain - pyth) / pyth * 10_000)
        rows.append(
            DriftRow(
                source=src,
                observed_us=observed_us,
                chain_price=chain,
                pyth_price=pyth,
                drift_bp=drift_bp,
                observed_age_ms=(
                    None if stated_ts_us is None else (observed_us - stated_ts_us) / 1_000
                ),
                match_age_ms=(observed_us - pyth_recv_wall_us) / 1_000,
            )
        )

    unmatched = store.db.execute(_UNMATCHED_SQL, params).fetchone()[0]
    return DriftResult(
        rows=rows, unmatched=unmatched, no_reference=no_reference, channel=resolved
    )


def percentile(sorted_values: list[float], q: float) -> float:
    """Linear interpolation between order statistics.

    Matches the default definition used by NumPy and R's type 7, so a figure
    quoted here can be reproduced by anyone re-running the query themselves.
    Expects an already-sorted list.
    """
    if not sorted_values:
        raise ValueError("percentile of an empty sequence")
    if len(sorted_values) == 1:
        return sorted_values[0]
    pos = q * (len(sorted_values) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_values) - 1)
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * (pos - lo)


def _spread(values: list[float]) -> dict:
    ordered = sorted(values)
    return {
        "median": percentile(ordered, 0.50),
        "p90": percentile(ordered, 0.90),
        "p99": percentile(ordered, 0.99),
        "max": ordered[-1],
        "mean": statistics.fmean(ordered),
    }


def summarize(result: DriftResult) -> dict:
    """Percentiles of drift and age.

    Absolute drift, because a lending protocol is exposed to error in whichever
    direction favours the borrower. The signed median is reported alongside it,
    because a persistent one-sided bias is a different finding from symmetric
    noise and the absolute value hides it.
    """
    out: dict = {
        "n": len(result.rows),
        "unmatched": result.unmatched,
        "no_reference": result.no_reference,
        "implausible": sum(
            1 for r in result.rows if abs(r.drift_bp) >= IMPLAUSIBLE_DRIFT_BP
        ),
        "channel": result.channel,
    }
    if not result.rows:
        return out

    out["drift_bp"] = _spread([abs(r.drift_bp) for r in result.rows])
    out["drift_bp"]["signed_median"] = percentile(
        sorted(r.drift_bp for r in result.rows), 0.50
    )
    out["match_age_ms"] = _spread([r.match_age_ms for r in result.rows])

    ages = [r.observed_age_ms for r in result.rows if r.observed_age_ms is not None]
    if ages:
        out["observed_age_ms"] = _spread(ages)
    return out


def format_report(source: str, summary: dict) -> str:
    header = f"{source}  channel={summary.get('channel', '?')}"
    if not summary.get("n"):
        detail = (
            f" ({summary.get('unmatched', 0)} observations had no Pyth tick in range)"
            if summary.get("unmatched")
            else ""
        )
        return f"{header}\n  no overlapping observations yet{detail}"

    d = summary["drift_bp"]
    lines = [
        f"{header}  (n={summary['n']})",
        f"  |drift|  median {d['median']:.2f} bp   "
        f"p90 {d['p90']:.2f}   p99 {d['p99']:.2f}   max {d['max']:.2f}",
        f"           signed median {d['signed_median']:+.2f} bp",
    ]
    if "observed_age_ms" in summary:
        a = summary["observed_age_ms"]
        lines.append(
            f"  age      median {a['median']:.0f} ms   "
            f"p90 {a['p90']:.0f}   p99 {a['p99']:.0f}   max {a['max']:.0f}"
        )
    m = summary["match_age_ms"]
    lines.append(
        f"  match    median {m['median']:.0f} ms   p99 {m['p99']:.0f}   "
        f"max {m['max']:.0f}   (staleness of our own Pyth reference)"
    )
    if summary["n"] < 100:
        # p99 of fewer than 101 samples interpolates the top two order
        # statistics, so it is the maximum wearing a percentile's name.
        lines.append(f"  note     n={summary['n']}: p99 is not a tail estimate")
    if summary.get("unmatched"):
        lines.append(
            f"  dropped  {summary['unmatched']} observations with no Pyth tick in range"
        )
    if summary.get("no_reference"):
        lines.append(
            f"  dropped  {summary['no_reference']} observations whose Pyth tick "
            "carried no price"
        )
    if summary.get("implausible"):
        lines.append(
            f"  WARNING  {summary['implausible']} samples exceed "
            f"{IMPLAUSIBLE_DRIFT_BP} bp — suspect the decoder or the feed pairing"
        )
    return "\n".join(lines)
