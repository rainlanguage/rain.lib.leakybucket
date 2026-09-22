// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {LibLeakyBucket} from "./LibLeakyBucket.sol";

/// @dev Bits the timestamp occupies in a packed checkpoint, in the low end of
/// the word.
uint256 constant LEAKY_BUCKET_TIMESTAMP_BITS = 64;

/// @dev Largest timestamp a packed checkpoint can hold, in seconds. Around
/// 5.8e11 years, so it is not a deadline in any sense that needs managing; it
/// exists so the width is stated rather than assumed.
uint256 constant LEAKY_BUCKET_TIMESTAMP_MAX = type(uint64).max;

/// @dev Largest level a packed checkpoint can hold, and therefore the largest
/// `capacity` that can be enforced through this codec. Around 6.2e57, which is
/// 6.2e39 whole tokens at eighteen decimals. Every entry point here that takes
/// a `capacity` rejects one above this, and `checkCapacity` is the same guard
/// on its own so a governance setter can refuse it at the moment it is set
/// rather than at the moment someone tries to mint.
uint256 constant LEAKY_BUCKET_LEVEL_MAX = type(uint192).max;

/// @dev Thrown when the capacity in force is above `LEAKY_BUCKET_LEVEL_MAX`,
/// which is a level this codec cannot store and therefore a cap it cannot
/// enforce. It is a misconfiguration rather than a condition to handle at the
/// call site, and it is named as one: the alternative is `headroomAt` reporting
/// room that `fill` will not take, and the rejection then naming the packing
/// width instead of the parameter that is actually wrong.
/// @param capacity The capacity that cannot be enforced.
error LeakyBucketCapacityOverflow(uint256 capacity);

/// @dev Thrown when a level does not fit the packed field. Not reachable
/// through `fill`, which refuses an unenforceable `capacity` up front and so
/// can only ever produce a level within it. It guards `pack` itself, for a
/// caller assembling a word from a level of its own.
/// @param level The level that did not fit.
error LeakyBucketLevelOverflow(uint256 level);

/// @dev Thrown when a timestamp does not fit the packed field, which makes it a
/// second this codec cannot record and therefore one `fill` can never act at.
/// Like `LeakyBucketCapacityOverflow` it names the argument that is wrong rather
/// than the width that rejected it, and every entry point that would otherwise
/// answer a question `fill` could not honour at such a second refuses it
/// instead.
/// @param timestamp The timestamp that did not fit.
error LeakyBucketTimestampOverflow(uint256 timestamp);

