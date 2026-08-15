//// # pyth_guard
////
//// Safety wrapper around `pyth.get_updates` for Pyth Pro on Cardano.
////
//// The Pyth withdraw script verifies that a price update carries a valid
//// signature. It deliberately does **not** enforce freshness, and it does not
//// prevent the same update being verified many times. Those checks are left to
//// the consuming contract. This module implements them once so that
//// integrators do not each reimplement them.
////
//// ## Two timestamps, and only one of them means "fresh"
////
//// A Lazer message carries `timestamp_us`, the time the *message* was
//// produced, and each feed inside it carries `feed_update_timestamp`, the time
//// that *price* was last generated. They are usually equal and they diverge
//// exactly when it matters: when publishers go quiet or a market closes, Pyth
//// keeps emitting messages that carry the last price forward. Those messages
//// are validly signed and their `timestamp_us` is always current.
////
//// A guard built on `timestamp_us` therefore accepts an arbitrarily old price
//// wearing a fresh envelope — the same failure this library exists to prevent,
//// one level down. Staleness here is measured against `feed_update_timestamp`,
//// which is strictly stronger: a message is never delivered before the price
//// in it was generated, so bounding the generation age bounds the delivery age
//// too.
////
//// ## What is checked
////
//// - **Bounded validity** — a transaction with an open-ended upper bound has
////   no notion of "now", so a freshness check against it would be vacuous.
//// - **Price freshness** — the price was *generated* no more than
////   `max_age_ms` before the transaction deadline.
//// - **Timestamp consistency** — a feed may not claim to have been generated
////   after the message that carried it.
//// - **Not future-dated** — against the deadline by default, which catches
////   accidents; against the ledger-enforced lower bound with
////   `with_strict_future_dating`, which catches intent.
//// - **Feed identity** — exactly one feed, in exactly one update, carries the
////   id that was asked for.
//// - **Confidence width** — required by default; opting out is explicit.
//// - **Market session** — optional, and necessary for anything that is not a
////   24/7 market.
//// - **Publisher count** and **channel** — optional.
////
//// ## What is NOT checked, and cannot be
////
//// - **That `pyth_id` is the real Pyth state policy.** Every guarantee here
////   rests on that one parameter. It must be a compile-time validator
////   parameter, never datum-supplied. See `docs/THREAT_MODEL.md`.
//// - **Replay across transactions.** `newer_than` is a comparison, not a
////   mechanism; the consumer must persist and advance the timestamp. See
////   `validators/price_ratchet.ak`.
//// - **Which price inside the window.** Every signed update whose generation
////   time falls inside `max_age_ms` passes, and the transaction submitter
////   chooses among them. A guard bounds the price to a window; it does not
////   deliver "the current price". `docs/THREAT_MODEL.md` covers what to do
////   about that, and `newer_by` is the primitive for it.
////
//// ## Sizing `max_age_ms`
////
//// `max_age_ms` is not only a staleness tolerance. Because freshness is
//// measured at the transaction deadline, it is also the width of the window in
//// which the transaction must be included in a block — see
//// `docs/INTEGRATION.md`. On Cardano that puts a hard floor under it, well
//// above what "as fresh as possible" would suggest. Squeezing it does not buy
//// safety; it buys expired transactions.
////
//// ## Errors as values
////
//// The primitive is `check`, which returns `Result<Price, Rejection>`. Every
//// rejection has a distinct reason, so a test can assert *why* a price was
//// refused rather than merely that something failed.

use aiken/collection/list
use aiken/interval.{Finite, IntervalBound}
use aiken/math
use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction, ValidityRange}
use pyth.{Feed, MarketSession, PriceUpdate}
use types/u16
use types/u32
use types/u64
use types/u8

