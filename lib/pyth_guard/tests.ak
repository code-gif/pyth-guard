//// Tests for `pyth_guard`.
////
//// ## Why these assert reasons rather than failures
////
//// A rejection test written as `test x() fail { let _ = validate(..) True }`
//// passes whenever *anything* in the body errors — and worse, Aiken erases a
//// discarded `let _ =` binding entirely, so the call under test may never run
//// at all. A typo in the fixture, a feed id that was never going to match, a
//// malformed guard: all of them produce a green test for a check that was
//// never reached. The suite then reports that a guard rejects stale prices
//// when it has proven no such thing.
////
//// So `check` returns `Result<Price, Rejection>` and these tests compare
//// against the exact `Rejection`. A test named `rejects_a_stale_update` fails
//// if the update is refused for any reason other than staleness.
////
//// The two genuine `fail` tests below cover `expect` bounds that have no
//// `Result` form. Each one *uses* the value it computes as the test's result,
//// so the expression cannot be discarded.
////
//// ## What is not covered here
////
//// Nothing in this file constructs a `Transaction`. `try_read` is a two-line
//// composition of `pyth.get_updates` and `select`, and `select` is tested
//// directly; faking a Pyth state reference input and a withdrawal redeemer
//// would test the upstream parser rather than this library. The
//// transaction-level path is exercised on a live network instead — see
//// ROADMAP.md.

use aiken/interval.{Finite, Interval, IntervalBound}
use cardano/transaction.{ValidityRange}
use pyth.{Closed, Feed, MarketSession, PriceUpdate, Regular}
use pyth_guard.{
  AmbiguousFeed, ConfidenceTooWide, ConfidenceUnavailable, ExponentUnavailable,
  FeedMissing, FutureDated, GenerationTimeUnavailable, InconsistentTimestamps,
  MalformedGuard, NonPositivePrice, Price, PriceUnavailable,
  PublisherCountUnavailable, Rejection, SessionNotAllowed, SessionUnavailable,
  Stale, TooFewPublishers, UnboundedValidity, WrongChannel,
}
use types/u16.{U16}
use types/u32
use types/u64
use types/u8

// A plausible wall-clock instant. Everything else is expressed relative to it.
const now_ms: Int = 1_760_000_000_000

const now_us: Int = 1_760_000_000_000_000

const ada_usd: Int = 16

/// 60 s. Not a freshness preference — a floor imposed by block cadence. See
/// the note on sizing `max_age_ms` in the module header.
const max_age: Int = 60_000

// ------------------------------------------------------------------ fixtures

/// Validity range with an **inclusive** upper bound, which is what
/// `interval.between` produces.
fn window(from_ms: Int, to_ms: Int) -> ValidityRange {
  interval.between(from_ms, to_ms)
}

/// Validity range with an **exclusive** upper bound, which is what the ledger
/// actually produces, because a transaction's `ttl` is exclusive. The two
/// disagree by one millisecond and reach different branches of `bounds`.
fn ledger_window(from_ms: Int, to_ms: Int) -> ValidityRange {
  Interval {
    lower_bound: IntervalBound {
      bound_type: Finite(from_ms),
      is_inclusive: True,
    },
    upper_bound: IntervalBound {
      bound_type: Finite(to_ms),
      is_inclusive: False,
    },
  }
}

/// The window a correctly built transaction carries: open at the price's own
/// timestamp, closing `max_age` later.
fn built_window(price_ms: Int) -> ValidityRange {
  window(price_ms, price_ms + max_age)
}

fn feed_full(
  id: Int,
  price: Option<Option<Int>>,
  exponent: Option<Int>,
  confidence: Option<Option<Int>>,
  publisher_count: Option<U16>,
  generated_ms: Option<Int>,
  session: Option<MarketSession>,
) -> Feed {
  let generated =
    when generated_ms is {
      None -> None
      Some(ms) -> Some(Some(u64.from_int(ms * 1000)))
    }
  Feed {
    feed_id: u32.from_int(id),
    price,
    best_bid_price: None,
    best_ask_price: None,
    publisher_count,
    exponent,
    confidence,
    funding_rate: None,
    funding_timestamp: None,
    funding_rate_interval: None,
    market_session: session,
    ema_price: None,
    ema_confidence: None,
    feed_update_timestamp: generated,
  }
}

