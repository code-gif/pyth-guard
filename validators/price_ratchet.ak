//// Reference consumer 2 of 2: a high-water-mark price ratchet.
////
//// One UTxO records the highest guarded price ever observed for one feed.
//// Anyone may advance it by presenting a fresher price. No funds move and
//// nothing is bought or sold — the point of this example is the *state
//// machine*, because persistent state is where replay protection actually
//// lives.
////
//// ## The rule this file exists to demonstrate
////
//// Checking `newer_than` against the stored timestamp is only half of the
//// obligation. The spend must also **write the new timestamp back into the
//// continuing output**. Omit that and the very same signed update satisfies
//// the check again in the next transaction, and the next, for as long as it
//// remains inside its freshness window — which is precisely the attack
//// `max_age_ms` was chosen to bound.
////
//// Check and advance are one obligation. `pyth_guard` can only supply the
//// check; the advance is unavoidably yours, because only your contract knows
//// where its state lives.
////
//// The other three conditions below are not incidental either. Pinning the
//// continuing output's value stops this being a withdrawal, pinning the
//// configuration stops a spend relaxing its own guard, and requiring exactly
//// one continuing output stops state being split across two.

use aiken/collection/list
use aiken/math
use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, OutputReference, Transaction, find_input}
use pyth_guard

pub type RatchetDatum {
  /// Pyth Pro numeric feed id being tracked.
  feed_id: Int,
  /// Fixed-point places `high_water` is expressed in.
  decimals: Int,
  /// Freshness tolerance, in milliseconds. Also the width of the window in
  /// which the spending transaction must reach a block — see
  /// docs/INTEGRATION.md before choosing a small number.
  max_age_ms: Int,
  /// Confidence ceiling, in basis points of price.
  max_confidence_bps: Int,
  /// Highest price observed so far, scaled to `decimals`.
  high_water: Int,
  /// Generation timestamp of the most recent price acted on, in microseconds.
  /// This is the replay guard, and it is only a guard because the validator
  /// below refuses to let it stand still.
  ///
  /// Generation time, not delivery time: Pyth carries a price forward in a
  /// stream of fresh messages, and storing the delivery time would let every
  /// one of them count as a new reading of an unchanged price.
  last_seen_us: Int,
}

validator price_ratchet(pyth_id: PolicyId) {
  spend(
    datum: Option<RatchetDatum>,
    _redeemer: Data,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    expect Some(state) = datum
    expect Some(own_input) = find_input(self.inputs, own_ref)
    let own_address = own_input.output.address

    let guard =
      pyth_guard.new(state.feed_id, state.max_age_ms, state.max_confidence_bps)

    let price = pyth_guard.read(guard, pyth_id, self)

    // The ratchet records what the price was, not the most favourable reading
    // of it, so the mid value is the right one here. A contract deciding
    // whether someone is solvent would want `at_confidence_floor` instead.
    let observed = pyth_guard.scaled(price, state.decimals)

    // Exactly one continuing output. Allowing two would let a spend fork the
    // state into a fresh copy and a stale one.
    expect [continuing] =
      list.filter(self.outputs, fn(output) { output.address == own_address })
    expect InlineDatum(raw) = continuing.datum
    expect next: RatchetDatum = raw

    and {
      // 1. The update must be strictly newer than the one last acted on.
      pyth_guard.newer_than(price, state.last_seen_us),
      // 2. ...and that timestamp must be persisted. Without this line,
      //    condition 1 is satisfied by the same update indefinitely.
      next.last_seen_us == price.generated_us,
      // 3. The ratchet only ever goes up.
      next.high_water == math.max(state.high_water, observed),
      // 4. A spend may not rewrite the terms it was checked against.
      next.feed_id == state.feed_id,
      next.decimals == state.decimals,
      next.max_age_ms == state.max_age_ms,
      next.max_confidence_bps == state.max_confidence_bps,
      // 5. The value stays put. This example moves no funds, and saying so
      //    explicitly is what stops it becoming a withdrawal.
      continuing.value == own_input.output.value,
    }
  }

  else(_) {
    fail
  }
}