/// Constraints a contract places on a price before it is willing to use it.
pub type Guard {
  /// Pyth Pro numeric feed id (e.g. 16 for ADA/USD).
  feed_id: Int,
  /// Maximum age of the *price*, in milliseconds, at the transaction
  /// deadline. Doubles as the transaction's block-inclusion window; see the
  /// module header. Must not be negative.
  max_age_ms: Int,
  /// Ceiling on confidence, in basis points of price. `None` accepts a price
  /// however much its publishers disagree, and is only reachable through
  /// `new_without_confidence_bound`.
  max_confidence_bps: Option<Int>,
  /// Market sessions the contract is willing to price in. `None` accepts any
  /// session, including `Closed`, which is correct only for 24/7 markets.
  allowed_sessions: Option<List<MarketSession>>,
  /// Check future-dating against the validity range's lower bound rather than
  /// its deadline. Stronger, and imposes a transaction-construction
  /// requirement; see `with_strict_future_dating`.
  strict_future_dating: Bool,
  /// Optional expected `channel_id` of the update.
  expected_channel: Option<Int>,
  /// Optional floor on the number of contributing publishers.
  min_publishers: Option<Int>,
}

/// A price that has passed every check in its `Guard`.
pub type Price {
  /// Integer mantissa. The real value is `value * 10^exponent`.
  value: Int,
  exponent: Int,
  /// Confidence in the same units as `value`. Zero means publishers agreed
  /// exactly, which is legitimate and common on liquid feeds.
  confidence: Int,
  /// When this price was **generated**, in microseconds. This is the one to
  /// reason about, to persist, and to compare — see `newer_than`.
  generated_us: Int,
  /// When the message carrying it was produced, in microseconds. Always at or
  /// after `generated_us`. Useful for diagnostics; not a freshness signal.
  delivered_us: Int,
}

/// Why a price was refused. Each variant is reachable by exactly one
/// condition, so tests assert the reason rather than the mere fact of failure.
pub type Rejection {
  /// The transaction has no finite upper validity bound, so "now" is
  /// undefined and freshness cannot be established.
  UnboundedValidity
  /// The `Guard` itself is malformed — a negative age or basis-point bound.
  /// Reachable when a guard is built from an untrusted datum.
  MalformedGuard
  /// No update in the transaction carries the requested feed.
  FeedMissing
  /// More than one update, or more than one feed within an update, carries
  /// the requested feed id. There is no principled way to choose between
  /// them and the transaction author chose the set.
  AmbiguousFeed
  /// The price was generated more than `max_age_ms` before the deadline.
  Stale
  /// The feed carries no generation timestamp, so its age is unknown. Fails
  /// closed: subscribe to the `feedUpdateTimestamp` property.
  GenerationTimeUnavailable
  /// The feed claims to have been generated after the message carrying it.
  InconsistentTimestamps
  /// The message is dated after the latest instant the ledger could have
  /// accepted the transaction.
  FutureDated
  /// `channel_id` does not match `expected_channel`.
  WrongChannel
  /// The market session is not one this contract prices in.
  SessionNotAllowed
  /// A session constraint is set but the update carries no session.
  SessionUnavailable
  /// The price property is absent from the update, or is zero.
  PriceUnavailable
  /// The exponent property is absent from the update.
  ExponentUnavailable
  /// The price mantissa is zero or negative.
  NonPositivePrice
  /// A confidence bound is required but the update carries no confidence
  /// property, so the bound cannot be checked.
  ConfidenceUnavailable
  /// Confidence exceeds `max_confidence_bps` of the price.
  ConfidenceTooWide
  /// A publisher floor is required but the update carries no publisher count.
  PublisherCountUnavailable
  /// Fewer contributing publishers than `min_publishers`.
  TooFewPublishers
}

/// Largest `decimals` argument `scaled` will accept. Bounds the cost of the
/// power-of-ten it computes, which matters because `decimals` frequently
/// originates in a datum rather than in the validator's own source.
pub const max_decimals: Int = 32

// ---------------------------------------------------------------- construction

/// A guard requiring price freshness and a confidence bound.
///
/// Both are mandatory because the failure mode of omitting the confidence
/// bound is silent: the contract keeps working, and simply accepts prices
/// during exactly the market conditions where publishers stop agreeing.
///
/// For anything that is not a 24/7 market, add `with_sessions`.
pub fn new(feed_id: Int, max_age_ms: Int, max_confidence_bps: Int) -> Guard {
  Guard {
    feed_id,
    max_age_ms,
    max_confidence_bps: Some(max_confidence_bps),
    allowed_sessions: None,
    strict_future_dating: False,
    expected_channel: None,
    min_publishers: None,
  }
}

