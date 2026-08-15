"""pythmon — off-chain drift monitor for Pyth Pro feeds consumed on Cardano.

Answers one question with evidence: when a Cardano protocol reads a price
on-chain, how far is that price from what Pyth was publishing at the time?

The two halves are independent. `stream` records what Pyth published; `poll`
records what protocols are holding on-chain; `drift` joins them after the fact.
Keeping the join at analysis time means a mistake in the analysis costs a
re-run, not the data.
"""

from __future__ import annotations

__version__ = "0.1.0"

__all__ = ["__version__"]
