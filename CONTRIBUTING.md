# Contributing

## Getting set up

The two halves are independent. You can work on either without the other.

**On-chain** — requires [Aiken](https://aiken-lang.org/installation-instructions)
v1.1.21 or later:

```bash
aiken check      # runs the test suite
aiken build      # emits plutus.json
aiken fmt        # formats; CI runs `aiken fmt --check`
```

**Off-chain** — requires Python 3.11+:

```bash
cd monitor
pip install -e ".[dev]"
pytest
ruff check .
python -m pythmon demo    # end-to-end on synthetic data, no API key
```

## The bar for a change to `lib/pyth_guard.ak`

This library exists so that integrators do not each reimplement the checks the
Pyth withdraw script leaves to them. That gives it one obligation above the
usual: **a check that is wrong here is wrong everywhere it is used.**

So:

- **Every behavioural change needs a test**, and a test that fails before the
  change. `aiken check` is cheap; there is no excuse for an untested branch.
- **Rejection tests must pin the reason for rejection**, not merely that
  something failed. Compare against the exact `Rejection`
  (`check(..) == Rejected(Stale)`), never write a bare `fail` test. Aiken erases a
  discarded `let _ =` binding, so a `fail` test can pass without ever running
  the call it names — and a test that passes because of a typo in its own
  fixture is worse than no test. The header of `lib/pyth_guard/tests.ak`
  explains this at length.
- **State the direction of any inequality change.** For every comparison in
  `validate`, one direction accepts a price that should have been rejected and
  the other rejects a good one. Say which you are moving and why.
- **New checks are opt-in unless they are free.** A guard that suddenly starts
  rejecting prices breaks live contracts on upgrade. Additive constraints go
  behind a `with_*` builder.

## The bar for a change to the threat model

`docs/THREAT_MODEL.md` records assumptions, not aspirations. If you change what
the library checks, change the corresponding assumption in the same commit. An
assumption that no longer matches the code is a security defect in its own
right.

## Style

- Aiken: `aiken fmt`. Comments explain *why a check is safe*, not what the line
  does.
- Python: `ruff check`, 100 columns. Module docstrings explain the measurement
  the module implements; that is the part a reader cannot reconstruct.
- Commits: imperative subject, and say what changed in behaviour rather than
  which files moved.

## Upstreaming

This library is a candidate contribution to
[`pyth-network/pyth-lazer-cardano`](https://github.com/pyth-network/pyth-lazer-cardano).
It is licensed Apache-2.0 to match, and deliberately adds no dependencies
beyond `aiken-lang/stdlib` and that repository. Keep it that way — a new
dependency closes off the merge path.