/// A guard that accepts a price no matter how widely its publishers disagree.
///
/// Deliberately long to type. It is the right choice when a contract consumes
/// the confidence interval itself — see `at_confidence_floor` and
/// `at_confidence_ceiling` — and therefore does not need a threshold on top of
/// it. It is the wrong choice everywhere else.
pub fn new_without_confidence_bound(feed_id: Int, max_age_ms: Int) -> Guard {
  Guard {
    feed_id,
    max_age_ms,
    max_confidence_bps: None,
    allowed_sessions: None,
    strict_future_dating: False,
    expected_channel: None,
    min_publishers: None,
  }
}

/// Tighten (or loosen) the confidence bound on an existing guard.
pub fn with_confidence_bps(self: Guard, bps: Int) -> Guard {
  Guard { ..self, max_confidence_bps: Some(bps) }
}

/// Restrict which market sessions the contract will price in.
///
/// Required for equities, FX, commodities — anything with trading hours. Pyth
/// keeps delivering a feed when its market is shut, and a carried-forward
/// price out of hours is not a price anyone can trade against. Passing
/// `[Regular]` is the conservative choice.
pub fn with_sessions(self: Guard, sessions: List<MarketSession>) -> Guard {
  Guard { ..self, allowed_sessions: Some(sessions) }
}

/// Check future-dating against the validity range's *lower* bound instead of
/// its deadline.
///
/// The deadline is chosen freely by whoever builds the transaction, so
/// comparing an update's timestamp against it only catches accidents: for any
/// update claiming a future time T, the builder simply sets the deadline to T
/// and the check passes. The lower bound is different — the ledger will not
/// include the transaction before it — so an update timestamped at or before
/// it genuinely predates inclusion.
///
/// Opt-in because it constrains how the transaction must be built: the
/// builder has to set `invalid_before` to at least the update's own timestamp
/// in milliseconds. That is one line, and it is good practice anyway, but a
/// contract that enables this without telling its off-chain side will reject
/// perfectly good prices. Enable it together with the builder change, not
/// before.
pub fn with_strict_future_dating(self: Guard) -> Guard {
  Guard { ..self, strict_future_dating: True }
}

/// Require the update to have arrived on a specific delivery channel.
pub fn with_channel(self: Guard, channel_id: Int) -> Guard {
  Guard { ..self, expected_channel: Some(channel_id) }
}

/// Require at least `n` publishers to have contributed to the price.
pub fn with_min_publishers(self: Guard, n: Int) -> Guard {
  Guard { ..self, min_publishers: Some(n) }
}

// --------------------------------------------------------------------- reading

/// Read the guarded price out of the transaction, failing the transaction if
/// no acceptable price is present.
///
/// `pyth_id` must be the policy id of the genuine Pyth state NFT for the
/// network being deployed to, and must be a validator parameter baked into the
/// script hash. Everything this library guarantees is conditional on that, and
/// it cannot be checked from inside the script: a `pyth_id` the attacker
/// chooses lets them supply their own state UTxO and their own withdraw
/// script, at which point no signature is verified anywhere in the
/// transaction.
pub fn read(guard: Guard, pyth_id: PolicyId, self: Transaction) -> Price {
  unwrap(try_read(guard, pyth_id, self))
}

/// `read` as a `Result`, for contracts that want to take a different branch
/// rather than fail when no acceptable price is available.
pub fn try_read(
  guard: Guard,
  pyth_id: PolicyId,
  self: Transaction,
) -> Result<Price, Rejection> {
  select(guard, pyth.get_updates(pyth_id, self), self.validity_range)
}

/// Pick the guarded price out of a list of updates.
///
/// Upstream `get_updates` returns a list, because the withdraw script's
/// redeemer is a list of signed messages and several protocols may share one
/// transaction. Updates that do not mention our feed belong to some other
/// consumer and are none of our business. Requiring exactly one update that
/// *does* mention it keeps that batching possible while refusing to guess when
/// two updates disagree about the same feed — a choice the transaction author
/// would otherwise be making on our behalf.
///
/// Split out from `try_read` so the selection rule is testable without
/// constructing a `Transaction`, a Pyth state reference input and a withdrawal
/// redeemer.
pub fn select(
  guard: Guard,
  updates: List<PriceUpdate>,
  range: ValidityRange,
) -> Result<Price, Rejection> {
  when bounds(range) is {
    None -> Error(UnboundedValidity)
    Some((deadline, earliest_ms)) -> {
      let carrying =
        list.filter(
          updates,
          fn(update) { count_feed(update.feeds, guard.feed_id) > 0 },
        )
      when carrying is {
        [] -> Error(FeedMissing)
        [update] -> check_at(guard, update, deadline, earliest_ms)
        _ -> Error(AmbiguousFeed)
      }
    }
  }
}

