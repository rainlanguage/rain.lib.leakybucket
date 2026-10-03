// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";

/// A fill of `amount` does not fit: `level + amount > capacity`.
error LeakyBucketCapacityExceeded(Float capacity, Float level, Float amount);

/// `amount` is zero.
error LeakyBucketZeroAmount();

/// `amount` is negative. A fill adds; a negative fill would drain the bucket
/// and so mint under a cap it never reached.
error LeakyBucketNegativeAmount(Float amount);

/// `capacity` is negative, so no fill could ever fit.
error LeakyBucketNegativeCapacity(Float capacity);

/// `leakRate` is negative, so the bucket would fill as time passed.
error LeakyBucketNegativeLeakRate(Float leakRate);

/// The stored `level` is negative, which reads as more headroom than the
/// capacity.
error LeakyBucketNegativeLevel(Float level);

/// A timestamp is negative: the stored one, or the one read or filled at.
error LeakyBucketNegativeTimestamp(Float timestamp);

/// `amount` fits the headroom but does not raise `level`, so accepting it would
/// charge nothing against the capacity.
error LeakyBucketAmountNotCredited(Float level, Float amount);

/// A bucket. The caller stores it; the library never writes it.
/// @param level The level at `timestamp`.
/// @param timestamp When `level` was recorded.
/// @param capacity Burst.
/// @param leakRate Units leaked per unit of time. Applied at read time to the
/// whole interval since `timestamp`, so a rate written alone re-rates time that
/// passed under the old one; see `setPolicy`.
struct LeakyBucket {
    Float level;
    Float timestamp;
    Float capacity;
    Float leakRate;
}

