//// End-to-end tests over a **real signed Pyth payload**.
////
//// `lib/pyth_guard/tests.ak` tests `check` and `select` directly, on
//// hand-built `PriceUpdate` values. That leaves one path uncovered, and it is
//// the path every consumer actually calls: `read` / `try_read`, which reach
//// the price through `pyth.get_updates` — the Pyth state reference input, the
//// withdrawal redeemer, and the upstream binary parser.
////
//// This module closes that gap without a network or an API key, by building
//// the transaction the ledger would present and driving the real parser with
//// real bytes.
////
//// ## Provenance of the payload
////
//// `signed_update` and the transaction scaffolding below are taken from
//// `pyth-network/pyth-lazer-cardano` (Apache-2.0), commit
//// `217b5917228b17f015719b27dd616a75ad6bd800`, where they back that project's
//// own `parses_update` and `gets_updates_with_current_script` tests. Reusing
//// their vector rather than inventing one is deliberate: a fixture we made up
//// would only prove we are self-consistent.
////
//// ## What the payload happens to contain, and why that is useful
////
//// Three feeds — ids 1, 2 and 112 — on `channel_id` 3, in a `Regular` market
//// session, with `feed_update_timestamp` equal to the message timestamp (so
//// nothing is being carried forward).
////
//// None of the three carries `confidence` or `publisher_count`: that
//// subscription did not request them. That makes this vector unusually good
//// for testing **fail-closed** behaviour, because the guard's default
//// insistence on a confidence bound has to refuse it — on real bytes, not on
//// a fixture built to fail.

use aiken/crypto.{ScriptHash}
use aiken/interval
use aiken/math/rational
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, ValidityRange,
  Withdraw,
}
use pyth.{Closed, Governance, Pyth, Regular}
use pyth_guard.{
  Accepted, ConfidenceUnavailable, FeedMissing, Price, PublisherCountUnavailable,
  Rejected, SessionNotAllowed, Stale, UnboundedValidity, WrongChannel,
}

/// One validly signed Pyth Lazer update, verbatim from upstream.
const signed_update: ByteArray =
  #"b9011a82db446efb9cf488be308398477ab37d650aeb3e06ad7e2424c31a97b4e318026486f544c2bbe17f85a3a158a4c8b628fa078066d7880b6bfbff8278139bf8e40380efc1f480c5615af3fb673d42287e993da9fbc3506b6e41dfa32950820c2e6cfe0075d3c79340699bb22e4c06000303010000000b00529a23605206000001b10d6c5e520600000280ba0b635206000004f8ff0600070008000900000a0008aa99440600000b20e4d495440600000c0140699bb22e4c0600020000000b00644c6fde2e0000000188a660de2e000000028a17ddde2e00000004f8ff0600070008000900000ae01c1a742e0000000b8898ec732e0000000c0140699bb22e4c0600700000000b00593e2c755106000001000000000000000002000000000000000004f4ff0601d809000000000000070129229ab22e4c0600080100209db4060000000900000a00000000000000000b00000000000000000c0140699bb22e4c0600"

/// The message timestamp inside `signed_update`, in milliseconds. Every feed
/// in it reports the same value for `feed_update_timestamp`.
const payload_ms: Int = 1772613309000

/// Feed ids present in the payload.
const feed_a: Int = 1

const feed_b: Int = 2

/// A feed id the payload does not carry.
const absent_feed: Int = 16

const payload_channel: Int = 3

const max_age: Int = 60_000

/// Stand-ins for a deployment. `pyth_id` is the policy of the Pyth state NFT;
/// everything this library guarantees is conditional on it being genuine.
const pyth_id: PolicyId = #"feed"

const withdraw_script: ScriptHash = #"900d"

// ------------------------------------------------------------------ scaffold

