"""Cardano-side polling.

Every protocol stores its oracle price differently, so the decoder is
pluggable: register one per target and the poller handles the rest. Nothing
here assumes a particular chain-index provider beyond a UTxO-by-address query,
which Koios, Blockfrost and Ogmios/Kupo all expose in some form.

Two things this module is careful about, because both distort the measurement
downstream:

**The raw datum is kept.** A decoder is a guess about someone else's encoding
and the first version of one is often wrong. Storing the bytes means a
corrected decoder can be replayed over history instead of invalidating it.

**On-chain time and observation time are different columns.** ``observed_us``
is when *we polled*; ``block_time_s`` is when the price actually landed. The
gap between them is our sampling latency, and folding it into the reported age
of somebody else's price would overstate their staleness by up to a full poll
interval.
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

import httpx

from .store import ChainObs, Store, now_us

log = logging.getLogger(__name__)


@dataclass(slots=True)
class DecodedPrice:
    """What a decoder pulls out of one UTxO's inline datum."""

    #: Price mantissa, already rescaled to `decimals`.
    price: int
    #: Fixed-point places `price` is expressed in.
    decimals: int
    #: Timestamp the datum itself claims, if it carries one.
    stated_ts_us: int | None = None


#: Returns None when the UTxO is not a price at all — many script addresses
#: hold unrelated UTxOs and skipping them is normal, not an error.
Decoder = Callable[[dict], "DecodedPrice | None"]


class Provider(Protocol):
    def utxos_at(self, address: str) -> list[dict]: ...


@dataclass(slots=True)
class Target:
    """One on-chain price to watch."""

    #: Label used in reports, e.g. "someprotocol-ada-usd".
    source: str
    #: Script address holding the price UTxO.
    address: str
    decoder: Decoder
    #: The Pyth Pro feed this price is compared against.
    pyth_feed_id: int


class KoiosProvider:
    """Koios UTxO reader.

    Paginated because Koios caps a response at 1000 rows and silently returns
    the first page otherwise — which would make a busy address look like a
    quiet one.
    """

    PAGE = 1000

    def __init__(
        self,
        base_url: str = "https://api.koios.rest/api/v1",
        timeout: float = 15.0,
        api_token: str | None = None,
    ):
        self.base_url = base_url.rstrip("/")
        headers = {"Authorization": f"Bearer {api_token}"} if api_token else None
        self.client = httpx.Client(timeout=timeout, headers=headers)

    def __enter__(self) -> KoiosProvider:
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    def utxos_at(self, address: str) -> list[dict]:
        rows: list[dict] = []
        offset = 0
        while True:
            response = self.client.post(
                f"{self.base_url}/address_utxos",
                params={"offset": offset, "limit": self.PAGE},
                json={"_addresses": [address], "_extended": True},
            )
            response.raise_for_status()
            page = response.json()
            rows.extend(page)
            if len(page) < self.PAGE:
                return rows
            offset += self.PAGE

    def close(self) -> None:
        self.client.close()


class ChainPoller:
    def __init__(self, provider: Provider, targets: list[Target], store: Store):
        self.provider = provider
        self.targets = targets
        self.store = store

    def poll_once(self) -> int:
        rows: list[ChainObs] = []
        for target in self.targets:
            try:
                utxos = self.provider.utxos_at(target.address)
            except Exception as exc:  # noqa: BLE001 — one bad target must not stop the rest
                log.warning("poll failed for %s: %s", target.source, exc)
                continue

            # One timestamp for the whole target, taken after the fetch, so
            # every UTxO in a page shares the instant it was observed at.
            observed = now_us()
            for utxo in utxos:
                datum = utxo.get("inline_datum")
                if not datum:
                    continue
                try:
                    decoded = target.decoder(datum)
                except Exception as exc:  # noqa: BLE001 — a decoder is a guess
                    log.warning("decoder failed for %s: %s", target.source, exc)
                    continue
                if decoded is None:
                    continue

                tx_hash = utxo.get("tx_hash")
                if tx_hash is None:
                    log.warning("skipping UTxO with no tx_hash at %s", target.source)
                    continue

                rows.append(
                    ChainObs(
                        source=target.source,
                        utxo_ref=f"{tx_hash}#{utxo.get('tx_index', 0)}",
                        observed_us=observed,
                        address=target.address,
                        price=decoded.price,
                        decimals=decoded.decimals,
                        stated_ts_us=decoded.stated_ts_us,
                        block_time_s=utxo.get("block_time"),
                        raw_datum=_raw_datum_text(datum),
                    )
                )
        return self.store.write_chain_obs(rows)

    def poll_forever(self, interval_s: float, on_tick: Callable[[int], None] | None = None) -> None:
        """Poll on a fixed period until interrupted.

        The interval is measured from the start of each poll, so a slow request
        shortens the following sleep instead of letting the sampling period
        drift.
        """
        while True:
            started = time.monotonic()
            written = self.poll_once()
            if on_tick is not None:
                on_tick(written)
            elapsed = time.monotonic() - started
            time.sleep(max(0.0, interval_s - elapsed))


def _raw_datum_text(datum: object) -> str | None:
    """Keep the datum in whatever shape the provider gave it.

    Koios returns an object with `bytes` and `value`; other providers return a
    hex string. Preferring the CBOR hex when present keeps the stored form
    provider-independent and re-decodable.
    """
    if isinstance(datum, dict):
        raw = datum.get("bytes")
        if isinstance(raw, str):
            return raw
        return json.dumps(datum, separators=(",", ":"), sort_keys=True)
    if isinstance(datum, str):
        return datum
    return None
