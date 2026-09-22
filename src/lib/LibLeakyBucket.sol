// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {LibSaturatingMath} from "rain-math-saturating-0.1.10/src/lib/LibSaturatingMath.sol";

/// @dev Thrown when a fill would push the bucket past its capacity. Carries
/// everything needed to explain the rejection without a second call: the
/// capacity that was in force, the level the bucket had already leaked down to
/// at the time of the attempt, and the amount that did not fit.
/// @param capacity The bucket capacity in force for the rejected fill.
/// @param level The bucket level at the time of the attempt, i.e. after the
/// leak accrued since the checkpoint was applied.
/// @param amount The amount that was offered and did not fit.
error LeakyBucketCapacityExceeded(uint256 capacity, uint256 level, uint256 amount);

/// @dev Thrown when the capacity in force is above
/// `LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX`, which is a level this library
/// cannot store and therefore a cap it cannot enforce. It is a
/// misconfiguration rather than a condition to handle at the call site, and it
/// is named as one: the alternative is `headroomAt` reporting room that `fill`
/// will not take, and the rejection then naming the packing width instead of
/// the parameter that is actually wrong.
/// @param capacity The capacity that cannot be enforced.
error LeakyBucketCapacityOverflow(uint256 capacity);

/// @dev Thrown when a timestamp does not fit the packed field, which makes it a
/// second this library cannot record and therefore one `fill` can never act at.
/// Like `LeakyBucketCapacityOverflow` it names the argument that is wrong
/// rather than the width that rejected it.
/// @param timestamp The timestamp that did not fit.
error LeakyBucketTimestampOverflow(uint256 timestamp);