/// The ordinary case: a fully populated feed whose price was generated at
/// `generated_ms`.
///
/// Note the confidence encoding. Zero confidence arrives on the wire as an
/// absent *inner* value, because the underlying property is non-zero
/// constrained. Reproduced faithfully because it is the shape most likely to
/// be mishandled, and mishandling it rejects the tightest prices Pyth
/// publishes.
fn feed_at(
  id: Int,
  price: Int,
  confidence: Int,
  publishers: Int,
  generated_ms: Int,
) -> Feed {
  let encoded_confidence =
    if confidence == 0 {
      None
    } else {
      Some(confidence)
    }
  feed_full(
    id,
    Some(Some(price)),
    Some(-8),
    Some(encoded_confidence),
    Some(u16.from_int(publishers)),
    Some(generated_ms),
    Some(Regular),
  )
}

/// ADA/USD at 0.42 with 4 bp of confidence, from 28 publishers.
fn ada_feed_at(generated_ms: Int) -> Feed {
  feed_at(ada_usd, 42_000_000, 16_800, 28, generated_ms)
}

fn update(at_ms: Int, feeds: List<Feed>) -> PriceUpdate {
  PriceUpdate {
    timestamp_us: u64.from_int(at_ms * 1000),
    channel_id: u8.from_int(1),
    feeds,
  }
}

/// A message produced at `at_ms` carrying an ADA/USD price generated at that
/// same instant — nothing carried forward.
fn fresh_update(at_ms: Int) -> PriceUpdate {
  update(at_ms, [ada_feed_at(at_ms)])
}

fn guard() -> pyth_guard.Guard {
  pyth_guard.new(ada_usd, max_age, 50)
}

fn expected_price(
  generated_ms: Int,
  delivered_ms: Int,
) -> Result<Price, Rejection> {
  Ok(
    Price {
      value: 42_000_000,
      exponent: -8,
      confidence: 16_800,
      generated_us: generated_ms * 1000,
      delivered_us: delivered_ms * 1000,
    },
  )
}

fn sample_price() -> Price {
  Price {
    value: 42_000_000,
    exponent: -8,
    confidence: 16_800,
    generated_us: now_us,
    delivered_us: now_us,
  }
}

// -------------------------------------------------- the carry-forward attack

/// **The defect this library exists to close, one level down.**
///
/// Pyth carries a price forward when its publishers go quiet or its market
/// shuts: it keeps emitting validly signed messages whose `timestamp_us` is
/// always current, while the price inside them was generated hours ago. A
/// guard that measures freshness against the message timestamp accepts every
/// one of them.
///
/// Here the envelope is one second old and the price inside it is six hours
/// old. It must be refused, and refused *as stale*.
test rejects_a_price_carried_forward_in_a_fresh_envelope() {
  pyth_guard.check(
    guard(),
    update(now_ms - 1_000, [ada_feed_at(now_ms - 21_600_000)]),
    window(now_ms - 10_000, now_ms),
  ) == Error(Stale)
}

/// The mirror of the above: same envelope, price generated a moment ago.
test accepts_a_freshly_generated_price() {
  pyth_guard.check(
    guard(),
    update(now_ms - 1_000, [ada_feed_at(now_ms - 1_000)]),
    window(now_ms - 10_000, now_ms),
  ) == expected_price(now_ms - 1_000, now_ms - 1_000)
}

/// Freshness is decided by the generation time alone, so a message delivered
/// long ago carrying a price generated at the same moment is exactly as
/// acceptable as a recent one — and a recent message carrying an old price is
/// not. Only the price's own age matters.
test delivery_time_does_not_rescue_a_stale_price() {
  and {
    // Old envelope, old price: stale.
    pyth_guard.check(
      guard(),
      update(now_ms - 120_000, [ada_feed_at(now_ms - 120_000)]),
      window(now_ms - 10_000, now_ms),
    ) == Error(Stale),
    // New envelope, old price: still stale.
    pyth_guard.check(
      guard(),
      update(now_ms, [ada_feed_at(now_ms - 120_000)]),
      window(now_ms - 10_000, now_ms),
    ) == Error(Stale),
  }
}

