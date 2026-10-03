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
/// @param leakRate Units leaked per unit of time.
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

    /// `level` after `elapsed` of leak, saturating at zero.
    function leak(Float level, Float elapsed, Float leakRate) private pure returns (Float) {
        return saturatingSub(level, elapsed.mul(leakRate));
    }

    /// The level recorded at `checkpoint` leaked forward to `timestamp`.
    ///
    /// The elapsed time saturates at zero, so a `timestamp` before the
    /// checkpoint leaks nothing rather than crediting a negative elapsed
    /// against the level.
    function levelAt(Float level, Float checkpoint, Float timestamp, Float leakRate) private pure returns (Float) {
        return leak(level, saturatingSub(timestamp, checkpoint), leakRate);
    }

    /// `capacity - levelNow`, saturating at zero.
    function headroomFrom(Float capacity, Float levelNow) private pure returns (Float) {
        return saturatingSub(capacity, levelNow);
    }

    /// Reverts on a bucket that cannot answer, so a read refuses exactly where
    /// a fill would.
    ///
    /// A negative capacity admits no fill and a negative leak rate fills the
    /// bucket as time passes, which is the opposite of a leak. A negative level
    /// is headroom above the capacity. None is a stricter bucket, so none is
    /// treated as one.
    function checkFillableDomain(LeakyBucket memory bucket, Float timestamp) private pure {
        if (bucket.capacity.lt(LibDecimalFloat.FLOAT_ZERO)) {
            revert LeakyBucketNegativeCapacity(bucket.capacity);
        }
        if (bucket.leakRate.lt(LibDecimalFloat.FLOAT_ZERO)) {
            revert LeakyBucketNegativeLeakRate(bucket.leakRate);
        }
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

    /// The level after filling `amount` at `timestamp`.
    function fillAt(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate, Float amount)
        private
        pure
        returns (Float)
    {
        if (amount.isZero()) {
            revert LeakyBucketZeroAmount();
        }
        if (amount.lt(LibDecimalFloat.FLOAT_ZERO)) {
            revert LeakyBucketNegativeAmount(amount);
        }
        Float levelNow = levelAt(level, checkpoint, timestamp, leakRate);
        Float headroom = headroomFrom(capacity, levelNow);
        if (amount.gt(headroom)) {
            revert LeakyBucketCapacityExceeded(capacity, levelNow, amount);
        }
        // A positive amount that leaves the level where it was has not been
        // charged. `Float` carries about 67 exact digits, so an amount far
        // enough below the level falls off the tail of the sum and the bucket
        // would report a successful fill having recorded nothing — a mint under
        // a cap it never reached.
        //
        // Refusing is the conservative direction: the caller is told the units
        // are too small to account for, rather than being granted them free.
        Float filled = levelNow.add(amount);
        if (!filled.gt(levelNow)) {
            revert LeakyBucketAmountNotCredited(levelNow, amount);
        }
        return filled;
    }

    /// The outstanding level at `timestamp`, leaked forward from the stored
    /// checkpoint.
    ///
    /// Exported because it cannot be derived from `headroomAt`. `capacity -
    /// headroom` agrees with the level only while the level is at or under the
    /// capacity; the headroom saturates at zero, so once a capacity is lowered
    /// under an outstanding level that subtraction returns the capacity and
    /// silently under-reports what is owed. A caller that wants the level has to
    /// be given it.
    /// @param bucket The bucket. Not modified.
    /// @param timestamp When to read at.
    /// @return The level at `timestamp`.
    function levelAt(LeakyBucket memory bucket, Float timestamp) internal pure returns (Float) {
        checkFillableDomain(bucket, timestamp);
        return levelAt(bucket.level, bucket.timestamp, timestamp, bucket.leakRate);
    }

    /// The most `fill` would accept at `timestamp`: a positive headroom fits
    /// in full and any amount above it is refused. Zero means nothing fits,
    /// and `fill` refuses a zero amount, so check for zero before filling.
    /// Reverts on the same buckets `fill` refuses.
    /// @param bucket The bucket. Not modified.
    /// @param timestamp When to read at.
    /// @return Headroom at `timestamp`.
    function headroomAt(LeakyBucket memory bucket, Float timestamp) internal pure returns (Float) {
        checkFillableDomain(bucket, timestamp);
        return headroomFrom(bucket.capacity, levelAt(bucket.level, bucket.timestamp, timestamp, bucket.leakRate));
    }

    /// Fill `amount` at `timestamp`. The returned checkpoint carries the later
    /// of `timestamp` and the stored timestamp, so a backwards clock never
    /// re-credits leak on the next fill.
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
        level = fillAt(bucket.level, bucket.timestamp, timestamp, bucket.capacity, bucket.leakRate, amount);
        checkpoint = LibDecimalFloat.max(timestamp, bucket.timestamp);
    }
}
