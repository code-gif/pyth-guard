//// Reference consumer 1 of 2: a one-shot, price-gated lock.
////
//// Funds locked here may be taken by their owner while a guarded Pyth Pro
//// price sits at or above `min_price`. This is the smallest complete
//// integration: build a guard from the datum, read the price out of the
//// transaction, compare it.
////
//// ## This validator deliberately has no replay protection
////
//// It does not need any, and pretending otherwise would teach the wrong
//// lesson. The UTxO is consumed by the same spend that reads the price, so
//// there is no surviving state for a second transaction to re-apply the same
//// update to. That is why the datum carries no `last_seen_us` field and the
//// code never calls `newer_than`.
////
//// A contract that *does* persist state across spends — a vault, a pool, a
//// perp, anything with a continuing output — cannot reason that way, and
//// copying this file into one produces a contract with no replay protection
//// at all. `price_ratchet.ak` is the example to copy in that case.
////
//// ## What it does not do
////
//// It never touches signatures and never calls `pyth.get_updates` directly.
//// Signature verification is the Pyth withdraw script's job; freshness,
//// confidence and feed identity are `pyth_guard`'s.

use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use pyth_guard

pub type LockDatum {
  /// Key permitted to unlock. Ownership is orthogonal to the oracle plumbing
  /// this example is about, but a reference implementation that anyone may
  /// drain is a dangerous thing to have copied.
  owner: VerificationKeyHash,
  /// Pyth Pro numeric feed id this lock is denominated in.
  feed_id: Int,
  /// Threshold, expressed with `decimals` places.
  min_price: Int,
  /// Fixed-point places `min_price` is expressed in.
  decimals: Int,
  /// Freshness tolerance, in milliseconds.
  ///
  /// Two things at once, pulling in opposite directions: it is the window
  /// during which a captured update can still be used against you, *and* the
  /// window in which the spending transaction must reach a block. Cardano
  /// produces a block roughly every 20 s, so a value chosen purely for
  /// freshness — a second or two — mostly yields transactions that expire
  /// unincluded. See docs/INTEGRATION.md; the residual risk from a wide
  /// window is managed with confidence bounds and cooldowns, not by
  /// shrinking this.
  max_age_ms: Int,
  /// Confidence ceiling, in basis points of price.
  max_confidence_bps: Int,
}

validator price_lock(pyth_id: PolicyId) {
  spend(
    datum: Option<LockDatum>,
    _redeemer: Data,
    _own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(lock) = datum

    let guard =
      pyth_guard.new(lock.feed_id, lock.max_age_ms, lock.max_confidence_bps)

    let price = pyth_guard.read(guard, pyth_id, self)

    // Unlocking is the direction an attacker wants to push, so the threshold
    // is tested against the *low* end of the confidence interval. A price of
    // 0.42 with confidence 0.01 does not unlock a lock set at 0.42.
    let conservative = pyth_guard.at_confidence_floor(price)

    and {
      list.has(self.extra_signatories, lock.owner),
      pyth_guard.scaled(conservative, lock.decimals) >= lock.min_price,
    }
  }

  else(_) {
    fail
  }
}
