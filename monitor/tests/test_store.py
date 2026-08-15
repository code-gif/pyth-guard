"""Store tests, concentrating on the ways rows go missing without saying so."""

from __future__ import annotations

import sqlite3
from dataclasses import fields

import pytest

from pythmon.store import ChainObs, Store, Tick, _insert_sql


def tick(**over) -> Tick:
    base = dict(
        feed_id=16,
        ts_us=1_000_000,
        channel="fixed_rate@200ms",
        recv_ns=1,
        recv_wall_us=1_003_000,
        price=42_000_000,
        exponent=-8,
        confidence=1_000,
        best_bid=None,
        best_ask=None,
        publishers=28,
    )
    base.update(over)
    return Tick(**base)


def obs(**over) -> ChainObs:
    base = dict(
        source="s",
        utxo_ref="abc#0",
        observed_us=1_000_000,
        address="addr",
        price=420_000,
        decimals=6,
        stated_ts_us=999_000,
        block_time_s=None,
        raw_datum=None,
    )
    base.update(over)
    return ChainObs(**base)


@pytest.fixture
def store(tmp_path):
    with Store(tmp_path / "t.sqlite") as s:
        yield s


def test_insert_names_every_column_in_dataclass_order():
    """A positional INSERT binds by position, so a reordered field silently
    writes each value into its neighbour's column. Naming them makes that a
    loud error instead of corrupt data."""
    for cls, table in ((Tick, "pyth_ticks"), (ChainObs, "chain_obs")):
        sql = _insert_sql(table, cls)
        for f in fields(cls):
            assert f.name in sql
        assert sql.count("?") == len(fields(cls))


def test_write_counts_are_real_inserts_not_input_length(store):
    """`INSERT OR IGNORE` swallows duplicates, so returning len(rows) would
    report success for rows the database discarded."""
    assert store.write_ticks([tick()]) == 1
    assert store.write_ticks([tick()]) == 0
    assert store.counts()["pyth_ticks"] == 1


def test_same_timestamp_on_two_channels_is_two_rows(store):
    """Channel is part of a tick's identity: the same feed at the same instant
    on two channels is two observations, not a duplicate."""
    store.write_ticks([tick(channel="a"), tick(channel="b")])
    assert store.counts()["pyth_ticks"] == 2


def test_two_outputs_of_one_transaction_both_survive(store):
    """A UTxO is identified by tx_hash#index. Keying on the transaction alone
    would silently drop every output after the first."""
    store.write_chain_obs([obs(utxo_ref="tx#0"), obs(utxo_ref="tx#1")])
    assert store.counts()["chain_obs"] == 2


def test_repeated_observation_of_one_utxo_is_a_new_sample(store):
    """The same unchanged UTxO seen at two different times is two drift
    samples, not one."""
    store.write_chain_obs([obs(observed_us=1), obs(observed_us=2)])
    assert store.counts()["chain_obs"] == 2


def test_chain_obs_primary_key_columns_are_all_non_null(store):
    """A NULL in a WITHOUT ROWID primary key is rejected, and `INSERT OR
    IGNORE` turns that rejection into a silent no-op. The schema must
    therefore keep every key column NOT NULL, and the writer must never be
    able to supply None for one."""
    info = store.db.execute("PRAGMA table_info(chain_obs)").fetchall()
    key_columns = {row[1] for row in info if row[5]}
    assert key_columns == {"source", "utxo_ref", "observed_us"}
    for row in info:
        if row[1] in key_columns:
            assert row[3] == 1, f"{row[1]} must be NOT NULL"


_RAW_OBS_INSERT = (
    "INTO chain_obs "
    "(source, utxo_ref, observed_us, address, price, decimals, "
    " stated_ts_us, block_time_s, raw_datum) "
    "VALUES (?,?,?,?,?,?,?,?,?)"
)
_NULL_KEY_ROW = ("s", None, 1, "addr", 1, 6, None, None, None)


def test_insert_or_ignore_swallows_a_null_key_without_a_word(store):
    """This is the hazard, demonstrated rather than described.

    A NULL in a WITHOUT ROWID primary key is a constraint violation. The
    writer uses `INSERT OR IGNORE` so that re-receiving a tick is cheap — and
    that same clause turns the violation into a silent no-op. The row does not
    arrive, nothing raises, and a naive writer returning `len(rows)` would
    report it as written.

    Nothing in the schema can prevent this; only never producing such a row
    can. `chain.py` skips UTxOs with no tx_hash, and `utxo_ref` is built by
    interpolation so it cannot be None.
    """
    before = store.counts()["chain_obs"]
    store.db.execute(f"INSERT OR IGNORE {_RAW_OBS_INSERT}", _NULL_KEY_ROW)
    assert store.counts()["chain_obs"] == before

    # Without OR IGNORE the same row is loudly rejected, which is the proof
    # that the silence above is the clause's doing and not a schema accident.
    with pytest.raises(sqlite3.IntegrityError):
        store.db.execute(f"INSERT {_RAW_OBS_INSERT}", _NULL_KEY_ROW)


def test_nullable_payload_columns_still_accept_none(store):
    """A feed that goes quiet is still an observation worth keeping."""
    assert store.write_ticks([tick(price=None, exponent=None)]) == 1


def test_schema_version_is_recorded(store):
    value = store.db.execute(
        "SELECT value FROM meta WHERE key = 'schema_version'"
    ).fetchone()[0]
    assert int(value) >= 2