/// Validate an update already in hand against a validity range.
pub fn validate(guard: Guard, update: PriceUpdate, range: ValidityRange) -> Price {
  unwrap(check(guard, update, range))
}

/// `validate` as a `Result`. This is the primitive; everything else wraps it.
pub fn check(
  guard: Guard,
  update: PriceUpdate,
  range: ValidityRange,
) -> Result<Price, Rejection> {
  when bounds(range) is {
    None -> Error(UnboundedValidity)
    Some((deadline, earliest_ms)) -> check_at(guard, update, deadline, earliest_ms)
  }
}

// -------------------------------------------------------------------- checking

fn check_at(
  guard: Guard,
  update: PriceUpdate,
  deadline_us: Int,
  earliest_ms: Option<Int>,
) -> Result<Price, Rejection> {
  let delivered_us = u64.as_int(update.timestamp_us)

  if guard.max_age_ms < 0 || bad_bps(guard) {
    Error(MalformedGuard)
  } else if future_dated(guard, delivered_us, deadline_us, earliest_ms) {
    Error(FutureDated)
  } else if !channel_ok(guard, update) {
    Error(WrongChannel)
  } else {
    when find_feed(update.feeds, guard.feed_id) is {
      Error(reason) -> Error(reason)
      Ok(feed) -> {
        when generation_time(feed) is {
          Error(reason) -> Error(reason)
          Ok(generated_us) ->
            if generated_us > delivered_us {
              // A price cannot have been produced after the message that
              // carried it. Either the payload is inconsistent or we have
              // misread the encoding; neither is a thing to price against.
              Error(InconsistentTimestamps)
            } else if generated_us + guard.max_age_ms * 1000 < deadline_us {
              // The ledger accepts this transaction at some point at or
              // before the deadline, so requiring freshness *at* the deadline
              // holds for every moment it could actually be included.
              // Shrinking the deadline cannot weaken this: a deadline already
              // past makes the transaction unacceptable to the ledger.
              //
              // Measured on the generation time, not the delivery time. Both
              // sides are microseconds, and nothing is divided.
              Error(Stale)
            } else {
              when session_ok(guard, feed) is {
                Error(reason) -> Error(reason)
                Ok(_) -> extract(guard, feed, generated_us, delivered_us)
              }
            }
        }
      }
    }
  }
}

/// Is the message dated later than the ledger could possibly have accepted it?
///
/// The baseline comparison is against the deadline, which catches accidents
/// but not intent: the deadline is chosen by whoever builds the transaction.
/// With `with_strict_future_dating` the comparison is made against the
/// validity range's lower bound as well, which the ledger does enforce.
///
/// The strict comparison is made in milliseconds because the lower bound is a
/// millisecond quantity: a builder setting `invalid_before` to the update's
/// own timestamp necessarily rounds down, and comparing microseconds against
/// that rounded value would reject a correctly built transaction by up to
/// 999 us.
fn future_dated(
  guard: Guard,
  delivered_us: Int,
  deadline_us: Int,
  earliest_ms: Option<Int>,
) -> Bool {
  if delivered_us > deadline_us {
    True
  } else if guard.strict_future_dating {
    when earliest_ms is {
      Some(earliest) -> delivered_us / 1000 > earliest
      None -> False
    }
  } else {
    False
  }
}

fn generation_time(feed: Feed) -> Result<Int, Rejection> {
  when feed.feed_update_timestamp is {
    // Fails closed. A consumer that has not subscribed to the
    // `feedUpdateTimestamp` property cannot establish price freshness at all,
    // and silently falling back to the message timestamp would reintroduce
    // exactly the defect this check exists to close.
    None -> Error(GenerationTimeUnavailable)
    Some(None) -> Error(GenerationTimeUnavailable)
    Some(Some(t)) -> Ok(u64.as_int(t))
  }
}