fn pyth_state() -> Pyth {
  Pyth(Governance(pyth_id, 0, #"", 0), [], [], withdraw_script)
}

/// The transaction shape a real integration must build: the Pyth state as a
/// reference input, and a zero withdrawal whose redeemer is the list of signed
/// updates.
fn transaction_over(range: ValidityRange) -> Transaction {
  let raw_updates: Data = [signed_update]
  Transaction {
    ..transaction.placeholder,
    validity_range: range,
    reference_inputs: [
      Input(
        OutputReference(#"", 0),
        Output {
          address: Address(Script(#""), None),
          value: assets.from_asset(pyth_id, "Pyth State", 1),
          datum: InlineDatum(pyth_state()),
          reference_script: None,
        },
      ),
    ],
    redeemers: [Pair(Withdraw(Script(withdraw_script)), raw_updates)],
  }
}

/// A transaction whose deadline sits `offset_ms` after the payload's own
/// timestamp — the window a builder would construct at that moment.
fn transaction_at(offset_ms: Int) -> Transaction {
  transaction_over(interval.between(payload_ms, payload_ms + offset_ms + 1_000))
}

/// The payload carries no confidence, so a guard for it must opt out
/// explicitly. That is the point of the opt-out being separately named.
fn guard_for(feed_id: Int) -> pyth_guard.Guard {
  pyth_guard.new_without_confidence_bound(feed_id, max_age)
}

/// Assert a price against upstream's own rounding, so this suite and theirs
/// agree about what the bytes mean rather than merely about the mantissa.
fn rounds_to(price: Price, expected: Int) -> Bool {
  expect Some(multiplier) = rational.from_int(10)
    |> rational.pow(price.exponent)
  (
    rational.from_int(price.value)
      |> rational.mul(multiplier)
      |> rational.round()
  ) == expected
}

// -------------------------------------------------------------- the full path

/// The headline: a real signed payload, read through the real parser, out of a
/// transaction shaped the way the ledger presents one.
test reads_a_real_signed_payload_end_to_end() {
  when pyth_guard.try_read(guard_for(feed_a), pyth_id, transaction_at(0)) is {
    Accepted(price) -> rounds_to(price, 69509)
    Rejected(_) -> False
  }
}

/// Feed selection through the full path: the payload carries three feeds, and
/// asking for the second returns the second.
test selects_the_requested_feed_from_a_three_feed_payload() {
  when pyth_guard.try_read(guard_for(feed_b), pyth_id, transaction_at(0)) is {
    Accepted(price) -> rounds_to(price, 2013)
    Rejected(_) -> False
  }
}

test rejects_a_feed_the_payload_does_not_carry() {
  pyth_guard.try_read(guard_for(absent_feed), pyth_id, transaction_at(0)) == Rejected(
    FeedMissing,
  )
}

/// Both timestamps in the payload agree, so the price is genuinely as fresh as
/// the message. Reading it back proves the generation timestamp survives the
/// parser rather than being an artefact of the hand-built fixtures next door.
test the_payload_reports_generation_and_delivery_alike() {
  when pyth_guard.try_read(guard_for(feed_a), pyth_id, transaction_at(0)) is {
    Accepted(price) -> and {
        price.generated_us == payload_ms * 1000,
        price.delivered_us == payload_ms * 1000,
      }
    Rejected(_) -> False
  }
}

/// Reading two feeds out of one payload costs two full parses.
///
/// `try_read` calls `pyth.get_updates`, and `get_updates` parses every signed
/// message in the redeemer from scratch. Nothing memoises it, so a consumer
/// settling two markets pays for the payload twice. Compare this test's
/// execution units against `reads_a_real_signed_payload_end_to_end`: the
/// difference is the parse, not the guard, and it is the argument for a
/// `read_many` that walks one parsed update several times.
test reading_two_feeds_parses_the_payload_twice() {
  let tx = transaction_at(0)
  and {
    pyth_guard.try_read(guard_for(feed_a), pyth_id, tx) != Rejected(FeedMissing),
    pyth_guard.try_read(guard_for(feed_b), pyth_id, tx) != Rejected(FeedMissing),
  }
}

// ------------------------------------------------------------------ freshness

/// The whole point of the library, exercised through the real parser: the same
/// validly signed bytes, read an hour later, are refused.
test the_same_payload_goes_stale_an_hour_later() {
  pyth_guard.try_read(guard_for(feed_a), pyth_id, transaction_at(3_600_000)) == Rejected(
    Stale,
  )
}

test the_payload_is_accepted_at_the_edge_of_its_window() {
  pyth_guard.try_read(
    guard_for(feed_a),
    pyth_id,
    transaction_over(interval.between(payload_ms, payload_ms + max_age)),
  ) != Rejected(Stale)
}

test rejects_a_transaction_with_no_finite_deadline() {
  pyth_guard.try_read(
    guard_for(feed_a),
    pyth_id,
    transaction_over(interval.after(payload_ms)),
  ) == Rejected(UnboundedValidity)
}

// --------------------------------------------------- fail-closed on real bytes

/// The subscription behind this payload did not request `confidence`. A guard
/// built the default way requires a confidence bound, cannot check one, and
/// refuses — on real bytes.
///
/// Reading an unsubscribed property as zero would turn "we did not ask" into
/// "the publishers agreed exactly", which is the most favourable possible
/// reading of an absence.
test the_default_guard_refuses_a_payload_without_confidence() {
  pyth_guard.check(
    pyth_guard.new(feed_a, max_age, 50),
    single_update(),
    interval.between(payload_ms, payload_ms + 1_000),
  ) == Rejected(ConfidenceUnavailable)
}

test a_publisher_floor_refuses_a_payload_without_publisher_counts() {
  pyth_guard.try_read(
    guard_for(feed_a) |> pyth_guard.with_min_publishers(8),
    pyth_id,
    transaction_at(0),
  ) == Rejected(PublisherCountUnavailable)
}

// ------------------------------------------------------- channel and session

test accepts_the_channel_the_payload_actually_arrived_on() {
  pyth_guard.try_read(
    guard_for(feed_a) |> pyth_guard.with_channel(payload_channel),
    pyth_id,
    transaction_at(0),
  ) != Rejected(WrongChannel)
}

test rejects_a_channel_the_payload_did_not_arrive_on() {
  pyth_guard.try_read(
    guard_for(feed_a) |> pyth_guard.with_channel(payload_channel + 1),
    pyth_id,
    transaction_at(0),
  ) == Rejected(WrongChannel)
}

test accepts_the_regular_session_the_payload_reports() {
  pyth_guard.try_read(
    guard_for(feed_a) |> pyth_guard.with_sessions([Regular]),
    pyth_id,
    transaction_at(0),
  ) != Rejected(SessionNotAllowed)
}

test rejects_a_session_the_payload_does_not_report() {
  pyth_guard.try_read(
    guard_for(feed_a) |> pyth_guard.with_sessions([Closed]),
    pyth_id,
    transaction_at(0),
  ) == Rejected(SessionNotAllowed)
}

// ------------------------------------------------------------- the trust chain

/// The root of trust, demonstrated rather than asserted.
///
/// With a `pyth_id` that does not match the state NFT, `get_updates` cannot
/// find the Pyth state at all and the script fails outright — this is not a
/// `Rejection`, because the library never gets far enough to have an opinion.
/// An attacker who *can* choose `pyth_id` supplies their own state UTxO and
/// their own withdraw script instead, and no signature is checked anywhere.
/// Hence: compile-time validator parameter, never a datum.
test a_wrong_pyth_id_cannot_even_locate_the_state() fail {
  pyth_guard.try_read(guard_for(feed_a), #"dead", transaction_at(0)) == Rejected(
    FeedMissing,
  )
}

/// Likewise if the state names a withdraw script that the transaction did not
/// actually run: there is no redeemer to read.
test a_state_naming_another_withdraw_script_finds_no_redeemer() fail {
  let raw_updates: Data = [signed_update]
  let tx = Transaction {
    ..transaction_at(0),
    redeemers: [Pair(Withdraw(Script(#"1bad")), raw_updates)],
  }
  pyth_guard.try_read(guard_for(feed_a), pyth_id, tx) == Rejected(FeedMissing)
}

// ---------------------------------------------------------------------- helper

/// The single update carried by `signed_update`, obtained through the real
/// parser, for the checks that are about `check` rather than about transaction
/// plumbing.
fn single_update() -> pyth.PriceUpdate {
  expect [update] = pyth.get_updates(pyth_id, transaction_at(0))
  update
}
