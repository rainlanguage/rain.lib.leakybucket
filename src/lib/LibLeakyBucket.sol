// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {
    LibDecimalFloatImplementation
} from "rain-math-float-0.2.4/src/lib/implementation/LibDecimalFloatImplementation.sol";

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
/// The one saturation is at zero: a leak never takes the level below it and a
/// backwards clock credits no leak. A leak too large for a `Float` is a leak
/// above the level like any other, so it drains the bucket and nothing reverts.
library LibLeakyBucket {
    using LibDecimalFloat for Float;

    /// `a - b`, saturating at zero.
    function saturatingSub(Float a, Float b) private pure returns (Float) {
        return LibDecimalFloat.max(a.sub(b), LibDecimalFloat.FLOAT_ZERO);
    }

    /// The level of `bucket` at `timestamp`, saturating at zero, with nothing
    /// checked. A backwards clock leaks nothing.
    ///
    /// `LibDecimalFloat.mul` reverts on a product whose exponent does not fit a
    /// `Float`, which would refuse every call on the bucket for good. The leak
    /// is multiplied and compared unpacked instead, where the exponent has 256
    /// bits, and only a level is ever packed.
    function leakedLevel(LeakyBucket memory bucket, Float timestamp) private pure returns (Float) {
        (int256 elapsedCoefficient, int256 elapsedExponent) = saturatingSub(timestamp, bucket.timestamp).unpack();
        (int256 rateCoefficient, int256 rateExponent) = bucket.leakRate.unpack();
        (int256 leakCoefficient, int256 leakExponent) =
            LibDecimalFloatImplementation.mul(elapsedCoefficient, elapsedExponent, rateCoefficient, rateExponent);
        (int256 levelCoefficient, int256 levelExponent) = bucket.level.unpack();
        if (LibDecimalFloatImplementation.gte(leakCoefficient, leakExponent, levelCoefficient, levelExponent)) {
            return LibDecimalFloat.FLOAT_ZERO;
        }
        (levelCoefficient, levelExponent) =
            LibDecimalFloatImplementation.sub(levelCoefficient, levelExponent, leakCoefficient, leakExponent);
        return LibDecimalFloat.packArithmeticResult(levelCoefficient, levelExponent);
    }

    /// The later of `timestamp` and the stored timestamp, so a backwards clock
    /// never moves the checkpoint back.
    function checkpointAt(LeakyBucket memory bucket, Float timestamp) private pure returns (Float) {
        return LibDecimalFloat.max(timestamp, bucket.timestamp);
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
        return leakedLevel(bucket, timestamp);
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
        return (leakedLevel(bucket, timestamp), checkpointAt(bucket, timestamp));
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
    /// Reverts on a negative `capacity` or `leakRate`, so neither is stored.
    /// The stored policy is being replaced, so it is not checked, and a bucket
    /// refused everywhere else for its stored policy takes a new one here. A
    /// stored leak rate that is negative is no rate to settle at: no leak is
    /// credited and the checkpoint still moves.
    ///
    /// A negative stored level or timestamp is refused here as everywhere. No
    /// policy repairs one; the caller rewrites the field.
    /// @param bucket The bucket under its stored policy. Not modified.
    /// @param timestamp When the new policy starts. Behind the stored
    /// timestamp, the policy starts at the stored one: nothing is leaked and
    /// the checkpoint stays.
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
        Float level = bucket.leakRate.lt(LibDecimalFloat.FLOAT_ZERO) ? bucket.level : leakedLevel(bucket, timestamp);
        return
            LeakyBucket({
                level: level, timestamp: checkpointAt(bucket, timestamp), capacity: capacity, leakRate: leakRate
            });
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
        Float levelNow = leakedLevel(bucket, timestamp);
        checkpoint = checkpointAt(bucket, timestamp);
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