fn session_ok(guard: Guard, feed: Feed) -> Result<Void, Rejection> {
  when guard.allowed_sessions is {
    None -> Ok(Void)
    Some(allowed) ->
      when feed.market_session is {
        None -> Error(SessionUnavailable)
        Some(session) ->
          if list.has(allowed, session) {
            Ok(Void)
          } else {
            Error(SessionNotAllowed)
          }
      }
  }
}

fn extract(
  guard: Guard,
  feed: Feed,
  generated_us: Int,
  delivered_us: Int,
) -> Result<Price, Rejection> {
  // The wire format encodes value-carrying properties twice-optionally: the
  // outer `Option` means "was this property part of the subscription", the
  // inner one means "was the value non-zero". `exponent` and `publisher_count`
  // carry no non-zero constraint upstream and so are singly optional. Getting
  // this wrong in either direction is a real bug: reading `confidence` as
  // singly optional rejects the tightest prices Pyth can publish, because
  // perfectly agreeing publishers arrive as `Some(None)`.
  when feed.price is {
    None -> Error(PriceUnavailable)
    Some(None) -> Error(PriceUnavailable)
    Some(Some(value)) ->
      if value <= 0 {
        // Narrower than the wire domain, which is a signed non-zero i64.
        // Negative-quoting feeds (energy futures, calendar spreads, policy
        // rates) are out of scope, and `confidence_of` below relies on this
        // sign to compare against a basis-point bound.
        Error(NonPositivePrice)
      } else {
        when feed.exponent is {
          None -> Error(ExponentUnavailable)
          Some(exponent) ->
            when confidence_of(guard, feed, value) is {
              Error(reason) -> Error(reason)
              Ok(confidence) ->
                when publishers_ok(guard, feed) is {
                  Error(reason) -> Error(reason)
                  Ok(_) ->
                    Ok(
                      Price {
                        value,
                        exponent,
                        confidence,
                        generated_us,
                        delivered_us,
                      },
                    )
                }
            }
        }
      }
  }
}

fn confidence_of(guard: Guard, feed: Feed, value: Int) -> Result<Int, Rejection> {
  when guard.max_confidence_bps is {
    None ->
      when feed.confidence is {
        None -> Ok(0)
        Some(None) -> Ok(0)
        Some(Some(c)) -> Ok(c)
      }
    Some(bps) ->
      when feed.confidence is {
        // A bound was required and the update cannot support checking it.
        // Treating an unsubscribed property as zero confidence would turn
        // "we did not ask" into "the publishers agreed exactly".
        None -> Error(ConfidenceUnavailable)
        Some(None) -> Ok(0)
        Some(Some(c)) ->
          if c < 0 {
            Error(ConfidenceTooWide)
          } else if c * 10_000 <= value * bps {
            Ok(c)
          } else {
            Error(ConfidenceTooWide)
          }
      }
  }
}

fn publishers_ok(guard: Guard, feed: Feed) -> Result<Void, Rejection> {
  when guard.min_publishers is {
    None -> Ok(Void)
    Some(floor) ->
      when feed.publisher_count is {
        None -> Error(PublisherCountUnavailable)
        Some(count) ->
          if u16.as_int(count) >= floor {
            Ok(Void)
          } else {
            Error(TooFewPublishers)
          }
      }
  }
}

fn find_feed(feeds: List<Feed>, feed_id: Int) -> Result<Feed, Rejection> {
  // `list.find` would take the first match. If an update ever carried the same
  // feed id twice, "the first one" is not a decision this library should make
  // silently.
  when list.filter(feeds, fn(f) { u32.as_int(f.feed_id) == feed_id }) is {
    [] -> Error(FeedMissing)
    [feed] -> Ok(feed)
    _ -> Error(AmbiguousFeed)
  }
}

fn count_feed(feeds: List<Feed>, feed_id: Int) -> Int {
  list.length(list.filter(feeds, fn(f) { u32.as_int(f.feed_id) == feed_id }))
}

fn channel_ok(guard: Guard, update: PriceUpdate) -> Bool {
  when guard.expected_channel is {
    None -> True
    Some(expected) -> u8.as_int(update.channel_id) == expected
  }
}

