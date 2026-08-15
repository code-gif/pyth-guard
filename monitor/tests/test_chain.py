"""Chain poller tests: what happens when a provider or a decoder misbehaves."""

from __future__ import annotations

import pytest

from pythmon.chain import ChainPoller, DecodedPrice, Target, _raw_datum_text
from pythmon.store import Store


class FakeProvider:
    def __init__(self, pages: dict[str, list[dict]]):
        self.pages = pages
        self.calls = 0

    def utxos_at(self, address: str) -> list[dict]:
        self.calls += 1
        result = self.pages[address]
        if isinstance(result, Exception):
            raise result
        return result


def utxo(**over) -> dict:
    base = {
        "tx_hash": "aa" * 32,
        "tx_index": 0,
        "block_time": 1_760_000_000,
        "inline_datum": {"bytes": "d8799f01ff"},
    }
    base.update(over)
    return base


def ok_decoder(_datum) -> DecodedPrice:
    return DecodedPrice(price=420_000, decimals=6, stated_ts_us=1_760_000_000_000_000)


def none_decoder(_datum):
    return None


def boom_decoder(_datum):
    raise ValueError("that is not a price")


@pytest.fixture
def store(tmp_path):
    with Store(tmp_path / "c.sqlite") as s:
        yield s


def target(decoder, address="addr1", source="src") -> Target:
    return Target(source=source, address=address, decoder=decoder, pyth_feed_id=16)


def test_records_a_decoded_utxo(store):
    provider = FakeProvider({"addr1": [utxo()]})
    assert ChainPoller(provider, [target(ok_decoder)], store).poll_once() == 1

    row = store.db.execute(
        "SELECT utxo_ref, price, decimals, block_time_s, raw_datum FROM chain_obs"
    ).fetchone()
    assert row[0] == "aa" * 32 + "#0"
    assert row[1] == 420_000
    assert row[3] == 1_760_000_000
    assert row[4] == "d8799f01ff"


def test_block_time_and_observation_time_are_separate_columns(store):
    """`observed_us` is when we polled; `block_time_s` is when the price
    landed. Folding one into the other would overstate somebody else's
    staleness by up to a full poll interval."""
    provider = FakeProvider({"addr1": [utxo()]})
    ChainPoller(provider, [target(ok_decoder)], store).poll_once()
    observed_us, block_time_s = store.db.execute(
        "SELECT observed_us, block_time_s FROM chain_obs"
    ).fetchone()
    assert block_time_s == 1_760_000_000
    assert observed_us != block_time_s


def test_two_outputs_of_one_transaction_are_distinct_observations(store):
    provider = FakeProvider({"addr1": [utxo(tx_index=0), utxo(tx_index=1)]})
    assert ChainPoller(provider, [target(ok_decoder)], store).poll_once() == 2


def test_utxo_without_a_tx_hash_is_skipped_not_written_as_null(store):
    """A None key would be swallowed by INSERT OR IGNORE and vanish silently,
    so it must never reach the writer."""
    provider = FakeProvider({"addr1": [utxo(tx_hash=None), utxo()]})
    assert ChainPoller(provider, [target(ok_decoder)], store).poll_once() == 1


def test_a_decoder_raising_does_not_discard_the_rest(store):
    """A decoder is a guess about someone else's encoding, and script
    addresses hold unrelated UTxOs. One exception must not take down every row
    already accumulated."""
    good = target(ok_decoder, address="addr1", source="good")
    bad = target(boom_decoder, address="addr2", source="bad")
    provider = FakeProvider({"addr1": [utxo()], "addr2": [utxo()]})
    assert ChainPoller(provider, [good, bad], store).poll_once() == 1


def test_a_provider_failing_does_not_stop_other_targets(store):
    good = target(ok_decoder, address="addr1", source="good")
    dead = target(ok_decoder, address="addr2", source="dead")
    provider = FakeProvider({"addr1": [utxo()], "addr2": RuntimeError("502")})
    assert ChainPoller(provider, [dead, good], store).poll_once() == 1


def test_non_price_utxos_are_skipped_quietly(store):
    provider = FakeProvider({"addr1": [utxo(), utxo(tx_index=1)]})
    assert ChainPoller(provider, [target(none_decoder)], store).poll_once() == 0


def test_utxo_without_an_inline_datum_is_skipped(store):
    provider = FakeProvider({"addr1": [utxo(inline_datum=None)]})
    assert ChainPoller(provider, [target(ok_decoder)], store).poll_once() == 0


def test_raw_datum_prefers_cbor_hex():
    assert _raw_datum_text({"bytes": "d879", "value": {}}) == "d879"
    assert _raw_datum_text("d879") == "d879"
    assert _raw_datum_text({"value": {"int": 1}}) == '{"value":{"int":1}}'
    assert _raw_datum_text(None) is None
