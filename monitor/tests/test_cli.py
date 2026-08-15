"""CLI tests, including the demo used as an end-to-end check in CI."""

from __future__ import annotations

import json
from decimal import ROUND_FLOOR, Decimal

import pytest

from pythmon.cli import DEMO_EXPECTED_AGE_MS, _demo_rows, load_targets, main


def test_demo_rescale_is_exact_decimal_arithmetic():
    """Rescaling exponent -8 to 6 places drops two digits; that part is
    intended. What must not creep in is float error: `int(mantissa * 10 ** -2)`
    evaluates a binary approximation and can land a unit below the true floor,
    and the demo would then report drift it invented itself."""
    ticks, obs = _demo_rows()
    by_ts = {t.ts_us: t for t in ticks}
    for o in obs:
        mantissa = by_ts[o.stated_ts_us].price
        exact = int(Decimal(mantissa).scaleb(-2).to_integral_value(ROUND_FLOOR))
        assert o.price == exact


def test_demo_lag_is_what_the_check_expects():
    ticks, obs = _demo_rows()
    first = obs[0]
    assert (first.observed_us - first.stated_ts_us) / 1_000 == DEMO_EXPECTED_AGE_MS


def test_demo_check_passes(tmp_path, capsys):
    code = main(["--db", str(tmp_path / "demo.sqlite"), "demo", "--check"])
    assert code == 0
    assert "OK:" in capsys.readouterr().out


def test_demo_is_idempotent(tmp_path, capsys):
    """A fixed epoch means repeated runs rewrite the same primary keys rather
    than stacking a fresh copy of the random walk on top."""
    db = str(tmp_path / "demo.sqlite")
    main(["--db", db, "demo", "--check"])
    capsys.readouterr()
    assert main(["--db", db, "demo", "--check"]) == 0
    out = capsys.readouterr().out
    assert "OK:" in out


def test_demo_defaults_to_its_own_database(tmp_path, monkeypatch):
    """The demo writes thousands of synthetic ticks; defaulting them into the
    capture database would contaminate every later report."""
    monkeypatch.chdir(tmp_path)
    assert main(["demo", "--check"]) == 0
    assert (tmp_path / "data" / "demo.sqlite").exists()
    assert not (tmp_path / "data" / "monitor.sqlite").exists()


def test_stream_without_a_token_exits_two(tmp_path, monkeypatch, capsys):
    monkeypatch.delenv("PYTH_LAZER_TOKEN", raising=False)
    code = main(["--db", str(tmp_path / "x.sqlite"), "stream"])
    assert code == 2
    assert "PYTH_LAZER_TOKEN" in capsys.readouterr().err


def test_drift_on_an_unknown_feed_exits_two(tmp_path, capsys):
    code = main(
        ["--db", str(tmp_path / "x.sqlite"), "drift", "--source", "s", "--feed", "16"]
    )
    assert code == 2
    assert "no ticks stored" in capsys.readouterr().err


def test_load_targets_resolves_a_decoder(tmp_path):
    spec = [
        {
            "source": "example",
            "address": "addr_test1x",
            "decoder": "pythmon.cli:_load_decoder",
            "pyth_feed_id": 16,
        }
    ]
    path = tmp_path / "targets.json"
    path.write_text(json.dumps(spec), encoding="utf-8")
    targets = load_targets(path)
    assert len(targets) == 1
    assert targets[0].pyth_feed_id == 16
    assert callable(targets[0].decoder)


def test_load_targets_rejects_a_malformed_decoder_reference(tmp_path):
    path = tmp_path / "targets.json"
    path.write_text(
        json.dumps([{"source": "s", "address": "a", "decoder": "nocolon", "pyth_feed_id": 1}]),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="module:function"):
        load_targets(path)


def test_poll_with_a_bad_targets_file_exits_two(tmp_path, capsys):
    code = main(
        ["--db", str(tmp_path / "x.sqlite"), "poll", "--targets", str(tmp_path / "nope.json")]
    )
    assert code == 2
    assert "could not load targets" in capsys.readouterr().err
