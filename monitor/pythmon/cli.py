"""Command line entry points.

    python -m pythmon demo --check           # end-to-end, synthetic, no key
    python -m pythmon stream --feeds 16,1    # needs PYTH_LAZER_TOKEN
    python -m pythmon poll --targets t.json  # needs decoders; see docs
    python -m pythmon drift --source X --feed 16
"""

from __future__ import annotations

import argparse
import asyncio
import importlib
import json
import logging
import os
import random
import sys
from pathlib import Path

from .chain import ChainPoller, KoiosProvider, Target
from .drift import DEFAULT_MAX_LOOKBACK_MS, compute, format_report, summarize
from .store import ChainObs, Store, Tick

log = logging.getLogger(__name__)

# --------------------------------------------------------------------- stream


def cmd_stream(args) -> int:
    from .stream import DEFAULT_ENDPOINTS, PythAuthError, PythProStream, StreamConfig

    token = os.environ.get("PYTH_LAZER_TOKEN")
    if not token:
        print("PYTH_LAZER_TOKEN is not set", file=sys.stderr)
        return 2

    endpoints = (
        tuple(x.strip() for x in args.endpoints.split(",") if x.strip())
        if args.endpoints
        else DEFAULT_ENDPOINTS
    )
    cfg = StreamConfig(
        token=token,
        feed_ids=[int(x) for x in args.feeds.split(",")],
        channel=args.channel,
        endpoints=endpoints,
    )

    with Store(args.db) as store:
        client = PythProStream(cfg, store)
        try:
            asyncio.run(client.run())
        except KeyboardInterrupt:
            pass
        except PythAuthError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        finally:
            # run() flushes on the way out; this reports what landed.
            print(f"wrote {client.written} ticks; store now holds {store.counts()}")
    return 0


# ----------------------------------------------------------------------- poll


def _load_decoder(spec: str):
    """Resolve a "package.module:function" decoder reference."""
    if ":" not in spec:
        raise ValueError(f"decoder {spec!r} must be written as 'module:function'")
    module_name, _, attr = spec.partition(":")
    return getattr(importlib.import_module(module_name), attr)


def load_targets(path: str | Path) -> list[Target]:
    """Read watch targets from JSON.

    No protocol decoders ship with this package — each one is a guess about
    somebody else's datum encoding and belongs next to evidence that it is
    right. See docs/MONITORING.md.
    """
    entries = json.loads(Path(path).read_text(encoding="utf-8"))
    return [
        Target(
            source=entry["source"],
            address=entry["address"],
            decoder=_load_decoder(entry["decoder"]),
            pyth_feed_id=int(entry["pyth_feed_id"]),
        )
        for entry in entries
    ]


def cmd_poll(args) -> int:
    try:
        targets = load_targets(args.targets)
    except (OSError, ValueError, KeyError, ImportError, AttributeError) as exc:
        print(f"could not load targets: {exc}", file=sys.stderr)
        return 2
    if not targets:
        print(f"{args.targets} lists no targets", file=sys.stderr)
        return 2

    with Store(args.db) as store, KoiosProvider(base_url=args.koios) as provider:
        poller = ChainPoller(provider, targets, store)
        log.info("polling %d target(s) every %.1fs", len(targets), args.interval)
        try:
            if args.once:
                print(f"wrote {poller.poll_once()} observations")
            else:
                poller.poll_forever(
                    args.interval,
                    on_tick=lambda n: log.info("wrote %d observations", n),
                )
        except KeyboardInterrupt:
            pass
        finally:
            print(store.counts())
    return 0


# ---------------------------------------------------------------------- drift


def cmd_drift(args) -> int:
    with Store(args.db) as store:
        try:
            result = compute(
                store,
                args.source,
                args.feed,
                channel=args.channel,
                max_lookback_ms=args.max_lookback_ms,
            )
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        print(format_report(args.source, summarize(result)))
    return 0


# ----------------------------------------------------------------------- demo

# A fixed epoch rather than the current time, so repeated runs write the same
# primary keys and the demo is idempotent instead of accumulating a new copy of
# itself every invocation.
DEMO_EPOCH_US = 1_760_000_000_000_000
DEMO_TICKS = 3_000
DEMO_PERIOD_US = 200_000
DEMO_TRANSPORT_US = 3_000
DEMO_LAG_TICKS = 40
DEMO_FEED_ID = 16
DEMO_CHANNEL = "demo@200ms"
DEMO_SOURCE = "demo-oracle"

#: 40 ticks x 200 ms of deliberate staleness, plus the 3 ms it took us to
#: receive the tick we compare against.
DEMO_EXPECTED_AGE_MS = (
    DEMO_LAG_TICKS * DEMO_PERIOD_US + DEMO_TRANSPORT_US
) / 1_000


