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

/// @title LibLeakyBucket
/// @notice A leaky bucket as a meter, in the textbook form, as pure functions
/// over 256 bit words.
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
/// Every function here is `pure` and takes the bucket state as arguments. The
/// library owns no storage, no slot, no mapping, no owner, no initializer and
/// no upgrade hook. A concrete contract holds `(level, checkpoint)` wherever it
/// likes, under whatever key it likes, and supplies `capacity` and `leakRate`
/// from wherever its governance puts them: immutables, a timelocked setter, a
/// multi stage upgrade, or a per minter mapping with a different pair per
/// minter. The library never sees any of that and cannot constrain it.
///
/// The state is two numbers. `level` is the fill as of `checkpoint`, and
/// `checkpoint` is the timestamp that level was recorded at. The leak between
/// `checkpoint` and now is derived on read, so a bucket that is never touched
/// costs nothing to drain. See `LibLeakyBucketCheckpoint` for the packing that
/// puts both in one word, and for the `fill` that writes both back together.
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
/// ## Arithmetic
///
/// Every operation that could leave the representable range is a saturating one
/// from `LibSaturatingMath`, which is audited and carries the same licence as
/// this library. There is no hand rolled overflow guard here to review. The
/// saturation directions are chosen so that the failure mode is always a
/// tighter cap or a drained bucket, never free headroom:
///
/// - The leak saturates the multiply at the top of the word, so an absurd
///   `elapsed * leakRate` reads as a leak larger than any level rather than
///   wrapping to a small one. A wrapped product would be free headroom.
/// - The leak saturates the subtract at zero, so a bucket cannot drain past
///   empty into a huge level, and cannot underflow.
/// - Elapsed time saturates at zero, so a clock at or behind the checkpoint
///   credits no leak at all rather than wrapping to billions of years of it.
/// - Headroom saturates at zero, so a level above capacity reports no room
///   rather than underflowing to an enormous allowance.
///
/// ## Leak is credited from the checkpoint, exactly
///
/// The leak is `elapsed * leakRate`, computed from the checkpoint in one
/// multiply. It is not accrued per call and not derived by dividing a capacity
/// by a window, so checkpointing more often cannot change the result:
///
/// ```
/// levelAt(levelAt(level, t0, t1, rate), t1, t2, rate) == levelAt(level, t0, t2, rate)
/// ```
///
/// for any `t0 <= t1 <= t2`. This holds exactly, at every input, with no
/// rounding slack, and it is fuzzed. It is worth stating because the common
/// alternative does not have it. Implementations that store a `window` and
/// leak at `capacity / window` per second take a floor division on every
/// checkpoint, so each call throws away the sub unit remainder, and a caller
/// touching the bucket every second is credited measurably less leak than a
/// caller touching it once an hour. That turns call frequency into part of the
/// cap. Here the rate is a parameter rather than a quotient and the checkpoint
/// is a subtraction from the original, so there is no per call remainder to
/// lose and frequency is not observable in the result.
///
/// The cost is that `leakRate` is expressed per second, so a policy written as
/// "X per day" is `X / 86400` and has to be rounded once, off chain, where the
/// rounding is visible and deliberate, instead of silently on every call. Round
/// down when converting, so the on chain rate is never faster than the policy.
library LibLeakyBucket {
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
    function leak(uint256 level, uint256 elapsed, uint256 leakRate) internal pure returns (uint256) {
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
    /// That is a property of this read, and keeping it takes one thing of
    /// whoever writes a result back: a stored checkpoint must never move
    /// backwards. Crediting no leak for a backwards step and then recording the
    /// earlier second leaves the same interval to be measured again on the next
    /// read, which pays out exactly the headroom this saturation just refused.
    /// `LibLeakyBucketCheckpoint.fill` keeps the later of the supplied time and
    /// the stored one for that reason, and a caller pairing this function with
    /// a checkpoint of its own owes the bucket the same.
    /// @param level The level recorded at the checkpoint.
    /// @param checkpoint The timestamp `level` was recorded at, in seconds.
    /// @param timestamp The timestamp to evaluate the bucket at, in seconds.
    /// @param leakRate The leak in units per second.
    /// @return The level as at `timestamp`.
    function levelAt(uint256 level, uint256 checkpoint, uint256 timestamp, uint256 leakRate)
        internal
        pure
        returns (uint256)
    {
        return leak(level, LibSaturatingMath.saturatingSub(timestamp, checkpoint), leakRate);
    }

    /// The largest amount that `fillAt` would accept at `timestamp`.
    ///
    /// Saturates at zero, which is what makes lowering `capacity` below a level
    /// that is already outstanding a safe governance action: headroom reads
    /// zero, every non zero fill is rejected, and the bucket leaks down under
    /// the new policy until it fits. No fill is needed to make the new capacity
    /// bind, and nothing has to be migrated.
    /// @param level The level recorded at the checkpoint.
    /// @param checkpoint The timestamp `level` was recorded at, in seconds.
    /// @param timestamp The timestamp to evaluate the bucket at, in seconds.
    /// @param capacity The bucket capacity.
    /// @param leakRate The leak in units per second.
    /// @return The amount that would fit at `timestamp`.
    function headroomAt(uint256 level, uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate)
        internal
        pure
        returns (uint256)
    {
        return LibSaturatingMath.saturatingSub(capacity, levelAt(level, checkpoint, timestamp, leakRate));
    }

    /// Fill the bucket with `amount` at `timestamp`, returning the new level.
    /// Reverts with `LeakyBucketCapacityExceeded` if `amount` does not fit.
    ///
    /// The returned level belongs to `timestamp`, not to `checkpoint`. A caller
    /// storing it against the old checkpoint would credit the same leak twice
    /// on the next call and the cap would not hold. Write both back together,
    /// or use `LibLeakyBucketCheckpoint.fill`, which packs them into one word
    /// and makes writing one without the other impossible.
    ///
    /// The exception is a `timestamp` at or before `checkpoint`, where the
    /// elapsed time saturates at zero and no leak is credited. The level
    /// returned then belongs to `checkpoint` as much as to `timestamp`, and it
    /// is `checkpoint` that must be stored: recording the earlier second lets
    /// the next read measure an interval that has already been paid for and
    /// hand out headroom nobody waited for. Store the later of the two. The
    /// codec does exactly that, which is another reason to reach for it.
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
    ) internal pure returns (uint256) {
        uint256 levelNow = levelAt(level, checkpoint, timestamp, leakRate);
        uint256 headroom = LibSaturatingMath.saturatingSub(capacity, levelNow);
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

    /// The earliest timestamp at which `amount` would fit, assuming `capacity`
    /// and `leakRate` do not change and nothing else fills the bucket in the
    /// meantime. Returns `timestamp` when the amount already fits.
    ///
    /// Returns `type(uint256).max` to mean never: either `amount` is larger
    /// than `capacity`, so no amount of waiting helps, or `leakRate` is zero,
    /// so the bucket does not drain at all. The same value comes back when the
    /// wait is real but the arrival time saturates the word, which is
    /// indistinguishable from never for any purpose.
    ///
    /// This is a view for callers and frontends. It is not consulted by
    /// `fillAt` and nothing in the enforcement path depends on it.
    /// @param level The level recorded at the checkpoint.
    /// @param checkpoint The timestamp `level` was recorded at, in seconds.
    /// @param timestamp The timestamp to evaluate the bucket at, in seconds.
    /// @param capacity The bucket capacity.
    /// @param leakRate The leak in units per second.
    /// @param amount The amount to wait for.
    /// @return The earliest timestamp `amount` fits at, or `type(uint256).max`.
    function fillableAt(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) internal pure returns (uint256) {
        if (amount > capacity) {
            return type(uint256).max;
        }
        uint256 levelNow = levelAt(level, checkpoint, timestamp, leakRate);
        // Exactly the test `fillAt` applies, so the two agree at every input.
        // In particular a zero amount always fits, including when the bucket is
        // already over capacity, and the answer is now rather than a wait.
        if (amount <= LibSaturatingMath.saturatingSub(capacity, levelNow)) {
            return timestamp;
        }
        // A bucket that does not drain never makes room for an amount that does
        // not already fit, so this is "never" however far short it is. Tested
        // before the target is worked out, because it does not depend on the
        // target: the cheaper and more general answer comes first.
        if (leakRate == 0) {
            return type(uint256).max;
        }
        uint256 wait;
        unchecked {
            // `amount <= capacity` was checked above, so this cannot underflow.
            uint256 target = capacity - amount;
            // `levelNow > target` so the deficit is at least one, the ceiling
            // division below cannot underflow, and the quotient is at most
            // `deficit - 1` so the increment cannot overflow.
            uint256 deficit = levelNow - target;
            wait = (deficit - 1) / leakRate + 1;
        }
        // The leak only accrues once the clock passes the checkpoint, so a
        // `timestamp` behind the checkpoint waits from the checkpoint rather
        // than from itself. `from >= timestamp`, so the answer is never earlier
        // than the caller's own clock, and a wait that leaves the word
        // saturates to the "never" sentinel.
        uint256 from = timestamp > checkpoint ? timestamp : checkpoint;
        return LibSaturatingMath.saturatingAdd(from, wait);
    }
}