fn bad_bps(guard: Guard) -> Bool {
  when guard.max_confidence_bps is {
    None -> False
    Some(bps) -> bps < 0
  }
}

/// The deadline and the earliest acceptable instant, both in **microseconds**.
///
/// The deadline is in microseconds; the earliest instant is in
/// **milliseconds**, unconverted, because that is the unit the future-dating
/// check compares in. `None` overall when the upper bound is not finite:
/// freshness relative to an open-ended range is meaningless. The second
/// element is `None` when the lower bound is open.
///
/// The ledger's `ttl` is an exclusive upper bound and reaches the script
/// context as `is_inclusive: False`, so the last acceptable instant is one
/// millisecond earlier. `interval.between` — which is what tests are built
/// from — produces inclusive bounds instead. Both paths are exercised in the
/// test suite because they are genuinely different code.
fn bounds(range: ValidityRange) -> Option<(Int, Option<Int>)> {
  let IntervalBound { bound_type, is_inclusive } = range.upper_bound
  when bound_type is {
    Finite(upper) -> {
      let deadline_us =
        if is_inclusive {
          upper * 1000
        } else {
          ( upper - 1 ) * 1000
        }
      Some((deadline_us, lower_bound_ms(range)))
    }
    _ -> None
  }
}

fn lower_bound_ms(range: ValidityRange) -> Option<Int> {
  let IntervalBound { bound_type, is_inclusive } = range.lower_bound
  when bound_type is {
    Finite(lower) ->
      Some(
        if is_inclusive {
          lower
        } else {
          lower + 1
        },
      )
    _ -> None
  }
}

fn unwrap(result: Result<Price, Rejection>) -> Price {
  // The messages cost nothing in a production build: `aiken build` erases
  // them unless tracing is explicitly enabled. During `aiken check` they turn
  // a bare script failure into a diagnosis.
  when result is {
    Ok(price) -> price
    Error(UnboundedValidity) ->
      fail @"pyth_guard: transaction has no finite upper validity bound"
    Error(MalformedGuard) ->
      fail @"pyth_guard: guard has a negative max_age_ms or max_confidence_bps"
    Error(FeedMissing) -> fail @"pyth_guard: requested feed is not in the update"
    Error(AmbiguousFeed) ->
      fail @"pyth_guard: requested feed appears more than once"
    Error(Stale) ->
      fail @"pyth_guard: price was generated more than max_age_ms before the deadline"
    Error(GenerationTimeUnavailable) ->
      fail @"pyth_guard: feed carries no feedUpdateTimestamp; subscribe to that property"
    Error(InconsistentTimestamps) ->
      fail @"pyth_guard: feed claims to predate the message carrying it"
    Error(FutureDated) -> fail @"pyth_guard: update is dated after the deadline"
    Error(WrongChannel) -> fail @"pyth_guard: update arrived on an unexpected channel"
    Error(SessionNotAllowed) ->
      fail @"pyth_guard: market session is not one this contract prices in"
    Error(SessionUnavailable) ->
      fail @"pyth_guard: session constraint set but update carries no market session"
    Error(PriceUnavailable) -> fail @"pyth_guard: update carries no price for this feed"
    Error(ExponentUnavailable) -> fail @"pyth_guard: update carries no exponent"
    Error(NonPositivePrice) -> fail @"pyth_guard: price mantissa is zero or negative"
    Error(ConfidenceUnavailable) ->
      fail @"pyth_guard: confidence bound required but update carries no confidence"
    Error(ConfidenceTooWide) ->
      fail @"pyth_guard: confidence exceeds max_confidence_bps of price"
    Error(PublisherCountUnavailable) ->
      fail @"pyth_guard: publisher floor required but update carries no publisher count"
    Error(TooFewPublishers) -> fail @"pyth_guard: too few contributing publishers"
  }
}

// --------------------------------------------------------------------- using

/// Replay guard: has the price actually moved on since `last_seen_us`?
///
/// Compares generation times, not delivery times. A carried-forward price
/// arrives in a stream of new messages that all describe the same reading, and
/// comparing delivery times would let every one of them count as new.
///
/// This is a comparison, not a mechanism. It protects nothing unless the
/// consumer also **writes the new timestamp back** into the state it will read
/// next time. A contract that checks `newer_than` against a datum it never
/// updates has no replay protection at all. `validators/price_ratchet.ak`
/// demonstrates the complete pattern.
///
/// Note what it does *not* bound: every signed update inside the freshness
/// window has a distinct, increasing generation time, so this accepts all of
/// them and the transaction submitter picks. Use `newer_by` where that matters.
pub fn newer_than(price: Price, last_seen_us: Int) -> Bool {
  price.generated_us > last_seen_us
}