/// Fails closed. A consumer that did not subscribe to `feedUpdateTimestamp`
/// cannot establish price freshness at all, and falling back to the message
/// timestamp would silently reinstate the defect above.
test rejects_a_feed_with_no_generation_timestamp() {
  let bare =
    feed_full(
      ada_usd,
      Some(Some(42_000_000)),
      Some(-8),
      Some(Some(16_800)),
      Some(u16.from_int(28)),
      None,
      Some(Regular),
    )
  pyth_guard.check(
    guard(),
    update(now_ms - 1_000, [bare]),
    window(now_ms - 10_000, now_ms),
  ) == Error(GenerationTimeUnavailable)
}

/// A price cannot have been generated after the message that carried it.
test rejects_a_feed_generated_after_its_message() {
  pyth_guard.check(
    guard(),
    update(now_ms - 5_000, [ada_feed_at(now_ms - 1_000)]),
    window(now_ms - 10_000, now_ms),
  ) == Error(InconsistentTimestamps)
}

// ----------------------------------------------------------------- freshness

test accepts_a_price_exactly_at_the_age_limit() {
  pyth_guard.check(
    guard(),
    update(now_ms, [ada_feed_at(now_ms - max_age)]),
    window(now_ms - 10_000, now_ms),
  ) != Error(Stale)
}

/// One microsecond past the limit. The library compares in microseconds
/// throughout and divides nothing, so this boundary is exact rather than
/// rounded to the nearest millisecond.
test rejects_a_price_one_microsecond_too_old() {
  let generated_us = now_us - max_age * 1000 - 1
  let carried =
    feed_full(
      ada_usd,
      Some(Some(42_000_000)),
      Some(-8),
      Some(Some(16_800)),
      Some(u16.from_int(28)),
      None,
      Some(Regular),
    )
  let precise =
    Feed {
      ..carried,
      feed_update_timestamp: Some(Some(u64.from_int(generated_us))),
    }
  pyth_guard.check(
    guard(),
    update(now_ms, [precise]),
    window(now_ms - 10_000, now_ms),
  ) == Error(Stale)
}

/// The failure mode the library was written for, in its original form.
test rejects_an_hour_old_update() {
  pyth_guard.check(
    guard(),
    fresh_update(now_ms - 3_600_000),
    window(now_ms - 10_000, now_ms),
  ) == Error(Stale)
}

test rejects_a_future_dated_message() {
  pyth_guard.check(
    guard(),
    fresh_update(now_ms + 1),
    window(now_ms - 10_000, now_ms),
  ) == Error(FutureDated)
}

test accepts_a_message_exactly_at_the_deadline() {
  pyth_guard.check(guard(), fresh_update(now_ms), window(now_ms - 10_000, now_ms)) != Error(
    FutureDated,
  )
}

// -------------------------------------------------------- strict future dating

/// By default the future-dating check compares against the deadline, which
/// whoever builds the transaction chooses freely — so an update claiming a
/// time five minutes ahead passes simply by setting the deadline to match.
test default_future_dating_is_satisfiable_by_the_builder() {
  let ahead = now_ms + 300_000
  pyth_guard.check(guard(), fresh_update(ahead), window(now_ms, ahead)) != Error(
    FutureDated,
  )
}

/// With the strict check the comparison moves to the lower bound, which the
/// ledger enforces: the transaction cannot be included before it. The same
/// transaction is now refused.
test strict_future_dating_catches_what_the_default_misses() {
  let ahead = now_ms + 300_000
  pyth_guard.check(
    guard() |> pyth_guard.with_strict_future_dating(),
    fresh_update(ahead),
    window(now_ms, ahead),
  ) == Error(FutureDated)
}

/// ...and a correctly built transaction — one whose `invalid_before` is the
/// price's own timestamp — still passes.
test strict_future_dating_accepts_a_correctly_built_window() {
  pyth_guard.check(
    guard() |> pyth_guard.with_strict_future_dating(),
    fresh_update(now_ms - 1_000),
    built_window(now_ms - 1_000),
  ) == expected_price(now_ms - 1_000, now_ms - 1_000)
}

