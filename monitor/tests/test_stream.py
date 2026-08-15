"""Stream tests: parsing robustness and the flush path.

No socket is opened here. What is tested is the part that mangles or loses
data — message parsing, and the buffer.
"""

from __future__ import annotations

import json

from pythmon.store import Store
from pythmon.stream import (
    DEFAULT_ENDPOINTS,
    DEFAULT_PROPERTIES,
    PythProStream,
    StreamConfig,
    parse_stream_update,
    subscribe_message,
)


def message(**over) -> dict:
    feed = {
        "priceFeedId": 16,
        "price": "42000000",
        "exponent": -8,
        "confidence": 1000,
        "publisherCount": 28,
    }
    feed.update(over.pop("feed", {}))
    parsed = {"timestampUs": str(1_760_000_000_000_000), "priceFeeds": [feed]}
    parsed.update(over.pop("parsed", {}))
    return {"type": "streamUpdated", "parsed": parsed}


def test_parses_a_normal_update():
    ticks = parse_stream_update(message(), "ch", 1, 2)
    assert len(ticks) == 1
    assert ticks[0].feed_id == 16
    assert ticks[0].price == 42_000_000
    assert ticks[0].exponent == -8
    assert ticks[0].channel == "ch"


def test_string_encoded_integers_are_accepted():
    """Pyth sends 64-bit values; some encoders emit them as JSON strings."""
    ticks = parse_stream_update(message(feed={"price": "123"}), "ch", 1, 2)
    assert ticks[0].price == 123


def test_a_quiet_feed_is_still_recorded():
    """Knowing the feed went quiet is itself an observation."""
    ticks = parse_stream_update(message(feed={"price": None}), "ch", 1, 2)
    assert len(ticks) == 1
    assert ticks[0].price is None


def test_one_unparseable_property_does_not_lose_the_feed():
    ticks = parse_stream_update(message(feed={"confidence": "not-a-number"}), "ch", 1, 2)
    assert len(ticks) == 1
    assert ticks[0].confidence is None
    assert ticks[0].price == 42_000_000


def test_a_feed_with_no_id_is_skipped_not_fatal():
    """There is nothing to record it against, but the rest of the batch is
    still good data."""
    msg = message()
    msg["parsed"]["priceFeeds"].append({"price": 1})
    ticks = parse_stream_update(msg, "ch", 1, 2)
    assert [t.feed_id for t in ticks] == [16]


def test_a_message_with_no_timestamp_yields_nothing():
    msg = message()
    del msg["parsed"]["timestampUs"]
    assert parse_stream_update(msg, "ch", 1, 2) == []


def test_missing_price_feeds_key_is_survivable():
    assert parse_stream_update({"parsed": {"timestampUs": 1}}, "ch", 1, 2) == []


def test_subscribe_message_carries_the_documented_fields():
    cfg = StreamConfig(token="t", feed_ids=[16, 1])
    body = json.loads(subscribe_message(cfg))
    assert body["type"] == "subscribe"
    assert body["priceFeedIds"] == [16, 1]
    assert body["deliveryFormat"] == "json"
    assert body["channel"] == "fixed_rate@200ms"


def test_generation_timestamp_is_subscribed_by_default():
    """The on-chain guard measures freshness against feedUpdateTimestamp and
    fails closed without it, so a monitor that never requests the property
    would be recording something the guard cannot use."""
    assert "feedUpdateTimestamp" in DEFAULT_PROPERTIES


def test_every_documented_endpoint_is_used():
    """The client's whole reason for holding several connections is that any
    one of them drops during a deployment."""
    assert len(DEFAULT_ENDPOINTS) == 3


def test_flush_persists_buffered_ticks(tmp_path):
    with Store(tmp_path / "s.sqlite") as store:
        client = PythProStream(StreamConfig(token="t", feed_ids=[16]), store)
        client._handle(json.dumps(message()), 1, 2)
        # Below the volume threshold, so nothing has been written yet.
        assert store.counts()["pyth_ticks"] == 0
        assert client.flush() == 1
        assert store.counts()["pyth_ticks"] == 1


def test_flush_is_idempotent_on_an_empty_buffer(tmp_path):
    with Store(tmp_path / "s.sqlite") as store:
        client = PythProStream(StreamConfig(token="t", feed_ids=[16]), store)
        assert client.flush() == 0
        assert client.flush() == 0


def test_volume_threshold_writes_without_an_explicit_flush(tmp_path):
    with Store(tmp_path / "s.sqlite") as store:
        cfg = StreamConfig(token="t", feed_ids=[16], flush_every=2)
        client = PythProStream(cfg, store)
        for i in range(2):
            msg = message()
            msg["parsed"]["timestampUs"] = str(1_760_000_000_000_000 + i)
            client._handle(json.dumps(msg), 1, 2)
        assert store.counts()["pyth_ticks"] == 2


def test_non_stream_messages_are_not_buffered(tmp_path):
    with Store(tmp_path / "s.sqlite") as store:
        client = PythProStream(StreamConfig(token="t", feed_ids=[16]), store)
        client._handle(json.dumps({"type": "subscribed", "subscriptionId": 1}), 1, 2)
        client._handle(json.dumps({"type": "error", "error": "nope"}), 1, 2)
        client._handle("not json at all", 1, 2)
        client._handle(b"\x00binary", 1, 2)
        assert client.flush() == 0