/// `newer_than` with a minimum advance — a per-position cooldown.
///
/// Freshness alone bounds the price to a `max_age_ms`-wide window, and inside
/// that window an adversary presents whichever signed tick suits them: the
/// low print of the last minute to trigger a liquidation, say. Requiring a
/// minimum advance between the updates a position is acted on caps how often
/// that choice can be exercised against the same position, which is the part
/// a price check cannot do on its own.
pub fn newer_by(price: Price, last_seen_us: Int, min_advance_us: Int) -> Bool {
  price.generated_us >= last_seen_us + min_advance_us
}

/// Rescale a price to a fixed number of decimal places, **rounding down**
/// (toward negative infinity).
///
/// Which way to round is a decision only the consumer can make, and it is not
/// a rounding-error-sized decision: rounding a collateral price down brings a
/// liquidation closer, and rounding a debt price down pushes it away. Pick the
/// direction that costs an attacker money rather than the one that costs you
/// money, and use `scaled_up` where that is the other way round.
///
/// Fails if `decimals` is negative or exceeds `max_decimals`, or if the
/// combined shift leaves that range. `decimals` is often datum-supplied, and
/// an unbounded power of ten is an execution-budget denial of service.
pub fn scaled(price: Price, decimals: Int) -> Int {
  let shift = checked_shift(price, decimals)
  if shift >= 0 {
    price.value * math.pow(10, shift)
  } else {
    div_floor(price.value, math.pow(10, -shift))
  }
}

/// `scaled`, **rounding up** (toward positive infinity).
pub fn scaled_up(price: Price, decimals: Int) -> Int {
  let shift = checked_shift(price, decimals)
  if shift >= 0 {
    price.value * math.pow(10, shift)
  } else {
    div_ceil(price.value, math.pow(10, -shift))
  }
}

/// The low end of the confidence interval, as a `Price` that scales and
/// compares like any other.
///
/// Use where an over-estimate of the price favours an attacker: valuing
/// collateral, sizing a payout, deciding a position is still solvent. A wide
/// enough confidence interval drives this to zero or below — the honest answer
/// when publishers disagree that much, and the reason to keep a
/// `max_confidence_bps` bound in place as well. `scaled` and `scaled_up` stay
/// correct for such a value; see `div_floor`.
pub fn at_confidence_floor(price: Price) -> Price {
  Price { ..price, value: price.value - price.confidence, confidence: 0 }
}

/// The high end of the confidence interval, as a `Price`.
///
/// Use where an under-estimate favours an attacker: valuing debt, sizing a
/// margin requirement, deciding a position is *not* yet liquidatable.
pub fn at_confidence_ceiling(price: Price) -> Price {
  Price { ..price, value: price.value + price.confidence, confidence: 0 }
}

fn checked_shift(price: Price, decimals: Int) -> Int {
  expect decimals >= 0 && decimals <= max_decimals
  let shift = price.exponent + decimals
  expect shift >= -max_decimals && shift <= max_decimals
  shift
}

/// Floor division, spelled out.
///
/// `check` guarantees a positive mantissa, but `at_confidence_floor` can hand
/// back a negative one, and for negative operands the two candidate builtins
/// (`divideInteger`, which floors, and `quotientInteger`, which truncates)
/// disagree. Rather than depend on which one `/` lowers to, both helpers keep
/// the operands non-negative and place the sign themselves.
fn div_floor(numerator: Int, denominator: Int) -> Int {
  if numerator >= 0 {
    numerator / denominator
  } else {
    -( ( -numerator + denominator - 1 ) / denominator )
  }
}

/// Ceiling division, spelled out. See `div_floor`.
fn div_ceil(numerator: Int, denominator: Int) -> Int {
  if numerator >= 0 {
    ( numerator + denominator - 1 ) / denominator
  } else {
    -( -numerator / denominator )
  }
}