/// With an open lower bound there is nothing enforced to compare against, so
/// the strict check degrades to the default rather than refusing everything.
test strict_future_dating_degrades_on_an_open_lower_bound() {
  pyth_guard.check(
    guard() |> pyth_guard.with_strict_future_dating(),
    fresh_update(now_ms - 1_000),
    interval.before(now_ms),
  ) != Error(FutureDated)
}

// --------------------------------------------- validity range interpretation

/// The ledger's `ttl` is exclusive, so the last instant at which a transaction
/// can be accepted is one millisecond *before* the number in the bound. An
/// earlier deadline means less elapsed time, so reading the bound as exclusive
/// is one millisecond more permissive about age — not less. Getting
/// `is_inclusive` wrong is a real behavioural difference, not a rounding
/// detail.
test the_two_bound_readings_differ_by_one_millisecond() {
  let payload = update(now_ms, [ada_feed_at(now_ms - max_age - 1)])
  and {
    pyth_guard.check(guard(), payload, window(now_ms - 10_000, now_ms)) == Error(
      Stale,
    ),
    pyth_guard.check(guard(), payload, ledger_window(now_ms - 10_000, now_ms)) != Error(
      Stale,
    ),
  }
}

/// Without a finite upper bound the script has no notion of "now", so any
/// freshness check against it would pass for any timestamp whatsoever. This is
/// the single most likely way a real integration gets this wrong.
test rejects_an_unbounded_validity_range() {
  pyth_guard.check(
    guard(),
    fresh_update(now_ms - 1_000),
    interval.after(now_ms - 10_000),
  ) == Error(UnboundedValidity)
}

/// An unbounded *lower* bound is fine by default: freshness binds at the
/// deadline, and the deadline is still finite.
test accepts_an_unbounded_lower_bound() {
  pyth_guard.check(
    guard(),
    fresh_update(now_ms - 1_000),
    interval.before(now_ms),
  ) == expected_price(now_ms - 1_000, now_ms - 1_000)
}

// -------------------------------------------------------------- feed identity

test rejects_a_missing_feed() {
  pyth_guard.check(
    guard(),
    update(now_ms - 1_000, [feed_at(17, 42_000_000, 16_800, 28, now_ms - 1_000)]),
    window(now_ms - 10_000, now_ms),
  ) == Error(FeedMissing)
}

/// Picks the requested feed out of a multi-feed update rather than the first.
test selects_the_requested_feed() {
  pyth_guard.check(
    guard(),
    update(
      now_ms - 1_000,
      [
        feed_at(17, 99_000_000, 1_000, 28, now_ms - 1_000),
        ada_feed_at(now_ms - 1_000),
        feed_at(1, 1, 0, 5, now_ms - 1_000),
      ],
    ),
    window(now_ms - 10_000, now_ms),
  ) == expected_price(now_ms - 1_000, now_ms - 1_000)
}

/// `list.find` would silently take the first of two, and which one it took
/// would depend on the order the transaction author chose.
test rejects_the_same_feed_twice_in_one_update() {
  pyth_guard.check(
    guard(),
    update(
      now_ms - 1_000,
      [
        ada_feed_at(now_ms - 1_000),
        feed_at(ada_usd, 99_000_000, 1_000, 28, now_ms - 1_000),
      ],
    ),
    window(now_ms - 10_000, now_ms),
  ) == Error(AmbiguousFeed)
}

// ----------------------------------------------------- selection over updates

/// Another protocol sharing the transaction has its own update for its own
/// feed. That is legitimate and must not break us.
test select_ignores_updates_for_other_feeds() {
  pyth_guard.select(
    guard(),
    [
      update(now_ms - 900, [feed_at(1, 99_000_000, 1_000, 28, now_ms - 900)]),
      update(now_ms - 1_000, [ada_feed_at(now_ms - 1_000)]),
      update(now_ms - 800, [feed_at(17, 1, 0, 5, now_ms - 800)]),
    ],
    window(now_ms - 10_000, now_ms),
  ) == expected_price(now_ms - 1_000, now_ms - 1_000)
}