/// @title LibLeakyBucket
/// @notice A leaky bucket meter over one 256 bit word of caller-held state.
///
/// The bucket holds a `level`. Filling adds to the level and is rejected if the
/// level would pass `capacity`. The level leaks away continuously at `leakRate`
/// units per second and stops at zero. Nothing else happens. Capping mints on a
/// token is the motivating case: `amount` is the mint, `capacity` is the
/// largest burst that is ever allowed to land at once, and `leakRate` is the
/// sustained rate the cap converges to over a long enough horizon.
///
/// Two numbers describe the whole policy:
///
/// - `capacity`, the burst. The most that can be minted in a single block, and
///   the most that can ever be outstanding against the cap at one instant.
/// - `leakRate`, the sustained rate, in units per second.
///
/// ## The surface is one function
///
/// `fill` is the product. It takes the packed checkpoint a caller has stored,
/// a clock, the policy pair and an amount, and it either reverts or returns the
/// word to store back. `headroomAt` is the only other entry point and it exists
/// for one reason, written into its own NatSpec.
///
/// Everything else here is `private`, because everything else here is a step of
/// `fill` rather than a thing to call. Every exported symbol is surface an
/// auditor has to read and a caller can misuse, on a library whose entire
/// purpose is to be what a compromised minter cannot get past, so the default
/// is that it is not exported.
///
/// ## Before a fill, and after it
///
/// The burst is the security-critical constraint, and the two sides of a fill
/// are deliberately not symmetric.
///
/// Before a fill, the burst is capped at `capacity`, always. However long the
/// bucket has sat untouched, the most a single fill can take is one `capacity`.
/// Elapsed time cannot enlarge a burst: the leak credited is
/// `min(level, elapsed * leakRate)`, bounded by the level, which is bounded by
/// `capacity`, and the level saturates at zero rather than going negative, so
/// idling banks no credit. Idle for an hour or a decade, the answer is one
/// `capacity`, never more.
///
/// Immediately after a fill consumes the bucket it is zero, at that same
/// second, not at the next block and not partially.
///
/// It then refills by leaking, up to `capacity` and no further, because the
/// level cannot pass `capacity`. So the next burst is capped exactly as the
/// first was.
///
/// In one line: no burst, at any point in the bucket's history, can exceed
/// `capacity`. What `leakRate` controls is how often a burst can be repeated,
/// never how large one can be. Sizing `capacity` is therefore a security
/// decision rather than a convenience: it is the most a minter can take in one
/// go if it is compromised at the worst moment, so it has to be survivable on
/// its own.
///
/// ## State is the caller's
///
/// Every function here is `pure` and takes the bucket state as an argument. The
/// library owns no storage, no slot, no mapping, no owner, no initializer and
/// no upgrade hook. A concrete contract holds the one word wherever it likes,
/// under whatever key it likes, and supplies `capacity` and `leakRate` from
/// wherever its governance puts them: immutables, a timelocked setter, a multi
/// stage upgrade, or a per minter mapping with a different pair per minter. The
/// library never sees any of that and cannot constrain it.
///
/// The state is one word: the level in the high 192 bits and the timestamp that
/// level was recorded at in the low 64. Both fields are read with a shift or a
/// mask and no keccak, so the whole hot path of a capped mint is: load one
/// word, one multiply for the leak, one compare against capacity, store one
/// word.
///
/// The packing is not a convenience. `fill` computes a level that belongs to
/// the second it was evaluated at, and storing that level while leaving an
/// older timestamp in place credits the same leak again on the next call, which
/// quietly stops the cap binding. It is a one line mistake with no symptom
/// until it is exploited, which is the worst shape a bug in a mint cap can
/// have. Here the two are one word, `fill` returns that word, and the only
/// thing a caller can do with it is write it back whole. The failure mode is
/// removed rather than documented.
///
/// ```solidity
/// // One bucket per minter, each with its own policy, governed however the
/// // concrete likes.
/// mapping(address minter => uint256 checkpoint) internal sBuckets;
/// mapping(address minter => uint256 capacity) internal sCapacity;
/// mapping(address minter => uint256 leakRate) internal sLeakRate;
///
/// function mint(address to, uint256 amount) external {
///     sBuckets[msg.sender] = LibLeakyBucket.fill(
///         sBuckets[msg.sender], block.timestamp, sCapacity[msg.sender], sLeakRate[msg.sender], amount
///     );
///     _mint(to, amount);
/// }
/// ```
///
/// A zero word is a valid initial state and means an empty bucket checkpointed
/// at the epoch. No initializer is needed: an untouched slot is a bucket that
/// has been empty since before the chain existed, which is exactly what it
/// should be.
///
/// The same identity is a hazard on the way out, and the library cannot see the
/// difference: a slot that is *cleared* reads identically to one that was never
/// used. `delete` on a bucket is not cleanup, it is a full refund of whatever
/// was outstanding, granted at that instant. A concrete that tidies up after a
/// revoked minter with `delete sBuckets[minter]`, and later grants that address
/// the role again, has handed it a fresh `capacity` that no elapsed time paid
/// for. Re-keying buckets in a storage migration does the same thing. The
/// per-burst bound this library enforces is per slot, so anything that resets a
/// slot resets the bound with it: leave a retired bucket where it is (it costs
/// nothing, and it leaks down on its own), and carry the word across verbatim
/// when state has to move.
///
/// ## Seconds, not blocks
///
/// Time is `block.timestamp` in seconds, passed in as `timestamp`. Block
/// numbers are not used anywhere. Block times differ by an order of magnitude
/// across chains and change under the same chain over time, so a cap expressed
/// in blocks is a different cap on every deployment and silently becomes a
/// different cap after a hard fork. A rate in units per second means the same
/// thing everywhere, which is what makes the same `capacity` and `leakRate`
/// deployable unchanged on any EVM chain.
///
/// `leakRate` is per second and nothing here converts to it. A policy written
/// as "X per day" is `X / 1 days`, computed by the caller, in the caller's own
/// units, in front of whoever signs the policy off. A conversion helper in here
/// would be a division with a rounding direction sitting in an audited security
/// library: approve "100 per day", have it silently floor, and the enforced cap
/// is not the number that was approved.
///
/// ## Arithmetic
///
/// Every operation that could leave the representable range is a saturating one
/// from `LibSaturatingMath`, which is audited and carries the same licence as
/// this library. There is no hand rolled overflow guard here to review.
///
/// The property the saturation directions buy is that no read here ever reports
/// MORE headroom than the bucket really has. Three of the four are exact, in
/// that the saturated answer IS the true answer rather than an approximation of
/// it, and the fourth is strictly conservative.
///
/// "Saturate rather than wrap" is not itself that property, and reading it as a
/// rule of thumb is how a fail open gets written here. For the first two below
/// the wrapping alternative would be the TIGHTER cap and the saturation is the
/// permissive direction; what makes those two safe is that the saturated value
/// is exactly right, not the direction it moves in.
///
/// - The leak saturates the multiply at the top of the word. Exact: a product
///   that overflows the word already exceeds every representable `level`, so
///   the true level is zero and the saturated subtract returns zero. Taken on
///   its own this moves the permissive way, since a larger leak is a lower
///   level is more headroom, and it is sound only while "the product
///   overflowed" implies "the leak exceeds the level". Scaling the product, or
///   holding the level in fewer than 256 bits while computing the product in
///   256, breaks that implication and turns this saturation into a free
///   capacity.
/// - The leak saturates the subtract at zero. Exact: a bucket stops at empty by
///   definition, so it cannot drain past empty and cannot underflow into a huge
///   level.
/// - Elapsed time saturates at zero, so a clock at or behind the checkpoint
///   credits no leak at all rather than wrapping to billions of years of it.
///   Conservative: it reports a level at or above the true one, hence a tighter
///   cap, and the wrap it replaces would have drained the bucket outright.
/// - Headroom saturates at zero. Exact: nothing fits in a bucket that is over
///   its capacity, and the underflow it replaces would be an enormous
///   allowance.
///
/// ## Leak is credited from the checkpoint, exactly
///
/// The leak is `elapsed * leakRate`, computed from the checkpoint in one
/// multiply. It is not accrued per call and not derived by dividing a capacity
/// by a window, so checkpointing more often cannot change the result: a fill
/// split in two at an intermediate second lands on exactly the level one fill
/// would have, at every input, with no rounding slack, and it is fuzzed.
///
/// It is worth stating because the common alternative does not have it.
/// Implementations that store a `window` and leak at `capacity / window` per
/// second take a floor division on every checkpoint, so each call throws away
/// the sub unit remainder, and a caller touching the bucket every second is
/// credited measurably less leak than a caller touching it once an hour. That
/// turns call frequency into part of the cap. Here the rate is a parameter
/// rather than a quotient and the checkpoint is a subtraction from the
/// original, so there is no per call remainder to lose and frequency is not
/// observable in the result.
library LibLeakyBucket {
    /// @dev Bits the timestamp occupies in a packed checkpoint, in the low end
    /// of the word.
    ///
    /// The one free parameter of the layout. Both maxima below are derived from
    /// it rather than spelled independently, so changing it moves the whole
    /// layout coherently instead of leaving two literals to be re-derived by
    /// hand.
    uint256 private constant LEAKY_BUCKET_TIMESTAMP_BITS = 64;

    /// @dev Largest timestamp a packed checkpoint can hold, in seconds. Around
    /// 5.8e11 years, so it is not a deadline in any sense that needs managing;
    /// it exists so the width is stated rather than assumed.
    ///
    /// Derived rather than spelled, because it is also the mask `unpack`
    /// applies: every bit below `LEAKY_BUCKET_TIMESTAMP_BITS` and nothing above
    /// it. Written as `type(uint64).max` it is correct only while the width
    /// happens to be 64, and a maintainer narrowing the width would get a mask
    /// wider than the field, which reads level bits back as part of the
    /// timestamp.
    ///
    /// The `uint256(1)` is load bearing rather than noise: a bare `1` on the
    /// left of the shift trips `forge lint`'s `incorrect-shift` rule, and the
    /// CI gate runs it with `-D warnings`. It also states the word the shift
    /// happens in, which is the whole point of the constant.
    uint256 private constant LEAKY_BUCKET_TIMESTAMP_MAX = (uint256(1) << LEAKY_BUCKET_TIMESTAMP_BITS) - 1;

    /// @dev Largest level a checkpoint can hold, and therefore the largest
    /// `capacity` this library can enforce. Around 6.2e57, which is 6.2e39
    /// whole tokens at eighteen decimals.
    ///
    /// The one constant that is exported, and it is exported because a caller
    /// cannot reject an unenforceable capacity without it. `fill` refuses a
    /// capacity above this with `LeakyBucketCapacityOverflow`, but a mint cap
    /// finds that out at the first mint, from whoever is unlucky enough to be
    /// minting when the misconfigured policy first binds. The moment the
    /// capacity is *set* is the only point at which it can be fixed rather than
    /// merely detected, and a governance setter refuses it there with
    ///
    /// ```solidity
    /// if (capacity > LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX) {
    ///     revert LeakyBucketCapacityOverflow(capacity);
    /// }
    /// ```
    ///
    /// Derived, like the timestamp maximum: the level field is exactly the word
    /// less the timestamp field, so `pack`'s `unchecked` shift can neither
    /// truncate a level this bound permits nor reach a timestamp bit. Written
    /// as `type(uint192).max` it is correct only while the width happens to be
    /// 64, and a maintainer widening the width would get a bound whose shifted
    /// value overflows the word, so `pack` would silently truncate the level it
    /// just accepted.
    uint256 internal constant LEAKY_BUCKET_LEVEL_MAX = type(uint256).max >> LEAKY_BUCKET_TIMESTAMP_BITS;

    /// Level remaining after leaking for `elapsed` seconds at `leakRate` units
    /// per second. Saturates at zero: a bucket cannot leak past empty.
    ///
    /// The whole leak is a saturating multiply feeding a saturating subtract.
    /// An overflowing `elapsed * leakRate` is not an error, it is a leak larger
    /// than any level that could ever be represented, which is a bucket that is
    /// empty, and saturating the product at the top of the word then subtracting
    /// it is exactly that answer.
    /// @param level The level at the start of the interval.
    /// @param elapsed The length of the interval in seconds.
    /// @param leakRate The leak in units per second.
    /// @return The level at the end of the interval.
    function leak(uint256 level, uint256 elapsed, uint256 leakRate) private pure returns (uint256) {
        return LibSaturatingMath.saturatingSub(level, LibSaturatingMath.saturatingMul(elapsed, leakRate));
    }

    /// Level of a bucket checkpointed at `(level, checkpoint)`, as at
    /// `timestamp`.
    ///
    /// A `timestamp` at or before `checkpoint` credits no leak at all, because
    /// the elapsed time saturates at zero. The bucket reads as though no time
    /// has passed rather than reverting or treating the difference as an
    /// unsigned wrap. Reverting would let a clock that steps backwards brick
    /// minting until it caught up, and wrapping would read as a leak of
    /// billions of years and empty the bucket outright. Crediting nothing is
    /// the only one of the three that is conservative in the direction that
    /// matters: it can only ever report a level at or above the true level, so
    /// it can only ever hand out less headroom than reality, never more.
    ///
    /// That is a property of the read, and keeping it takes one thing of the
    /// write: a stored checkpoint must never move backwards. Crediting no leak
    /// for a backwards step and then recording the earlier second leaves the
    /// same interval to be measured again on the next read, which pays out
    /// exactly the headroom this saturation just refused. `fill` keeps the
    /// later of the supplied time and the stored one for that reason.
    /// @param level The level recorded at the checkpoint.
    /// @param checkpoint The timestamp `level` was recorded at, in seconds.
    /// @param timestamp The timestamp to evaluate the bucket at, in seconds.
    /// @param leakRate The leak in units per second.
    /// @return The level as at `timestamp`.
    function levelAt(uint256 level, uint256 checkpoint, uint256 timestamp, uint256 leakRate)
        private
        pure
        returns (uint256)
    {
        return leak(level, LibSaturatingMath.saturatingSub(timestamp, checkpoint), leakRate);
    }

    /// Headroom against `capacity` for a level that has already been evaluated
    /// at the timestamp of interest. The single definition of "what fits",
    /// shared by `headroomAt` and `fillAt` so that the two cannot drift apart.
    /// They cannot share `headroomAt` itself, because `fillAt` already holds
    /// the level and would pay a second `levelAt` for it, so the shared piece
    /// is the saturation rather than the entry point.
    ///
    /// Saturates at zero, so a level above the capacity reports no room rather
    /// than underflowing to an enormous allowance.
    /// @param capacity The bucket capacity.
    /// @param levelNow The level as at the timestamp of interest.
    /// @return The amount that fits.
    function headroomFrom(uint256 capacity, uint256 levelNow) private pure returns (uint256) {
        return LibSaturatingMath.saturatingSub(capacity, levelNow);
    }

    /// Fill an unpacked bucket with `amount` at `timestamp`, returning the new
    /// level. Reverts with `LeakyBucketCapacityExceeded` if `amount` does not
    /// fit.
    ///
    /// The returned level belongs to `timestamp`, not to `checkpoint`, except
    /// where `timestamp` is at or behind `checkpoint` and no leak was credited,
    /// in which case it belongs to `checkpoint`. `fill` is what reconciles that
    /// with the word it writes back.
    ///
    /// An `amount` of zero is accepted whenever the bucket is at or over
    /// capacity as well as under it, because zero fits in zero headroom. It
    /// leaves the level unchanged, so it is a checkpoint and nothing else.
    /// @param level The level recorded at the checkpoint.
    /// @param checkpoint The timestamp `level` was recorded at, in seconds.
    /// @param timestamp The timestamp to fill at, in seconds.
    /// @param capacity The bucket capacity.
    /// @param leakRate The leak in units per second.
    /// @param amount The amount to fill.
    /// @return The new level, as at `timestamp`.
    function fillAt(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) private pure returns (uint256) {
        uint256 levelNow = levelAt(level, checkpoint, timestamp, leakRate);
        uint256 headroom = headroomFrom(capacity, levelNow);
        if (amount > headroom) {
            revert LeakyBucketCapacityExceeded(capacity, levelNow, amount);
        }
        unchecked {
            // `amount <= headroom`, and `headroom` saturates at
            // `capacity - levelNow`, so the sum is at most `capacity` and
            // cannot overflow.
            return levelNow + amount;
        }
    }

    /// Revert unless `capacity` is one this library can enforce, i.e. one that
    /// fits the packed level field.
    ///
    /// A capacity above `LEAKY_BUCKET_LEVEL_MAX` is not a tighter cap, it is a
    /// cap the layout cannot represent: the level it permits does not fit the
    /// word it has to be stored in. Left unchecked, `headroomAt` answers from
    /// the capacity and reports room that `fill` then refuses, so the two
    /// disagree at the same inputs and the one documented as "the largest
    /// amount `fill` would accept" is the one that is wrong. Checking it at
    /// both entry points makes them agree everywhere they answer at all.
    ///
    /// Rejecting rather than clamping is the same choice `pack` makes about
    /// truncation. A clamp would silently substitute a policy nobody set, and a
    /// mint cap that quietly enforces a different number than governance wrote
    /// is worse than one that refuses to run.
    /// @param capacity The capacity to check.
    function checkCapacity(uint256 capacity) private pure {
        if (capacity > LEAKY_BUCKET_LEVEL_MAX) {
            revert LeakyBucketCapacityOverflow(capacity);
        }
    }

    /// Revert unless `timestamp` is a second this library can record.
    ///
    /// The mirror of `checkCapacity` on the other packed field, and it exists
    /// for the same reason. `fill` ends in `pack`, which cannot store a second
    /// above `LEAKY_BUCKET_TIMESTAMP_MAX`, so a read that answered there would
    /// be naming an amount that `fill` refuses — the same disagreement between
    /// a read and a fill that `checkCapacity` exists to remove, on the other
    /// half of the word.
    ///
    /// Refusing rather than answering zero is the same choice again. A clock
    /// this library cannot represent is a broken clock source rather than a
    /// bucket that will not fill, and an error naming the second that is wrong
    /// sends whoever debugs it to the clock instead of leaving them with an
    /// answer they cannot act on.
    /// @param timestamp The timestamp to check, in seconds.
    function checkTimestamp(uint256 timestamp) private pure {
        if (timestamp > LEAKY_BUCKET_TIMESTAMP_MAX) {
            revert LeakyBucketTimestampOverflow(timestamp);
        }
    }

    /// The one statement of the rule this library rests on: **a read answers
    /// exactly where `fill` acts.**
    ///
    /// `fill` refuses two arguments outright, before any policy question is
    /// asked, because the word it has to write cannot carry them: a `capacity`
    /// wider than the level field, and a `timestamp` wider than the timestamp
    /// field. A read that answered at either would be making a promise `fill`
    /// breaks, so `headroomAt` refuses them first, here.
    ///
    /// Holding the rule in one place rather than repeating the guards at each
    /// entry point is the point of this function. Enforced pointwise, the rule
    /// is only as complete as whoever last remembered it — which is how the
    /// `capacity` half came to be guarded at three call sites while the
    /// `timestamp` half was guarded at none. A future packed field with a bound
    /// of its own is added once, here, and every entry point inherits it.
    ///
    /// `capacity` is checked first, so a call that is wrong in both ways names
    /// the policy parameter rather than the clock.
    /// @param capacity The capacity to check.
    /// @param timestamp The timestamp to check, in seconds.
    function checkFillableDomain(uint256 capacity, uint256 timestamp) private pure {
        checkCapacity(capacity);
        checkTimestamp(timestamp);
    }

    /// Pack a level and a timestamp into one word. The layout, in one place.
    ///
    /// Neither field is re-checked here, and that is a statement about `fill`
    /// rather than an omission. `fill` is the only caller and it establishes
    /// both bounds before it gets here:
    ///
    /// - The level. `checkFillableDomain` refuses a `capacity` above
    ///   `LEAKY_BUCKET_LEVEL_MAX`, `unpack` can only ever produce a level at or
    ///   below it, and `fillAt` returns at most the larger of that level and
    ///   the capacity. So the level is at or below `LEAKY_BUCKET_LEVEL_MAX` and
    ///   the shift cannot truncate it or reach a timestamp bit.
    /// - The timestamp. `checkFillableDomain` refuses one above
    ///   `LEAKY_BUCKET_TIMESTAMP_MAX`, and the stored checkpoint it is compared
    ///   against came out of `unpack`'s mask, so the larger of the two is
    ///   within the field.
    ///
    /// Truncation is still the failure this ordering exists to prevent, and it
    /// is prevented at the parameter rather than at the word. A time field that
    /// wrapped would read as a checkpoint far in the past, which is an enormous
    /// leak, which is a full bucket of headroom that was never earned; a
    /// wrapped level would read as a far emptier bucket than reality. A cap
    /// that fails open is worse than one that fails closed, so the capacity and
    /// the clock are refused up front, by name, where a caller can act on which
    /// one was wrong.
    /// @param level The level to pack. At or below `LEAKY_BUCKET_LEVEL_MAX`.
    /// @param timestamp The timestamp to pack, in seconds. At or below
    /// `LEAKY_BUCKET_TIMESTAMP_MAX`.
    /// @return The packed checkpoint.
    function pack(uint256 level, uint256 timestamp) private pure returns (uint256) {
        unchecked {
            return (level << LEAKY_BUCKET_TIMESTAMP_BITS) | timestamp;
        }
    }

    /// Unpack a checkpoint into its level and timestamp. Total over every 256
    /// bit word, and the exact inverse of `pack` over every packable pair.
    /// @param checkpoint The packed checkpoint.
    /// @return level The level recorded at the checkpoint.
    /// @return timestamp The timestamp the level was recorded at, in seconds.
    function unpack(uint256 checkpoint) private pure returns (uint256 level, uint256 timestamp) {
        unchecked {
            level = checkpoint >> LEAKY_BUCKET_TIMESTAMP_BITS;
            timestamp = checkpoint & LEAKY_BUCKET_TIMESTAMP_MAX;
        }
    }

    /// The largest amount `fill` would accept at `timestamp`. Reverts with
    /// `LeakyBucketCapacityOverflow` if `capacity` is one this library cannot
    /// enforce, or `LeakyBucketTimestampOverflow` if `timestamp` is a second it
    /// cannot record, rather than naming an amount `fill` would refuse. See
    /// `checkFillableDomain`.
    ///
    /// ## Why this is exported at all
    ///
    /// It is not here because a caller might like to know, and it is not a view
    /// for frontends. It is here because **a caller metering one amount through
    /// several buckets cannot otherwise say which of them refused it.**
    ///
    /// `fill` reverts with `LeakyBucketCapacityExceeded(capacity, level,
    /// amount)`, which names a policy and a state but not a bucket, and two
    /// buckets can be running the same `capacity`. `fill` is `internal`, so the
    /// revert cannot be caught and relabelled in the frame that raised it. A
    /// caller that must attribute the rejection — a token metering every mint
    /// through a global bucket and a per-minter one, where "which cap bound"
    /// decides whether an operator raises a limit or revokes a key — therefore
    /// has to ask before it fills, and this is the question.
    ///
    /// The alternative is for the caller to compute headroom itself, which
    /// means re-deriving the leak, the field widths and the saturation
    /// directions outside the library that exists to hold them. That is the
    /// duplication this library is for, so `headroomAt` stays.
    ///
    /// What it answers is exactly what `fill` takes: the amount it names always
    /// fits, one unit more is always rejected, and the two are guarded by the
    /// same `checkFillableDomain` and computed through the same `headroomFrom`,
    /// so they agree at every input by construction rather than by two copies
    /// of the arithmetic staying in step.
    ///
    /// It also saturates at zero, which is what makes lowering `capacity` below
    /// a level that is already outstanding a safe governance action: headroom
    /// reads zero, every non zero fill is rejected, and the bucket leaks down
    /// under the new policy until it fits. No fill is needed to make the new
    /// capacity bind, and nothing has to be migrated.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The timestamp to evaluate the bucket at, in seconds.
    /// @param capacity The bucket capacity.
    /// @param leakRate The leak in units per second.
    /// @return The amount that would fit at `timestamp`.
    function headroomAt(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate)
        internal
        pure
        returns (uint256)
    {
        checkFillableDomain(capacity, timestamp);
        (uint256 level, uint256 checkpointTimestamp) = unpack(checkpoint);
        return headroomFrom(capacity, levelAt(level, checkpointTimestamp, timestamp, leakRate));
    }

    /// Fill a bucket with `amount` at `timestamp`, returning the new packed
    /// checkpoint to store. Reverts with `LeakyBucketCapacityExceeded` if the
    /// amount does not fit, `LeakyBucketCapacityOverflow` if `capacity` is one
    /// this library cannot enforce, or `LeakyBucketTimestampOverflow` if
    /// `timestamp` is past the width of the packed field and so cannot be
    /// recorded. The caller stores nothing in any of the three cases, and that
    /// list is exhaustive: a `try`/`catch`, or a frontend decoding a failed
    /// simulation, is written from it.
    ///
    /// The third path is reachable from any caller that supplies a time from
    /// somewhere other than `block.timestamp`, which this library permits and
    /// the backwards clock tests exercise.
    ///
    /// The returned word carries the new level and the timestamp that level
    /// belongs to, so writing it back is the whole of the state update.
    ///
    /// ## The stored timestamp never goes backwards
    ///
    /// The word carries the later of `timestamp` and the checkpoint it
    /// replaces, not `timestamp` itself. The two differ only when the clock is
    /// behind the stored checkpoint, and then they differ in a direction that
    /// matters.
    ///
    /// `levelAt` saturates the elapsed time at zero, so a backwards clock
    /// credits no leak and the level computed is the level the bucket has at
    /// the *checkpoint*, not at `timestamp`. Storing it against `timestamp`
    /// would therefore be storing a level at a second it does not belong to,
    /// and the next read would measure its elapsed time from that earlier
    /// second and credit leak for time that had already passed before this
    /// fill. The saturation keeps the backwards step from handing out headroom
    /// on the way in, and a regressed checkpoint hands it out on the way out
    /// instead: from one zero amount call at a stale clock, a bucket leaking
    /// one unit a second and checkpointed an hour ago offers an hour of leak
    /// that nobody waited for.
    ///
    /// Keeping the later of the two is exact rather than merely conservative.
    /// When the clock is behind, no leak was credited, so the level returned is
    /// precisely the level at the checkpoint, and the checkpoint is precisely
    /// the second it belongs to. When the clock is ahead, which is every case a
    /// monotonic `block.timestamp` can produce, this is `timestamp` and nothing
    /// changes.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The timestamp to fill at, in seconds.
    /// @param capacity The bucket capacity.
    /// @param leakRate The leak in units per second.
    /// @param amount The amount to fill.
    /// @return The new packed checkpoint.
    function fill(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        checkFillableDomain(capacity, timestamp);
        (uint256 level, uint256 checkpointTimestamp) = unpack(checkpoint);
        return pack(
            fillAt(level, checkpointTimestamp, timestamp, capacity, leakRate, amount),
            timestamp > checkpointTimestamp ? timestamp : checkpointTimestamp
        );
    }
}
