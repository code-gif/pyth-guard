"""Drift tests: the join, the clocks, and the arithmetic."""

from __future__ import annotations

from decimal import Decimal

import pytest

from pythmon.drift import (
    IMPLAUSIBLE_DRIFT_BP,
    compute,
    format_report,
    percentile,
    resolve_channel,
    summarize,
)
from pythmon.store import ChainObs, Store, Tick

CH = "fixed_rate@200ms"
T0 = 1_760_000_000_000_000


@pytest.fixture
def store(tmp_path):
    with Store(tmp_path / "d.sqlite") as s:
        yield s


def put_tick(store, *, ts_us, recv_wall_us, price, exponent=-8, channel=CH, feed=16):
    store.write_ticks(
        [
            Tick(
                feed_id=feed,
                ts_us=ts_us,
                channel=channel,
                recv_ns=0,
                recv_wall_us=recv_wall_us,
                price=price,
                exponent=exponent,
                confidence=0,
                best_bid=None,
                best_ask=None,
                publishers=1,
            )
        ]
    )


def put_obs(store, *, observed_us, price, decimals=6, stated_ts_us=None, ref="u#0"):
    store.write_chain_obs(
        [
            ChainObs(
                source="src",
                utxo_ref=ref,
                observed_us=observed_us,
                address="addr",
                price=price,
                decimals=decimals,
                stated_ts_us=stated_ts_us,
                block_time_s=None,
                raw_datum=None,
            )
        ]
    )


# ------------------------------------------------------------------ percentile


def test_percentile_matches_type_seven():
    xs = [1.0, 2.0, 3.0, 4.0]
    assert percentile(xs, 0.0) == 1.0
    assert percentile(xs, 1.0) == 4.0
    assert percentile(xs, 0.5) == 2.5


def test_percentile_handles_one_and_two_samples():
    assert percentile([7.0], 0.99) == 7.0
    assert percentile([1.0, 3.0], 0.5) == 2.0


def test_percentile_rejects_empty_input():
    with pytest.raises(ValueError):
        percentile([], 0.5)


# ------------------------------------------------------------------- the join


def test_join_uses_the_local_clock_not_the_publish_clock(store):
    """The chain observation is stamped with our wall clock; a tick's publish
    time comes from Pyth's. Matching one against the other folds our own clock
    skew into every drift figure.

    Here the later-published tick had not been *received* when we sampled the
    chain, so it must not be the reference — even though its publish timestamp
    precedes the observation.
    """
    put_tick(store, ts_us=T0, recv_wall_us=T0 + 1_000, price=100_000_000)
    # Published before we sampled, but delivered afterwards.
    put_tick(store, ts_us=T0 + 500, recv_wall_us=T0 + 9_000, price=200_000_000)
    put_obs(store, observed_us=T0 + 5_000, price=1_000_000)

    result = compute(store, "src", 16, channel=CH)
    assert len(result.rows) == 1
    assert result.rows[0].pyth_price == Decimal("1")


def test_price_and_exponent_come_from_the_same_row(store):
    """Two independent subqueries could take the price from one tick and the
    exponent from another. Different exponents on adjacent ticks would then
    produce a value off by orders of magnitude."""
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=42_000_000, exponent=-8)
    put_tick(store, ts_us=T0 + 1, recv_wall_us=T0 + 1, price=42, exponent=-2)
    put_obs(store, observed_us=T0 + 100, price=420_000)

    row = compute(store, "src", 16, channel=CH).rows[0]
    assert row.pyth_price == Decimal("0.42")
    assert row.drift_bp == pytest.approx(0.0)


def test_lookback_bound_excludes_and_counts_stale_references(store):
    """A tick from an hour before the observation is not an answer to "what
    was the price then". It must not silently become one."""
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=42_000_000)
    put_obs(store, observed_us=T0 + 3_600_000_000, price=420_000)

    result = compute(store, "src", 16, channel=CH, max_lookback_ms=60_000)
    assert result.rows == []
    assert result.unmatched == 1