/// Two updates both carrying our feed at different prices. Both are validly
/// signed and both are inside the freshness window, so there is no honest way
/// to choose — and the transaction author picked the pair.
test select_rejects_two_updates_carrying_the_same_feed() {
  pyth_guard.select(
    guard(),
    [
      update(now_ms - 1_000, [ada_feed_at(now_ms - 1_000)]),
      update(
        now_ms - 900,
        [feed_at(ada_usd, 41_000_000, 1_000, 28, now_ms - 900)],
      ),
    ],
    window(now_ms - 10_000, now_ms),
  ) == Error(AmbiguousFeed)
}

test select_rejects_an_empty_update_list() {
  pyth_guard.select(guard(), [], window(now_ms - 10_000, now_ms)) == Error(
    FeedMissing,
  )
}

// --------------------------------------------------------------- market session

/// Pyth keeps delivering a feed when its market is shut. Out of hours the
/// price is carried forward, so a session constraint and the generation-time
/// check defend the same ground from two directions — but a market can also
/// close moments after a genuinely fresh print, which the age check alone
/// would wave through.
test rejects_a_closed_market_when_a_session_is_required() {
  let shut =
    feed_full(
      ada_usd,
      Some(Some(42_000_000)),
      Some(-8),
      Some(Some(16_800)),
      Some(u16.from_int(28)),
      Some(now_ms - 1_000),
      Some(Closed),
    )
  pyth_guard.check(
    guard() |> pyth_guard.with_sessions([Regular]),
    update(now_ms - 1_000, [shut]),
    window(now_ms - 10_000, now_ms),
  ) == Error(SessionNotAllowed)
}

test accepts_an_allowed_session() {
  pyth_guard.check(
    guard() |> pyth_guard.with_sessions([Regular]),
    fresh_update(now_ms - 1_000),
    window(now_ms - 10_000, now_ms),
  ) == expected_price(now_ms - 1_000, now_ms - 1_000)
}

/// A 24/7 feed with no session constraint is unaffected, including when the
/// property is absent entirely.
test ignores_the_session_when_none_is_required() {
  let sessionless =
    feed_full(
      ada_usd,
      Some(Some(42_000_000)),
      Some(-8),
      Some(Some(16_800)),
      Some(u16.from_int(28)),
      Some(now_ms - 1_000),
      None,
    )
  pyth_guard.check(
    guard(),
    update(now_ms - 1_000, [sessionless]),
    window(now_ms - 10_000, now_ms),
  ) == expected_price(now_ms - 1_000, now_ms - 1_000)
}

test rejects_when_a_required_session_cannot_be_checked() {
  let sessionless =
    feed_full(
      ada_usd,
      Some(Some(42_000_000)),
      Some(-8),
      Some(Some(16_800)),
      Some(u16.from_int(28)),
      Some(now_ms - 1_000),
      None,
    )
  pyth_guard.check(
    guard() |> pyth_guard.with_sessions([Regular]),
    update(now_ms - 1_000, [sessionless]),
    window(now_ms - 10_000, now_ms),
  ) == Error(SessionUnavailable)
}

// ------------------------------------------------------------------ confidence

test rejects_a_wide_confidence_interval() {
  // 0.60% of price against a 0.50% ceiling.
  pyth_guard.check(
    guard(),
    update(
      now_ms - 1_000,
      [feed_at(ada_usd, 42_000_000, 252_000, 28, now_ms - 1_000)],
    ),
    window(now_ms - 10_000, now_ms),
  ) == Error(ConfidenceTooWide)
}

test accepts_confidence_exactly_at_the_ceiling() {
  // 50 bp of 42_000_000 is exactly 210_000.
  pyth_guard.check(
    guard(),
    update(
      now_ms - 1_000,
      [feed_at(ada_usd, 42_000_000, 210_000, 28, now_ms - 1_000)],
    ),
    window(now_ms - 10_000, now_ms),
  ) != Error(ConfidenceTooWide)
}

test rejects_confidence_one_unit_over_the_ceiling() {
  pyth_guard.check(
    guard(),
    update(
      now_ms - 1_000,
      [feed_at(ada_usd, 42_000_000, 210_001, 28, now_ms - 1_000)],
    ),
    window(now_ms - 10_000, now_ms),
  ) == Error(ConfidenceTooWide)
}

