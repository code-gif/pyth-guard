"""Local storage for the drift monitor.

SQLite in WAL mode, single writer, batched inserts. The data survives restarts
and is queryable with plain SQL; nothing here should be clever.

Two tables:

  pyth_ticks     every price update received from Pyth Pro
  chain_obs      every price observed on-chain, from a Cardano oracle consumer

The join between them happens at analysis time, not ingest time, so that a bug
in the drift calculation never costs you the underlying data. For the same
reason ``chain_obs`` keeps the raw datum: a decoder that turns out to be wrong
can be re-run over history instead of invalidating it.

Every tick carries **three** timestamps, and they answer different questions:

  ``generated_us``   when Pyth produced the price
  ``ts_us``          when Pyth produced the message carrying it
  ``recv_wall_us``   when we received that message

The first two diverge whenever a price is carried forward — a quiet feed, a
closed market — and that divergence is the staleness question, not a detail.
The last two are the width of our own transport, and you cannot measure how
stale somebody else's price is without first knowing how long yours took to
arrive. ``drift.py`` joins on the local clock for exactly that reason: mixing
Pyth's clock with ours would fold our skew into the answer invisibly.
"""

from __future__ import annotations

import sqlite3
import time
from collections.abc import Iterable
from dataclasses import astuple, dataclass, fields
from pathlib import Path

SCHEMA_VERSION = 3

SCHEMA = """
CREATE TABLE IF NOT EXISTS pyth_ticks (
    feed_id        INTEGER NOT NULL,
    ts_us          INTEGER NOT NULL,   -- publish time, as signed by Pyth
    channel        TEXT    NOT NULL,   -- delivery channel the tick arrived on
    recv_ns        INTEGER NOT NULL,   -- local monotonic receipt time
    recv_wall_us   INTEGER NOT NULL,   -- local wall clock at receipt
    price          INTEGER,            -- mantissa; value = price * 10^exponent
    exponent       INTEGER,
    confidence     INTEGER,
    best_bid       INTEGER,
    best_ask       INTEGER,
    publishers     INTEGER,
    generated_us   INTEGER,            -- when the PRICE was generated
    PRIMARY KEY (feed_id, channel, ts_us)
) WITHOUT ROWID;

-- drift.py matches on the LOCAL clock, so that is the index it needs.
CREATE INDEX IF NOT EXISTS ix_ticks_recv
    ON pyth_ticks (feed_id, channel, recv_wall_us);

CREATE TABLE IF NOT EXISTS chain_obs (
    source         TEXT    NOT NULL,   -- label for the protocol/feed watched
    utxo_ref       TEXT    NOT NULL,   -- "<tx_hash>#<index>", the natural key
    observed_us    INTEGER NOT NULL,   -- local wall clock when we saw it
    address        TEXT    NOT NULL,
    price          INTEGER,            -- rescaled to `decimals`
    decimals       INTEGER NOT NULL,
    stated_ts_us   INTEGER,            -- timestamp the datum claims, if any
    block_time_s   INTEGER,            -- on-chain time, if the provider gives it
    raw_datum      TEXT,               -- kept so a decoder fix can be replayed
    PRIMARY KEY (source, utxo_ref, observed_us)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS ix_obs_source_ts ON chain_obs (source, observed_us);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


@dataclass(slots=True)
class Tick:
    """One feed's values from one Pyth update.

    Field order is not load-bearing: inserts name their columns explicitly.
    """

    feed_id: int
    ts_us: int
    channel: str
    recv_ns: int
    recv_wall_us: int
    price: int | None
    exponent: int | None
    confidence: int | None
    best_bid: int | None
    best_ask: int | None
    publishers: int | None
    #: When the price was *generated*, as opposed to ``ts_us``, when the
    #: message carrying it was produced. They diverge when Pyth carries a
    #: price forward, and that divergence is the whole staleness question —
    #: the on-chain guard measures age against this one.
    generated_us: int | None = None


@dataclass(slots=True)
class ChainObs:
    """One on-chain price, as it looked at one moment."""

    source: str
    utxo_ref: str
    observed_us: int
    address: str
    price: int | None
    decimals: int
    stated_ts_us: int | None
    block_time_s: int | None
    raw_datum: str | None


def _insert_sql(table: str, cls: type) -> str:
    """Build an INSERT that names its columns.

    A positional ``INSERT INTO t VALUES (?,?,...)`` fed from a dataclass binds
    by position, so adding or reordering a field silently writes every value
    into the wrong column. Naming them means a mismatch is an error instead.
    """
    names = [f.name for f in fields(cls)]
    placeholders = ",".join("?" * len(names))
    return f"INSERT OR IGNORE INTO {table} ({','.join(names)}) VALUES ({placeholders})"


_INSERT_TICK = _insert_sql("pyth_ticks", Tick)
_INSERT_OBS = _insert_sql("chain_obs", ChainObs)


class Store:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.path, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.executescript(SCHEMA)
        self.db.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?)",
            (str(SCHEMA_VERSION),),
        )

    def __enter__(self) -> Store:
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    def write_ticks(self, ticks: Iterable[Tick]) -> int:
        return self._insert(_INSERT_TICK, [astuple(t) for t in ticks])

    def write_chain_obs(self, obs: Iterable[ChainObs]) -> int:
        return self._insert(_INSERT_OBS, [astuple(o) for o in obs])

    def _insert(self, sql: str, rows: list[tuple]) -> int:
        """Insert and return the number of rows that were *actually* written.

        ``INSERT OR IGNORE`` swallows constraint violations as well as
        duplicates, so returning ``len(rows)`` would report success for rows
        the database rejected. ``total_changes`` counts what really landed.
        """
        if not rows:
            return 0
        before = self.db.total_changes
        self.db.executemany(sql, rows)
        return self.db.total_changes - before

    def counts(self) -> dict[str, int]:
        ticks = self.db.execute("SELECT COUNT(*) FROM pyth_ticks").fetchone()[0]
        obs = self.db.execute("SELECT COUNT(*) FROM chain_obs").fetchone()[0]
        return {"pyth_ticks": ticks, "chain_obs": obs}

    def sources(self) -> list[str]:
        cur = self.db.execute("SELECT DISTINCT source FROM chain_obs ORDER BY source")
        return [row[0] for row in cur]

    def close(self) -> None:
        self.db.close()


def now_us() -> int:
    return int(time.time() * 1_000_000)