/// @title LibLeakyBucket
/// @notice Pure leaky bucket over a `LeakyBucket` the caller holds. Every field
/// is a `Float`, timestamps included, so elapsed time is a subtraction in the
/// same arithmetic as the level rather than a separate fixed point domain the
/// caller converts across.
///
/// Nothing saturates at a type boundary any more, because a `Float` has no
/// boundary a bucket reaches: the level, the capacity and the timestamp were
/// each bounded by the field they were packed into, and none of them is packed
/// now. What remains of the old saturation is `saturatingSub` at zero — a leak
/// never takes the level below it and a backwards clock credits no leak — which
/// is a property of the bucket rather than of the arithmetic.
library LibLeakyBucket {
    using LibDecimalFloat for Float;

    /// `a - b`, saturating at zero.
    function saturatingSub(Float a, Float b) private pure returns (Float) {
        return LibDecimalFloat.max(a.sub(b), LibDecimalFloat.FLOAT_ZERO);
    }

    /// `bucket` leaked to `timestamp` at `leakRate`, with nothing checked: the
    /// level, saturating at zero, then the later of `timestamp` and the stored
    /// timestamp. A backwards clock leaks nothing.
    function leak(LeakyBucket memory bucket, Float timestamp, Float leakRate) private pure returns (Float, Float) {
        Float elapsed = saturatingSub(timestamp, bucket.timestamp);
        return (saturatingSub(bucket.level, elapsed.mul(leakRate)), LibDecimalFloat.max(timestamp, bucket.timestamp));
    }

    /// `capacity - levelNow`, saturating at zero.
    function headroomFrom(Float capacity, Float levelNow) private pure returns (Float) {
        return saturatingSub(capacity, levelNow);
    }

    /// Reverts on a negative `capacity` or `leakRate`.
    function checkPolicy(Float capacity, Float leakRate) private pure {
        if (capacity.lt(LibDecimalFloat.FLOAT_ZERO)) {
            revert LeakyBucketNegativeCapacity(capacity);
        }
        if (leakRate.lt(LibDecimalFloat.FLOAT_ZERO)) {
            revert LeakyBucketNegativeLeakRate(leakRate);
        }
    }

    /// Reverts on a negative stored level, or a negative timestamp.
    function checkLevelAndTimestamps(LeakyBucket memory bucket, Float timestamp) private pure {
        if (bucket.level.lt(LibDecimalFloat.FLOAT_ZERO)) {
            revert LeakyBucketNegativeLevel(bucket.level);
        }
        if (bucket.timestamp.lt(LibDecimalFloat.FLOAT_ZERO)) {
            revert LeakyBucketNegativeTimestamp(bucket.timestamp);
        }
        if (timestamp.lt(LibDecimalFloat.FLOAT_ZERO)) {
            revert LeakyBucketNegativeTimestamp(timestamp);
        }
    }

    /// Reverts on a bucket that cannot answer.
    ///
    /// A negative capacity admits no fill and a negative leak rate fills the
    /// bucket as time passes, which is the opposite of a leak. A negative level
    /// is headroom above the capacity. None is a stricter bucket, so none is
    /// treated as one.
    function checkFillableDomain(LeakyBucket memory bucket, Float timestamp) private pure {
        checkPolicy(bucket.capacity, bucket.leakRate);
        checkLevelAndTimestamps(bucket, timestamp);
    }

    /// The outstanding level at `timestamp`: the stored level leaked forward at
    /// the stored rate, a backwards clock leaking nothing.
    ///
    /// Exported because it cannot be derived from `headroomAt`. `capacity -
    /// headroom` agrees with the level only while the level is at or under the
    /// capacity; the headroom saturates at zero, so once a capacity is lowered
    /// under an outstanding level that subtraction returns the capacity and
    /// silently under-reports what is owed.
    /// @param bucket The bucket. Not modified.
    /// @param timestamp When to read at.
    /// @return The level at `timestamp`.
    function levelAt(LeakyBucket memory bucket, Float timestamp) internal pure returns (Float) {
        checkFillableDomain(bucket, timestamp);
        (Float level,) = leak(bucket, timestamp, bucket.leakRate);
        return level;
    }

    /// The bucket checkpointed at `timestamp` with nothing filled: the level
    /// `levelAt` reports, and the later of `timestamp` and the stored
    /// timestamp, so a backwards clock never re-credits leak on the next fill.
    ///
    /// To the precision of the level, not exactly. A `Float` subtraction keeps
    /// about 67 digits and its rounding is not directed: a leak below the
    /// level's last digit takes a whole digit off it or, further below, takes
    /// nothing, and the checkpoint advances over that time either way. At that
    /// scale a settle changes what a later read returns, in either direction.
    /// @param bucket The bucket. Not modified.
    /// @param timestamp When to settle at.
    /// @return level The settled level, to store as `bucket.level`.
    /// @return checkpoint The new timestamp, to store as `bucket.timestamp`.
    function settle(LeakyBucket memory bucket, Float timestamp) internal pure returns (Float level, Float checkpoint) {
        checkFillableDomain(bucket, timestamp);
        return leak(bucket, timestamp, bucket.leakRate);
    }

    /// `bucket` under a new policy from `timestamp`: settled at the stored
    /// rate, then carrying `capacity` and `leakRate`. The way to change either.
    ///
    /// A bucket records its level and when, not the rate that was in force, so
    /// the leak over the whole interval since the checkpoint is priced at
    /// whatever rate is read. A new rate written alone re-rates that interval:
    /// raising it hands out headroom neither policy earned, and a zero rate is
    /// not a pause, because the time spent at zero is leaked at the restored
    /// rate. Settled first, each rate is charged for the time it was in force.
    ///
    /// Reverts on a negative `capacity` or `leakRate`, so neither is stored,
    /// and on a negative stored level or timestamp. The stored policy is being
    /// replaced, so it is not checked. A stored leak rate that is already
    /// negative is no rate to settle at: no leak is credited and the checkpoint
    /// still moves, so such a bucket takes a policy rather than refusing every
    /// call for good.
    /// @param bucket The bucket under its stored policy. Not modified.
    /// @param timestamp When the new policy starts.
    /// @param capacity The new capacity.
    /// @param leakRate The new leak rate.
    /// @return The bucket to store, all four fields.
    function setPolicy(LeakyBucket memory bucket, Float timestamp, Float capacity, Float leakRate)
        internal
        pure
        returns (LeakyBucket memory)
    {
        checkPolicy(capacity, leakRate);
        checkLevelAndTimestamps(bucket, timestamp);
        Float storedRate = LibDecimalFloat.max(bucket.leakRate, LibDecimalFloat.FLOAT_ZERO);
        (Float level, Float checkpoint) = leak(bucket, timestamp, storedRate);
        return LeakyBucket({level: level, timestamp: checkpoint, capacity: capacity, leakRate: leakRate});
    }

    /// The most `fill` would accept at `timestamp`: a positive headroom fits
    /// in full and any amount above it is refused. Zero means nothing fits,
    /// and `fill` refuses a zero amount, so check for zero before filling.
    /// Reverts on the same buckets `fill` refuses.
    /// @param bucket The bucket. Not modified.
    /// @param timestamp When to read at.
    /// @return Headroom at `timestamp`.
    function headroomAt(LeakyBucket memory bucket, Float timestamp) internal pure returns (Float) {
        return headroomFrom(bucket.capacity, levelAt(bucket, timestamp));
    }

    /// Fill `amount` at `timestamp`: `amount` on top of the settled level. The
    /// bucket is checked, then the amount, then the leak is computed, so a zero
    /// or a negative amount reverts by name on every bucket the check passes.
    /// @param bucket The bucket. Not modified.
    /// @param timestamp When to fill at.
    /// @param amount The amount to fill.
    /// @return level The new level, to store as `bucket.level`.
    /// @return checkpoint The new timestamp, to store as `bucket.timestamp`.
    function fill(LeakyBucket memory bucket, Float timestamp, Float amount)
        internal
        pure
        returns (Float level, Float checkpoint)
    {
        checkFillableDomain(bucket, timestamp);
        if (amount.isZero()) {
            revert LeakyBucketZeroAmount();
        }
        if (amount.lt(LibDecimalFloat.FLOAT_ZERO)) {
            revert LeakyBucketNegativeAmount(amount);
        }
        Float levelNow;
        (levelNow, checkpoint) = leak(bucket, timestamp, bucket.leakRate);
        if (amount.gt(headroomFrom(bucket.capacity, levelNow))) {
            revert LeakyBucketCapacityExceeded(bucket.capacity, levelNow, amount);
        }
        // A positive amount that leaves the level where it was has not been
        // charged. `Float` carries about 67 exact digits, so an amount far
        // enough below the level falls off the tail of the sum and the bucket
        // would report a successful fill having recorded nothing — a mint under
        // a cap it never reached.
        //
        // Refusing is the conservative direction: the caller is told the units
        // are too small to account for, rather than being granted them free.
        level = levelNow.add(amount);
        if (!level.gt(levelNow)) {
            revert LeakyBucketAmountNotCredited(levelNow, amount);
        }
    }
}