/// @title LibLeakyBucketCheckpoint
/// @notice `LibLeakyBucket` state packed into a single 256 bit word, so that a
/// concrete contract can keep a bucket in one storage slot and touch it with
/// one `SLOAD` and one `SSTORE` per fill.
///
/// The layout is the level in the high 192 bits and the timestamp in the low
/// 64. Both fields are read with a shift or a mask and no keccak, so the whole
/// hot path of a capped mint is: load one word, one multiply for the leak, one
/// compare against capacity, store one word.
///
/// ## Why this exists rather than two return values
///
/// `LibLeakyBucket.fillAt` returns a level that belongs to the timestamp it was
/// evaluated at. Storing that level while leaving the old checkpoint timestamp
/// in place credits the same leak again on the next call, and the cap quietly
/// stops binding. It is a one line mistake with no symptom until it is
/// exploited, which is the worst shape a bug in a mint cap can have. Here the
/// level and the timestamp are one word, `fill` returns that word, and the only
/// thing a caller can do with it is write it back whole. The failure mode is
/// removed rather than documented.
///
/// ## What is still the caller's
///
/// The slot. The key, if there is more than one bucket. Where `capacity` and
/// `leakRate` come from and who is allowed to change them. This library is
/// reached the same way from an immutable pair, a timelocked setter, a staged
/// upgrade, or a per minter mapping holding a different pair for every minter,
/// and it cannot tell which it is being used from.
///
/// Two bounds are the codec's rather than the caller's, because they follow
/// from the packing rather than from any view about policy. A `capacity` wider
/// than `LEAKY_BUCKET_LEVEL_MAX` is a cap this codec cannot enforce, and a
/// `timestamp` past `LEAKY_BUCKET_TIMESTAMP_MAX` is a second it cannot record.
/// `checkFillableDomain` is the single statement of both, and it is what every
/// entry point below that makes a claim about `fill` applies, so the readable
/// domain and the fillable domain are the same set by construction rather than
/// by three call sites agreeing with each other. `checkCapacity` and
/// `checkTimestamp` are the halves on their own, for a governance setter that
/// would rather refuse a policy it can never use at the moment it is set, or a
/// caller validating a clock of its own before it reaches here.
///
/// ```solidity
/// // One bucket per minter, each with its own policy, governed however the
/// // concrete likes.
/// mapping(address minter => uint256 checkpoint) internal _buckets;
///
/// function mint(address to, uint256 amount) external {
///     _buckets[msg.sender] = LibLeakyBucketCheckpoint.fill(
///         _buckets[msg.sender], block.timestamp, capacity[msg.sender], leakRate[msg.sender], amount
///     );
///     _mint(to, amount);
/// }
/// ```
///
/// A zero word is a valid initial state and means an empty bucket checkpointed
/// at the epoch. No initializer is needed: an untouched slot is a bucket that
/// has been empty since before the chain existed, which is exactly what it
/// should be. Concretes that want the opposite, a bucket that starts full,
/// write `pack(capacity, block.timestamp)` once.
library LibLeakyBucketCheckpoint {
    /// Revert unless `capacity` is one this codec can enforce, i.e. one that
    /// fits the packed level field.
    ///
    /// A capacity above `LEAKY_BUCKET_LEVEL_MAX` is not a tighter cap, it is a
    /// cap the codec cannot represent: the level it permits does not fit the
    /// word it has to be stored in. Left unchecked, `headroomAt` answers from
    /// the capacity and reports room that `fill` then refuses, so the two
    /// disagree at the same inputs and the one documented as "the largest
    /// amount `fill` would accept" is the one that is wrong. Checking it at
    /// every entry point makes them agree everywhere they answer at all.
    ///
    /// Rejecting rather than clamping is the same choice `pack` makes about
    /// truncation. A clamp would silently substitute a policy nobody set, and a
    /// mint cap that quietly enforces a different number than governance wrote
    /// is worse than one that refuses to run.
    ///
    /// Exposed on its own so a governance setter can apply it where the
    /// capacity enters the system, which is the only place the misconfiguration
    /// can be fixed rather than merely detected.
    /// @param capacity The capacity to check.
    function checkCapacity(uint256 capacity) internal pure {
        if (capacity > LEAKY_BUCKET_LEVEL_MAX) {
            revert LeakyBucketCapacityOverflow(capacity);
        }
    }

    /// Revert unless `timestamp` is a second this codec can record.
    ///
    /// The mirror of `checkCapacity` on the other packed field, and it exists
    /// for the same reason. `fill` ends in `pack`, which cannot store a second
    /// above `LEAKY_BUCKET_TIMESTAMP_MAX`, so a read that answered there would
    /// be naming an amount, or a moment, that `fill` refuses — the same
    /// disagreement between a read and a fill that `checkCapacity` exists to
    /// remove, on the other half of the word.
    ///
    /// Refusing rather than answering "never" is the same choice again. A clock
    /// this codec cannot represent is a broken clock source rather than a
    /// bucket that will not fill, and an error naming the second that is wrong
    /// sends whoever debugs it to the clock instead of leaving them with an
    /// answer they cannot act on.
    ///
    /// Exposed on its own for a caller that supplies a time from somewhere
    /// other than `block.timestamp` and would rather find out where that time
    /// enters the system.
    /// @param timestamp The timestamp to check, in seconds.
    function checkTimestamp(uint256 timestamp) internal pure {
        if (timestamp > LEAKY_BUCKET_TIMESTAMP_MAX) {
            revert LeakyBucketTimestampOverflow(timestamp);
        }
    }

    /// The one statement of the rule the packed API rests on: **a read answers
    /// exactly where `fill` acts.**
    ///
    /// `fill` refuses two arguments outright, before any policy question is
    /// asked, because the word it has to write cannot carry them: a `capacity`
    /// wider than the level field, and a `timestamp` wider than the timestamp
    /// field. A read that answered at either would be making a promise `fill`
    /// breaks, so every entry point that makes a claim about `fill` refuses
    /// them first, here.
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
    ///
    /// `levelAt` is deliberately not held to this. It takes no `capacity` and
    /// makes no claim about `fill`: it reports where the bucket's own
    /// trajectory is at a second, which is as true of a second the codec could
    /// not record as of one it could.
    /// @param capacity The capacity to check.
    /// @param timestamp The timestamp to check, in seconds.
    function checkFillableDomain(uint256 capacity, uint256 timestamp) internal pure {
        checkCapacity(capacity);
        checkTimestamp(timestamp);
    }

    /// Pack a level and a timestamp into one word. Reverts rather than
    /// truncating if either does not fit.
    ///
    /// Truncation is the specific failure this guards. A time field that wraps
    /// reads as a checkpoint far in the past, which is an enormous leak, which
    /// is a full bucket of headroom that was never earned. A cap that fails
    /// open at a fixed future date is worse than one that fails closed, so both
    /// fields revert.
    /// @param level The level to pack.
    /// @param timestamp The timestamp to pack, in seconds.
    /// @return The packed checkpoint.
    function pack(uint256 level, uint256 timestamp) internal pure returns (uint256) {
        if (level > LEAKY_BUCKET_LEVEL_MAX) {
            revert LeakyBucketLevelOverflow(level);
        }
        checkTimestamp(timestamp);
        unchecked {
            return (level << LEAKY_BUCKET_TIMESTAMP_BITS) | timestamp;
        }
    }

    /// Unpack a checkpoint into its level and timestamp. Total over every 256
    /// bit word, and the exact inverse of `pack` over every packable pair.
    /// @param checkpoint The packed checkpoint.
    /// @return level The level recorded at the checkpoint.
    /// @return timestamp The timestamp the level was recorded at, in seconds.
    function unpack(uint256 checkpoint) internal pure returns (uint256 level, uint256 timestamp) {
        unchecked {
            level = checkpoint >> LEAKY_BUCKET_TIMESTAMP_BITS;
            timestamp = checkpoint & LEAKY_BUCKET_TIMESTAMP_MAX;
        }
    }

    /// The level of a packed bucket as at `timestamp`.
    ///
    /// Answers at any second, including one this codec could not record. It is
    /// the one packed read that makes no claim about `fill`, so there is
    /// nothing here for a second outside the packable range to disagree with:
    /// the bucket's trajectory is defined at every second whether or not a
    /// checkpoint could be written at it. See `checkFillableDomain`.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The timestamp to evaluate the bucket at, in seconds.
    /// @param leakRate The leak in units per second.
    /// @return The level as at `timestamp`.
    function levelAt(uint256 checkpoint, uint256 timestamp, uint256 leakRate) internal pure returns (uint256) {
        (uint256 level, uint256 checkpointTimestamp) = unpack(checkpoint);
        return LibLeakyBucket.levelAt(level, checkpointTimestamp, timestamp, leakRate);
    }

    /// The largest amount `fill` would accept at `timestamp`. Reverts with
    /// `LeakyBucketCapacityOverflow` if `capacity` is one this codec cannot
    /// enforce, or `LeakyBucketTimestampOverflow` if `timestamp` is a second it
    /// cannot record, rather than naming an amount `fill` would refuse. See
    /// `checkFillableDomain`.
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
        return LibLeakyBucket.headroomAt(level, checkpointTimestamp, timestamp, capacity, leakRate);
    }

    /// The earliest timestamp `amount` would fit at. See
    /// `LibLeakyBucket.fillableAt` for what the sentinel means. Reverts with
    /// `LeakyBucketCapacityOverflow` if `capacity` is one this codec cannot
    /// enforce, or `LeakyBucketTimestampOverflow` if `timestamp` is a second it
    /// cannot record, rather than naming a second at which `fill` would revert.
    /// See `checkFillableDomain`.
    ///
    /// The answer is the core's, narrowed to this codec's horizon. A second
    /// past `LEAKY_BUCKET_TIMESTAMP_MAX` is one `fill` can never be called at,
    /// so it comes back as the "never" sentinel rather than as a date: a wait
    /// nobody can wait out is not a wait, and naming it as one is exactly the
    /// answer a scheduler or a frontend would act on and never be able to
    /// execute. The core already collapses an arrival time that leaves the word
    /// to the same sentinel for the same reason; the packed layout only makes
    /// the horizon nearer, so the rule it already states is applied at the
    /// narrower width.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The timestamp to evaluate the bucket at, in seconds.
    /// @param capacity The bucket capacity.
    /// @param leakRate The leak in units per second.
    /// @param amount The amount to wait for.
    /// @return The earliest timestamp `amount` fits at, or `type(uint256).max`.
    function fillableAt(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        checkFillableDomain(capacity, timestamp);
        (uint256 level, uint256 checkpointTimestamp) = unpack(checkpoint);
        uint256 at = LibLeakyBucket.fillableAt(level, checkpointTimestamp, timestamp, capacity, leakRate, amount);
        // A second this codec cannot record is a second `fill` can never be
        // called at, which is never rather than a wait.
        return at > LEAKY_BUCKET_TIMESTAMP_MAX ? type(uint256).max : at;
    }

    /// Fill a packed bucket with `amount` at `timestamp`, returning the new
    /// packed checkpoint to store. Reverts with `LeakyBucketCapacityExceeded`
    /// if the amount does not fit, or `LeakyBucketCapacityOverflow` if
    /// `capacity` is one this codec cannot enforce, and the caller stores
    /// nothing either way.
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
    /// `LibLeakyBucket.levelAt` saturates the elapsed time at zero, so a
    /// backwards clock credits no leak and the level this returns is the level
    /// the bucket has at the *checkpoint*, not at `timestamp`. Storing it
    /// against `timestamp` would therefore be storing a level at a second it
    /// does not belong to, and the next read would measure its elapsed time
    /// from that earlier second and credit leak for time that had already
    /// passed before this fill. The saturation keeps the backwards step from
    /// handing out headroom on the way in, and a regressed checkpoint hands it
    /// out on the way out instead: from one zero amount call at a stale clock,
    /// a bucket leaking one unit a second and checkpointed an hour ago offers
    /// an hour of leak that nobody waited for.
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
            LibLeakyBucket.fillAt(level, checkpointTimestamp, timestamp, capacity, leakRate, amount),
            timestamp > checkpointTimestamp ? timestamp : checkpointTimestamp
        );
    }
}
