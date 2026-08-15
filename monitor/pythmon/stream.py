"""Pyth Pro (Lazer) websocket client.

Logs every price update to the store, with local receipt timestamps alongside
Pyth's publish timestamps. That pair is the whole point: the difference between
them is your own transport latency, and you cannot measure anyone else's
staleness without first knowing your own.

Pyth publishes three stream endpoints and advises holding connections to all of
them, because any single one drops briefly during deployments. This client does
that, and deduplicates on write via the primary key, so the redundancy costs
bandwidth and nothing else.

Buffered ticks are flushed on a timer as well as on volume, and again on the
way out. A monitor that loses its last few hundred samples every time it is
restarted quietly biases exactly the periods you restarted during.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time
from collections.abc import Sequence
from dataclasses import dataclass, field

import websockets
from websockets.exceptions import InvalidStatus

from .store import Store, Tick, now_us

log = logging.getLogger(__name__)

DEFAULT_ENDPOINTS = (
    "wss://pyth-lazer-0.dourolabs.app/v1/stream",
    "wss://pyth-lazer-1.dourolabs.app/v1/stream",
    "wss://pyth-lazer-2.dourolabs.app/v1/stream",
)

# Properties worth asking for. bestBidPrice, bestAskPrice and publisherCount do
# not exist on the free Core feeds, and they are half the reason to hold a Pro
# key at all, so request them explicitly.
#
# feedUpdateTimestamp is not optional in practice. It is when the price was
# *generated*, as opposed to when the message carrying it was produced, and the
# two diverge exactly when a feed is being carried forward. The on-chain guard
# measures staleness against it and refuses a feed that lacks it, so a
# subscription without it records prices no guarded contract can consume.
DEFAULT_PROPERTIES = (
    "price",
    "bestBidPrice",
    "bestAskPrice",
    "confidence",
    "publisherCount",
    "exponent",
    "feedUpdateTimestamp",
)


class PythAuthError(RuntimeError):
    """The server rejected our credentials. Retrying will not help."""


@dataclass(slots=True)
class StreamConfig:
    token: str
    feed_ids: list[int]
    channel: str = "fixed_rate@200ms"
    properties: tuple[str, ...] = DEFAULT_PROPERTIES
    endpoints: tuple[str, ...] = DEFAULT_ENDPOINTS
    flush_every: int = 200
    flush_seconds: float = 2.0
    max_backoff_seconds: float = 30.0
    stats: dict[str, int] = field(default_factory=dict)


def subscribe_message(cfg: StreamConfig, subscription_id: int = 1) -> str:
    return json.dumps(
        {
            "type": "subscribe",
            "subscriptionId": subscription_id,
            "priceFeedIds": cfg.feed_ids,
            "properties": list(cfg.properties),
            "formats": [],
            "deliveryFormat": "json",
            "channel": cfg.channel,
            "jsonBinaryEncoding": "hex",
        }
    )


def _as_int(value: object) -> int | None:
    """Coerce a JSON number to int, tolerating strings and rejecting junk.

    Pyth sends large integers; some encoders emit them as strings. A feed with
    one unparseable property should lose that property, not the whole batch.
    """
    if value is None:
        return None
    try:
        if isinstance(value, str):
            return int(value, 10)
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_stream_update(
    msg: dict, channel: str, recv_ns: int, recv_wall_us: int
) -> list[Tick]:
    """Turn one streamUpdated message into Tick rows.

    Absent properties come back missing rather than null, so every field is
    fetched defensively. A feed that arrives without a price is still recorded:
    knowing the feed went quiet is itself an observation. A feed with no
    identifier is not recorded, because there is nothing to record it against.
    """
    parsed = msg.get("parsed") or {}
    ts_us = _as_int(parsed.get("timestampUs"))
    if ts_us is None:
        return []

    out: list[Tick] = []
    for feed in parsed.get("priceFeeds") or []:
        if not isinstance(feed, dict):
            continue
        feed_id = _as_int(feed.get("priceFeedId"))
        if feed_id is None:
            log.warning("dropping feed entry with no priceFeedId: %r", feed)
            continue
        out.append(
            Tick(
                feed_id=feed_id,
                ts_us=ts_us,
                channel=channel,
                recv_ns=recv_ns,
                recv_wall_us=recv_wall_us,
                price=_as_int(feed.get("price")),
                exponent=_as_int(feed.get("exponent")),
                confidence=_as_int(feed.get("confidence")),
                best_bid=_as_int(feed.get("bestBidPrice")),
                best_ask=_as_int(feed.get("bestAskPrice")),
                publishers=_as_int(feed.get("publisherCount")),
                generated_us=_as_int(feed.get("feedUpdateTimestamp")),
            )
        )
    return out


class PythProStream:
    def __init__(self, cfg: StreamConfig, store: Store):
        self.cfg = cfg
        self.store = store
        self._buf: list[Tick] = []
        self._last_flush = time.monotonic()
        self.written = 0

    async def run(self) -> None:
        """Hold every endpoint open until cancelled, flushing as we go.

        The buffer is flushed in `finally` so that Ctrl-C, a cancelled task and
        an unhandled error all persist what has already been received.
        """
        tasks = [
            asyncio.create_task(self._run_endpoint(url), name=f"stream:{url}")
            for url in self.cfg.endpoints
        ]
        tasks.append(asyncio.create_task(self._flush_loop(), name="flush"))
        try:
            # If one endpoint raises a non-retryable error (bad token), stop
            # rather than leaving the others spinning against the same key.
            done, pending = await asyncio.wait(
                tasks, return_when=asyncio.FIRST_EXCEPTION
            )
            for task in done:
                task.result()
        finally:
            for task in tasks:
                task.cancel()
            for task in tasks:
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await task
            self.flush()

    async def _flush_loop(self) -> None:
        """Flush on a timer as well as on volume.

        Without this a quiet feed leaves rows in memory indefinitely: the
        volume trigger only fires when a message arrives, and so does the
        elapsed-time check that rides along with it.
        """
        while True:
            await asyncio.sleep(self.cfg.flush_seconds)
            self.flush()

    async def _run_endpoint(self, url: str) -> None:
        backoff = 1.0
        while True:
            try:
                async with websockets.connect(
                    url,
                    additional_headers={"Authorization": f"Bearer {self.cfg.token}"},
                    ping_interval=20,
                    max_queue=4096,
                ) as ws:
                    await ws.send(subscribe_message(self.cfg))
                    log.info("subscribed on %s", url)
                    backoff = 1.0
                    async for raw in ws:
                        self._handle(raw, time.monotonic_ns(), now_us())
            except InvalidStatus as exc:
                status = getattr(getattr(exc, "response", None), "status_code", None)
                if status in (401, 403):
                    # Retrying a rejected credential just produces an infinite
                    # loop of identical failures with no visible cause.
                    raise PythAuthError(
                        f"{url} rejected the token (HTTP {status}); "
                        "check PYTH_LAZER_TOKEN"
                    ) from exc
                log.warning("%s returned HTTP %s (retry in %.1fs)", url, status, backoff)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, self.cfg.max_backoff_seconds)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 — reconnect on anything transient
                log.warning(
                    "stream %s dropped: %r (retry in %.1fs)", url, exc, backoff
                )
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, self.cfg.max_backoff_seconds)

    def _handle(self, raw: str | bytes, recv_ns: int, recv_wall_us: int) -> None:
        if isinstance(raw, bytes):
            return  # binary payloads are for on-chain submission, not logging
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            log.debug("dropping non-JSON frame")
            return
        if not isinstance(msg, dict):
            return

        kind = msg.get("type")
        if kind == "subscribed":
            log.info("subscription %s confirmed", msg.get("subscriptionId"))
            return
        if kind in ("error", "subscriptionError"):
            # Surfaced rather than ignored: a rejected subscription otherwise
            # looks exactly like a feed that never ticks.
            log.error("server error: %s", msg)
            return
        if kind != "streamUpdated":
            return

        self._buf.extend(
            parse_stream_update(msg, self.cfg.channel, recv_ns, recv_wall_us)
        )
        if len(self._buf) >= self.cfg.flush_every:
            self.flush()

    def flush(self) -> int:
        if not self._buf:
            return 0
        batch, self._buf = self._buf, []
        written = self.store.write_ticks(batch)
        self.written += written
        if written != len(batch):
            # Expected: the same tick arrives on all three endpoints and the
            # primary key discards the duplicates. Logged at debug so that an
            # unexpected ratio is still discoverable.
            log.debug("wrote %d of %d buffered ticks", written, len(batch))
        self._last_flush = time.monotonic()
        return written


async def stream_forever(
    token: str,
    feed_ids: Sequence[int],
    store: Store,
    channel: str = "fixed_rate@200ms",
    endpoints: tuple[str, ...] = DEFAULT_ENDPOINTS,
) -> PythProStream:
    cfg = StreamConfig(
        token=token, feed_ids=list(feed_ids), channel=channel, endpoints=endpoints
    )
    client = PythProStream(cfg, store)
    await client.run()
    return client