/// Zero confidence arrives as an absent inner value. Treating that as
/// "property missing" would reject the tightest prices Pyth can publish.
test accepts_zero_confidence() {
  pyth_guard.check(
    guard(),
    update(now_ms - 1_000, [feed_at(ada_usd, 42_000_000, 0, 28, now_ms - 1_000)]),
    window(now_ms - 10_000, now_ms),
  ) == Ok(
    Price {
      value: 42_000_000,
      exponent: -8,
      confidence: 0,
      generated_us: ( now_ms - 1_000 ) * 1000,
      delivered_us: ( now_ms - 1_000 ) * 1000,
    },
  )
}

/// A bound was required and the subscription did not carry the property, so
/// the bound cannot be checked. Reading an unsubscribed property as zero would
/// turn "we did not ask" into "the publishers agreed exactly".
test rejects_when_a_required_confidence_bound_cannot_be_checked() {
  let bare =
    feed_full(
      ada_usd,
      Some(Some(42_000_000)),
      Some(-8),
      None,
      Some(u16.from_int(28)),
      Some(now_ms - 1_000),
      Some(Regular),
    )
  pyth_guard.check(
    guard(),
    update(now_ms - 1_000, [bare]),
    window(now_ms - 10_000, now_ms),
  ) == Error(ConfidenceUnavailable)
}

/// ...but a guard that explicitly opted out has no reason to demand it.
test accepts_absent_confidence_when_no_bound_was_requested() {
  let bare =
    feed_full(
      ada_usd,
      Some(Some(42_000_000)),
      Some(-8),
      None,
      Some(u16.from_int(28)),
      Some(now_ms - 1_000),
      Some(Regular),
    )
  pyth_guard.check(
    pyth_guard.new_without_confidence_bound(ada_usd, max_age),
    update(now_ms - 1_000, [bare]),
    window(now_ms - 10_000, now_ms),
  ) == Ok(
    Price {
      value: 42_000_000,
      exponent: -8,
      confidence: 0,
      generated_us: ( now_ms - 1_000 ) * 1000,
      delivered_us: ( now_ms - 1_000 ) * 1000,
    },
  )
}

// ------------------------------------------------------------------- publishers

test rejects_too_few_publishers() {
  pyth_guard.check(
    guard() |> pyth_guard.with_min_publishers(10),
    update(
      now_ms - 1_000,
      [feed_at(ada_usd, 42_000_000, 16_800, 9, now_ms - 1_000)],
    ),
    window(now_ms - 10_000, now_ms),
  ) == Error(TooFewPublishers)
}

test accepts_exactly_enough_publishers() {
  pyth_guard.check(
    guard() |> pyth_guard.with_min_publishers(10),
    update(
      now_ms - 1_000,
      [feed_at(ada_usd, 42_000_000, 16_800, 10, now_ms - 1_000)],
    ),
    window(now_ms - 10_000, now_ms),
  ) != Error(TooFewPublishers)
}

test rejects_when_a_required_publisher_floor_cannot_be_checked() {
  let bare =
    feed_full(
      ada_usd,
      Some(Some(42_000_000)),
      Some(-8),
      Some(Some(16_800)),
      None,
      Some(now_ms - 1_000),
      Some(Regular),
    )
  pyth_guard.check(
    guard() |> pyth_guard.with_min_publishers(10),
    update(now_ms - 1_000, [bare]),
    window(now_ms - 10_000, now_ms),
  ) == Error(PublisherCountUnavailable)
}

// ---------------------------------------------------------------------- channel

test rejects_a_mismatched_channel() {
  pyth_guard.check(
    guard() |> pyth_guard.with_channel(2),
    fresh_update(now_ms - 1_000),
    window(now_ms - 10_000, now_ms),
  ) == Error(WrongChannel)
}

test accepts_the_expected_channel() {
  pyth_guard.check(
    guard() |> pyth_guard.with_channel(1),
    fresh_update(now_ms - 1_000),
    window(now_ms - 10_000, now_ms),
  ) != Error(WrongChannel)
}

// ------------------------------------------------------- malformed input