def _demo_rows() -> tuple[list[Tick], list[ChainObs]]:
    rng = random.Random(7)
    price = 42_000_000
    ticks: list[Tick] = []
    for i in range(DEMO_TICKS):
        price += rng.randint(-6_000, 6_000)
        ts_us = DEMO_EPOCH_US + i * DEMO_PERIOD_US
        ticks.append(
            Tick(
                feed_id=DEMO_FEED_ID,
                ts_us=ts_us,
                channel=DEMO_CHANNEL,
                recv_ns=i,
                recv_wall_us=ts_us + DEMO_TRANSPORT_US,
                price=price,
                exponent=-8,
                confidence=abs(rng.randint(0, 20_000)),
                best_bid=price - 5_000,
                best_ask=price + 5_000,
                publishers=28,
                generated_us=ts_us,
            )
        )

    obs: list[ChainObs] = []
    for i in range(DEMO_LAG_TICKS, DEMO_TICKS, 25):
        stale = ticks[i - DEMO_LAG_TICKS]
        # Exact integer rescale from exponent -8 to 6 decimal places. Writing
        # this as `int(mantissa * 10 ** -2)` introduces binary rounding into a
        # value that is exactly divisible, and can land a unit low.
        assert stale.price is not None
        obs.append(
            ChainObs(
                source=DEMO_SOURCE,
                utxo_ref=f"demo{i:05d}#0",
                observed_us=ticks[i].recv_wall_us,
                address="addr_test1demo",
                price=stale.price // 100,
                decimals=6,
                stated_ts_us=stale.ts_us,
                block_time_s=stale.ts_us // 1_000_000,
                raw_datum=None,
            )
        )
    return ticks, obs


def cmd_demo(args) -> int:
    """Exercise the whole pipeline without a Pyth key.

    Generates a random-walk price at 200 ms, then samples it into `chain_obs`
    with a deliberate lag, so the reported age comes back as that lag. It
    exists so the join and the statistics can be checked independently of a
    live subscription — with `--check`, it is a test rather than a
    demonstration, which is how CI runs it.
    """
    ticks, obs = _demo_rows()
    # Written under a synthetic channel and, by default, a separate file, so a
    # demo run can never be mistaken for captured data.
    with Store(args.db) as store:
        store.write_ticks(ticks)
        store.write_chain_obs(obs)
        print(store.counts())

        result = compute(store, DEMO_SOURCE, DEMO_FEED_ID, channel=DEMO_CHANNEL)
        summary = summarize(result)
        print(format_report(DEMO_SOURCE, summary))

        if not args.check:
            return 0

        failures = []
        if summary["n"] != len(obs):
            failures.append(f"matched {summary['n']} of {len(obs)} observations")
        if summary["unmatched"] != 0:
            failures.append(f"{summary['unmatched']} observations went unmatched")
        age = summary.get("observed_age_ms", {}).get("median")
        if age != DEMO_EXPECTED_AGE_MS:
            failures.append(f"median age {age} ms, expected {DEMO_EXPECTED_AGE_MS}")
        # Every observation is compared against the tick we had just received,
        # so our own reference is never stale in the demo.
        if summary["match_age_ms"]["max"] != 0:
            failures.append(
                f"match age reached {summary['match_age_ms']['max']} ms, expected 0"
            )
        # An 8 s lag on a random walk has to show up as *some* drift; a zero
        # here would mean the join silently compared a price against itself.
        if summary["drift_bp"]["median"] <= 0:
            failures.append("median |drift| is zero — the join is not doing anything")

        if failures:
            for line in failures:
                print(f"FAIL: {line}", file=sys.stderr)
            return 1
        print("OK: pipeline reproduces the injected lag exactly")
    return 0


# ----------------------------------------------------------------------- main


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="pythmon")
    parser.add_argument(
        "--db",
        default=None,
        help="database path (default: data/monitor.sqlite, data/demo.sqlite for demo)",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="log at DEBUG instead of INFO"
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("stream", help="log Pyth Pro updates")
    s.add_argument("--feeds", default="16", help="comma-separated feed ids")
    s.add_argument("--channel", default="fixed_rate@200ms")
    s.add_argument("--endpoints", default=None, help="comma-separated override")
    s.set_defaults(func=cmd_stream)

    p = sub.add_parser("poll", help="record on-chain prices")
    p.add_argument("--targets", required=True, help="JSON file describing targets")
    p.add_argument("--interval", type=float, default=20.0, help="seconds between polls")
    p.add_argument("--once", action="store_true", help="poll a single time and exit")
    p.add_argument("--koios", default="https://api.koios.rest/api/v1")
    p.set_defaults(func=cmd_poll)

    d = sub.add_parser("drift", help="report drift for one source")
    d.add_argument("--source", required=True)
    d.add_argument("--feed", type=int, required=True)
    d.add_argument("--channel", default=None)
    d.add_argument("--max-lookback-ms", type=int, default=DEFAULT_MAX_LOOKBACK_MS)
    d.set_defaults(func=cmd_drift)

    m = sub.add_parser("demo", help="run the pipeline on synthetic data")
    m.add_argument(
        "--check",
        action="store_true",
        help="assert the pipeline reproduces the injected lag; non-zero exit if not",
    )
    m.set_defaults(func=cmd_demo)

    args = parser.parse_args(argv)
    if args.db is None:
        # The demo writes thousands of synthetic ticks. Defaulting it into the
        # same file as real captures would contaminate every later report with
        # a random walk, and nothing downstream could tell the two apart.
        args.db = "data/demo.sqlite" if args.cmd == "demo" else "data/monitor.sqlite"
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