def test_channel_is_part_of_the_match(store):
    """Channels are different sampling rates of the same feed; the baseline
    must not silently switch between them."""
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=42_000_000, channel="a")
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=84_000_000, channel="b")
    put_obs(store, observed_us=T0 + 10, price=420_000)

    assert compute(store, "src", 16, channel="a").rows[0].pyth_price == Decimal("0.42")
    assert compute(store, "src", 16, channel="b").rows[0].pyth_price == Decimal("0.84")


def test_resolve_channel_refuses_to_guess_between_two(store):
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=1, channel="a")
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=1, channel="b")
    with pytest.raises(ValueError, match="channels"):
        resolve_channel(store, 16)


def test_resolve_channel_picks_the_only_one(store):
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=1, channel="only")
    assert resolve_channel(store, 16) == "only"


def test_missing_reference_price_is_counted_not_discarded(store):
    """"We had no reference" and "the chain agreed with Pyth" must not look
    the same in a report."""
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=None, exponent=None)
    put_obs(store, observed_us=T0 + 10, price=420_000)

    result = compute(store, "src", 16, channel=CH)
    assert result.rows == []
    assert result.no_reference == 1


# ------------------------------------------------------------------ arithmetic


def test_drift_is_exact_for_a_decimal_price(store):
    """Reconstructing 42_000_000e-8 by float multiplication gives
    0.42000000000000004; the error is ~1e-15 relative, and the statistic is
    quoted at 1e-4."""
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=42_000_000, exponent=-8)
    put_obs(store, observed_us=T0 + 10, price=420_000, decimals=6)

    row = compute(store, "src", 16, channel=CH).rows[0]
    assert row.chain_price == Decimal("0.42")
    assert row.pyth_price == Decimal("0.42")
    assert row.drift_bp == 0.0


def test_drift_sign_follows_the_chain_price(store):
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=100_000_000, exponent=-8)
    put_obs(store, observed_us=T0 + 10, price=990_000, decimals=6)

    row = compute(store, "src", 16, channel=CH).rows[0]
    assert row.drift_bp == pytest.approx(-100.0)


def test_signed_median_survives_summarisation(store):
    """A one-sided bias is a different finding from symmetric noise, and
    taking the absolute value before aggregating hides it."""
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=100_000_000, exponent=-8)
    for i in range(5):
        put_obs(store, observed_us=T0 + 10 + i, price=990_000, ref=f"u#{i}")

    summary = summarize(compute(store, "src", 16, channel=CH))
    assert summary["drift_bp"]["median"] == pytest.approx(100.0)
    assert summary["drift_bp"]["signed_median"] == pytest.approx(-100.0)


def test_age_is_measured_from_the_stated_timestamp(store):
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=100_000_000)
    put_obs(store, observed_us=T0 + 8_000_000, price=1_000_000, stated_ts_us=T0)

    row = compute(store, "src", 16, channel=CH).rows[0]
    assert row.observed_age_ms == pytest.approx(8_000.0)


# --------------------------------------------------------------------- report


def test_implausible_drift_is_flagged(store):
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=100_000_000, exponent=-8)
    put_obs(store, observed_us=T0 + 10, price=1, decimals=6)

    summary = summarize(compute(store, "src", 16, channel=CH))
    assert summary["implausible"] == 1
    assert "WARNING" in format_report("src", summary)
    assert str(IMPLAUSIBLE_DRIFT_BP) in format_report("src", summary)


def test_small_samples_disclaim_the_p99(store):
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=100_000_000)
    put_obs(store, observed_us=T0 + 10, price=1_000_000)

    report = format_report("src", summarize(compute(store, "src", 16, channel=CH)))
    assert "p99 is not a tail estimate" in report


def test_empty_report_does_not_crash(store):
    put_tick(store, ts_us=T0, recv_wall_us=T0, price=1)
    summary = summarize(compute(store, "nobody", 16, channel=CH))
    assert summary["n"] == 0
    assert "no overlapping observations" in format_report("nobody", summary)