/// Guards are frequently built from a datum, which the contract does not
/// necessarily control. A negative tolerance would otherwise make the
/// freshness comparison meaningless rather than strict.
test rejects_a_negative_max_age() {
  pyth_guard.check(
    pyth_guard.new(ada_usd, -1, 50),
    fresh_update(now_ms - 1_000),
    window(now_ms - 10_000, now_ms),
  ) == Error(MalformedGuard)
}

test rejects_a_negative_confidence_bound() {
  pyth_guard.check(
    pyth_guard.new(ada_usd, max_age, -1),
    fresh_update(now_ms - 1_000),
    window(now_ms - 10_000, now_ms),
  ) == Error(MalformedGuard)
}

test rejects_an_absent_price() {
  let bare =
    feed_full(
      ada_usd,
      None,
      Some(-8),
      Some(Some(0)),
      None,
      Some(now_ms - 1_000),
      None,
    )
  pyth_guard.check(
    pyth_guard.new_without_confidence_bound(ada_usd, max_age),
    update(now_ms - 1_000, [bare]),
    window(now_ms - 10_000, now_ms),
  ) == Error(PriceUnavailable)
}

/// A zero price is encoded as an absent inner value, exactly like a zero
/// confidence — but unlike confidence, a zero price is unusable.
test rejects_a_zero_price() {
  let zeroed =
    feed_full(
      ada_usd,
      Some(None),
      Some(-8),
      Some(Some(0)),
      None,
      Some(now_ms - 1_000),
      None,
    )
  pyth_guard.check(
    pyth_guard.new_without_confidence_bound(ada_usd, max_age),
    update(now_ms - 1_000, [zeroed]),
    window(now_ms - 10_000, now_ms),
  ) == Error(PriceUnavailable)
}

/// Narrower than the wire domain, which is a signed non-zero i64.
/// Negative-quoting feeds are out of scope, and the confidence comparison
/// depends on this sign.
test rejects_a_negative_price() {
  let negative =
    feed_full(
      ada_usd,
      Some(Some(-1)),
      Some(-8),
      Some(Some(0)),
      None,
      Some(now_ms - 1_000),
      None,
    )
  pyth_guard.check(
    pyth_guard.new_without_confidence_bound(ada_usd, max_age),
    update(now_ms - 1_000, [negative]),
    window(now_ms - 10_000, now_ms),
  ) == Error(NonPositivePrice)
}

test rejects_an_absent_exponent() {
  let bare =
    feed_full(
      ada_usd,
      Some(Some(42_000_000)),
      None,
      Some(Some(0)),
      None,
      Some(now_ms - 1_000),
      None,
    )
  pyth_guard.check(
    pyth_guard.new_without_confidence_bound(ada_usd, max_age),
    update(now_ms - 1_000, [bare]),
    window(now_ms - 10_000, now_ms),
  ) == Error(ExponentUnavailable)
}

// ------------------------------------------------------------ replay primitive

/// Compares generation times. A carried-forward price arrives in a stream of
/// new messages that all describe the same reading, and comparing delivery
/// times would let every one of them count as new.
test replay_guard_requires_strict_advancement() {
  let price = sample_price()
  and {
    pyth_guard.newer_than(price, price.generated_us - 1),
    !pyth_guard.newer_than(price, price.generated_us),
    !pyth_guard.newer_than(price, price.generated_us + 1),
  }
}

test replay_guard_ignores_a_moving_delivery_time() {
  // Same price, redelivered a minute later. It is not new.
  let redelivered =
    Price { ..sample_price(), delivered_us: now_us + 60_000_000 }
  !pyth_guard.newer_than(redelivered, now_us)
}

/// The cooldown primitive. Freshness alone lets an adversary pick any signed
/// tick inside the window; a minimum advance caps how often that choice can be
/// exercised against the same position.
test cooldown_requires_a_minimum_advance() {
  let price = sample_price()
  and {
    pyth_guard.newer_by(price, now_us - 30_000_000, 30_000_000),
    !pyth_guard.newer_by(price, now_us - 30_000_000 + 1, 30_000_000),
    !pyth_guard.newer_by(price, now_us, 1),
  }
}

// -------------------------------------------------------------------- scaling

test scales_to_fixed_decimals() {
  let price = sample_price()
  and {
    pyth_guard.scaled(price, 6) == 420_000,
    pyth_guard.scaled(price, 8) == 42_000_000,
    pyth_guard.scaled(price, 10) == 4_200_000_000,
  }
}

/// The two directions disagree wherever the rescale is lossy, which is the
/// entire reason both exist. Rounding a collateral price down brings a
/// liquidation closer; rounding a debt price down pushes it away.
test rounding_direction_is_a_real_choice() {
  let price = Price { ..sample_price(), value: 42_000_001, confidence: 0 }
  and {
    pyth_guard.scaled(price, 6) == 420_000,
    pyth_guard.scaled_up(price, 6) == 420_001,
  }
}

test rounding_directions_agree_when_the_rescale_is_exact() {
  let price = sample_price()
  and {
    pyth_guard.scaled(price, 8) == 42_000_000,
    pyth_guard.scaled_up(price, 8) == 42_000_000,
  }
}

test scaling_up_never_reports_zero_for_a_nonzero_price() {
  let price = sample_price()
  and {
    pyth_guard.scaled(price, 0) == 0,
    pyth_guard.scaled_up(price, 0) == 1,
  }
}

/// A confidence interval wider than the price drives `at_confidence_floor`
/// negative, and that value goes straight into `scaled` in any consumer that
/// prices collateral conservatively. Floor must round toward negative
/// infinity and ceiling toward positive infinity for negatives too, which is
/// the case Plutus' two division builtins disagree on.
test rounding_stays_directional_for_a_negative_mantissa() {
  let underwater =
    Price { ..sample_price(), value: 100, confidence: 150 }
  let floored = pyth_guard.at_confidence_floor(underwater)
  and {
    floored.value == -50,
    pyth_guard.scaled(floored, 6) == -1,
    pyth_guard.scaled_up(floored, 6) == 0,
  }
}

/// `decimals` commonly comes from a datum. An unbounded power of ten is an
/// execution-budget denial of service, so it is bounded. The result is the
/// test's own value, so the call cannot be discarded as unused.
test scaled_rejects_decimals_beyond_the_bound() fail {
  pyth_guard.scaled(sample_price(), pyth_guard.max_decimals + 1) == 0
}

test scaled_rejects_negative_decimals() fail {
  pyth_guard.scaled(sample_price(), -1) == 0
}

// -------------------------------------------------------- confidence interval

test confidence_floor_and_ceiling_bracket_the_price() {
  let price = sample_price()
  and {
    pyth_guard.at_confidence_floor(price).value == 41_983_200,
    pyth_guard.at_confidence_ceiling(price).value == 42_016_800,
    pyth_guard.at_confidence_floor(price).confidence == 0,
    pyth_guard.at_confidence_ceiling(price).confidence == 0,
  }
}

test confidence_floor_composes_with_scaling() {
  pyth_guard.scaled(pyth_guard.at_confidence_floor(sample_price()), 6) == 419_832
}

test confidence_bounds_collapse_when_publishers_agree() {
  let price = Price { ..sample_price(), confidence: 0 }
  and {
    pyth_guard.at_confidence_floor(price).value == 42_000_000,
    pyth_guard.at_confidence_ceiling(price).value == 42_000_000,
  }
}

// ------------------------------------------------------- ordering of rejections

/// A malformed guard is reported before anything is read from the update at
/// all. Pinned so that reordering the checks is a deliberate, visible change:
/// every test above assumes a specific reason wins.
test a_malformed_guard_is_reported_first() {
  pyth_guard.check(
    pyth_guard.new(ada_usd, -1, 50),
    update(now_ms - 3_600_000, [feed_at(17, 1, 0, 1, now_ms - 3_600_000)]),
    window(now_ms - 10_000, now_ms),
  ) == Error(MalformedGuard)
}

/// Feed identity is resolved before the price inside it is judged, so a
/// transaction carrying only somebody else's feed reports the feed as missing
/// rather than complaining about its contents.
test feed_identity_is_reported_before_staleness() {
  pyth_guard.check(
    guard(),
    update(now_ms - 1_000, [feed_at(17, 1, 0, 1, now_ms - 3_600_000)]),
    window(now_ms - 10_000, now_ms),
  ) == Error(FeedMissing)
}
