// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, stdError} from "forge-std-1.16.2/src/Test.sol";
import {
    LibLeakyBucket,
    LeakyBucketCapacityExceeded,
    LEAKY_BUCKET_SECONDS_PER_HOUR,
    LEAKY_BUCKET_SECONDS_PER_DAY,
    LEAKY_BUCKET_SECONDS_PER_WEEK
} from "../../../src/lib/LibLeakyBucket.sol";
import {LibLeakyBucketSlow} from "../../lib/LibLeakyBucketSlow.sol";

/// Properties of the bucket itself, stated as invariants over the whole input
/// space rather than as a table of worked examples. The cap is only as good as
/// the arithmetic under it, so the bounds that make it a cap at all, that the
/// level never rises on its own, never underflows, and never grants headroom
/// that time did not earn, are asserted directly.
contract LibLeakyBucketTest is Test {
    /// `expectRevert` needs an external call boundary.
    function externalFillAt(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure returns (uint256) {
        return LibLeakyBucket.fillAt(level, checkpoint, timestamp, capacity, leakRate, amount);
    }

    /// `expectRevert` needs an external call boundary.
    function externalLeakRatePer(uint256 amountPerPeriod, uint256 period) external pure returns (uint256) {
        return LibLeakyBucket.leakRatePer(amountPerPeriod, period);
    }

    /// Leaking can only ever lower the level, at every input. This is the
    /// underflow guard stated as a property: there is no input where the
    /// subtraction wraps and reports a level above where it started.
    function testLeakNeverRaisesLevel(uint256 level, uint256 elapsed, uint256 leakRate) external pure {
        assertLe(LibLeakyBucket.leak(level, elapsed, leakRate), level);
    }

    /// A zero rate is a bucket that does not drain, forever.
    function testLeakRateZeroNeverLeaks(uint256 level, uint256 elapsed) external pure {
        assertEq(LibLeakyBucket.leak(level, elapsed, 0), level);
    }

    /// No time, no leak.
    function testLeakZeroElapsedNeverLeaks(uint256 level, uint256 leakRate) external pure {
        assertEq(LibLeakyBucket.leak(level, 0, leakRate), level);
    }

    /// Where the product cannot overflow the leak is exactly `elapsed * rate`,
    /// floored at empty. No rounding, no slack.
    function testLeakIsExactWhereItCannotOverflow(uint128 level, uint64 elapsed, uint64 leakRate) external pure {
        uint256 leaked = uint256(elapsed) * uint256(leakRate);
        assertEq(LibLeakyBucket.leak(level, elapsed, leakRate), leaked < level ? level - leaked : 0);
    }

    /// An overflowing product is a leak larger than any representable level, so
    /// the bucket reads empty. The bug this pins is the opposite: a wrapped
    /// product is a small leak, and a small leak on a full bucket is free
    /// headroom.
    function testLeakOverflowingProductEmptiesBucket(uint256 level, uint256 elapsed, uint256 leakRate) external pure {
        elapsed = bound(elapsed, 1 << 128, type(uint256).max);
        leakRate = bound(leakRate, 1 << 128, type(uint256).max);
        assertEq(LibLeakyBucket.leak(level, elapsed, leakRate), 0);
    }

    /// The closed form agrees with draining one second at a time, everywhere
    /// the loop is affordable to run.
    function testLeakAgainstUnitSteps(uint256 level, uint256 elapsed, uint256 leakRate) external pure {
        elapsed = bound(elapsed, 0, 512);
        level = bound(level, 0, type(uint128).max);
        leakRate = bound(leakRate, 0, type(uint128).max);
        assertEq(LibLeakyBucket.leak(level, elapsed, leakRate), LibLeakyBucketSlow.leakSlow(level, elapsed, leakRate));
    }

    /// The conversion is never faster than the policy, and is off by less than
    /// one period's worth. Both halves are the point: rounding down is what
    /// keeps the on chain rate at or under what was approved, and the remainder
    /// bound is what stops "rounds down" being satisfied by a rate of zero.
    ///
    /// Stated over the whole word rather than a narrowed one. Neither product
    /// can overflow: `rate` is `amountPerPeriod / period`, so `rate * period` is
    /// at most `amountPerPeriod`, which is where the subtraction gets its floor
    /// as well.
    function testLeakRatePerNeverExceedsThePolicy(uint256 amountPerPeriod, uint256 period) external pure {
        period = bound(period, 1, type(uint256).max);
        uint256 rate = LibLeakyBucket.leakRatePer(amountPerPeriod, period);
        assertLe(rate * period, amountPerPeriod);
        assertLt(amountPerPeriod - rate * period, period);
    }

    /// A period of zero panics on the division rather than answering. A rate
    /// per no time is not a slower rate or a faster one, so there is nothing to
    /// saturate toward and no conservative direction to pick. This is the one
    /// argument in the library that is a policy being written down rather than
    /// bucket state or a clock, so zero is a caller bug and is treated as one.
    function testLeakRatePerZeroPeriodPanics(uint256 amountPerPeriod) external {
        vm.expectRevert(stdError.divisionError);
        this.externalLeakRatePer(amountPerPeriod, 0);
    }

    /// The constants are the seconds they name, and they nest the way the
    /// calendar does. A wrong one here is the whole hazard the helper exists to
    /// remove, and it would be invisible on chain.
    function testSecondsPerPeriodConstants() external pure {
        assertEq(LEAKY_BUCKET_SECONDS_PER_HOUR, 60 * 60);
        assertEq(LEAKY_BUCKET_SECONDS_PER_DAY, 24 * LEAKY_BUCKET_SECONDS_PER_HOUR);
        assertEq(LEAKY_BUCKET_SECONDS_PER_WEEK, 7 * LEAKY_BUCKET_SECONDS_PER_DAY);
    }

    /// The worked policy from the README: 86400 units a day is one unit a
    /// second, a full day of leak is exactly the day's allowance, and a second
    /// short of a day leaves exactly one unit behind.
    function testLeakRatePerDayIsTheDocumentedConversion() external pure {
        uint256 rate = LibLeakyBucket.leakRatePer(86_400e18, LEAKY_BUCKET_SECONDS_PER_DAY);
        assertEq(rate, 1e18);
        assertEq(LibLeakyBucket.leak(86_400e18, LEAKY_BUCKET_SECONDS_PER_DAY, rate), 0);
        assertEq(LibLeakyBucket.leak(86_400e18, LEAKY_BUCKET_SECONDS_PER_DAY - 1, rate), 1e18);
    }

    /// The hazard the helper exists to remove, shown as a number. Governance
    /// approves a million units a day; the per second rate is 11574074074074074
    /// and change, and typing the daily figure into the per second slot is a
    /// bucket that drains 86400 times too fast. A full capacity refills in
    /// well under one block, so the sustained limit is gone while the burst,
    /// every read and every revert still look exactly right.
    function testLeakRatePerIsTheDifferenceBetweenAPolicyAndNoPolicy() external pure {
        uint256 amountPerDay = 1_000_000e18;
        uint256 capacity = 100_000e18;
        uint256 correct = LibLeakyBucket.leakRatePer(amountPerDay, LEAKY_BUCKET_SECONDS_PER_DAY);
        assertEq(correct, 11_574_074_074_074_074_074);

        // At the correct rate a drained burst of a tenth of the daily
        // allowance takes a tenth of a day to come back: 8640 seconds, plus
        // one, because a rate rounded down is a hair slower than the policy
        // and the wait rounds up to whole seconds. That is the policy working.
        assertEq(LibLeakyBucket.fillableAt(capacity, 0, 0, capacity, correct, capacity), 8641);

        // At the mistyped rate it is back within the same second.
        assertEq(LibLeakyBucket.fillableAt(capacity, 0, 0, capacity, amountPerDay, capacity), 1);
    }

    /// A clock at or behind the checkpoint credits no leak. Not a revert, which
    /// would brick minting until the clock caught up, and not an unsigned wrap,
    /// which would read as billions of years of leak and empty the bucket.
    function testLevelAtBackwardsClockCreditsNoLeak(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 leakRate
    ) external pure {
        timestamp = bound(timestamp, 0, checkpoint);
        assertEq(LibLeakyBucket.levelAt(level, checkpoint, timestamp, leakRate), level);
    }

    /// Later never reads fuller.
    function testLevelAtMonotonicInTime(
        uint256 level,
        uint256 checkpoint,
        uint256 earlier,
        uint256 later,
        uint256 leakRate
    ) external pure {
        later = bound(later, earlier, type(uint256).max);
        assertLe(
            LibLeakyBucket.levelAt(level, checkpoint, later, leakRate),
            LibLeakyBucket.levelAt(level, checkpoint, earlier, leakRate)
        );
    }

    /// The headline property. Checkpointing part way through an interval gives
    /// the identical level to not checkpointing at all, at every input, with no
    /// rounding slack. Call frequency is therefore not observable in the cap,
    /// so a caller cannot gain or lose allowance by touching the bucket more or
    /// less often. Implementations that leak at `capacity / window` per second
    /// take a floor division per checkpoint and fail this.
    function testLevelAtHasNoCheckpointDrift(uint256 level, uint256 t0, uint256 t1, uint256 t2, uint256 leakRate)
        external
        pure
    {
        t1 = bound(t1, t0, type(uint256).max);
        t2 = bound(t2, t1, type(uint256).max);
        assertEq(
            LibLeakyBucket.levelAt(LibLeakyBucket.levelAt(level, t0, t1, leakRate), t1, t2, leakRate),
            LibLeakyBucket.levelAt(level, t0, t2, leakRate)
        );
    }

    /// Headroom is capacity minus the level, floored at zero, so it is never
    /// more than the capacity and never underflows when the level is above it.
    function testHeadroomAtNeverExceedsCapacity(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate
    ) external pure {
        assertLe(LibLeakyBucket.headroomAt(level, checkpoint, timestamp, capacity, leakRate), capacity);
    }

    /// Exactly the reported headroom fits, and one unit more does not. Both
    /// halves matter: the first is the cap not being stricter than it claims,
    /// the second is the cap actually binding.
    function testFillAtAcceptsExactlyHeadroomAndNoMore(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate
    ) external {
        uint256 levelNow = LibLeakyBucket.levelAt(level, checkpoint, timestamp, leakRate);
        uint256 headroom = LibLeakyBucket.headroomAt(level, checkpoint, timestamp, capacity, leakRate);

        assertEq(LibLeakyBucket.fillAt(level, checkpoint, timestamp, capacity, leakRate, headroom), levelNow + headroom);

        // Only where there is a "one more" to offer at all: headroom saturates
        // the word when the capacity does.
        if (headroom == type(uint256).max) {
            return;
        }

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelNow, headroom + 1));
        this.externalFillAt(level, checkpoint, timestamp, capacity, leakRate, headroom + 1);
    }

    /// Filling never leaves the bucket above its capacity, unless it was
    /// already above it, in which case the only accepted fill is zero and the
    /// level is untouched.
    function testFillAtNeverOverfills(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        uint256 levelNow = LibLeakyBucket.levelAt(level, checkpoint, timestamp, leakRate);
        uint256 headroom = LibLeakyBucket.headroomAt(level, checkpoint, timestamp, capacity, leakRate);
        if (amount > headroom) {
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelNow, amount));
            this.externalFillAt(level, checkpoint, timestamp, capacity, leakRate, amount);
        } else {
            uint256 newLevel = LibLeakyBucket.fillAt(level, checkpoint, timestamp, capacity, leakRate, amount);
            assertLe(newLevel, levelNow > capacity ? levelNow : capacity);
        }
    }

    /// A zero fill is accepted at any level, including above capacity, and
    /// moves nothing. It is a checkpoint and nothing else.
    function testFillAtZeroAmountIsCheckpointOnly(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate
    ) external pure {
        assertEq(
            LibLeakyBucket.fillAt(level, checkpoint, timestamp, capacity, leakRate, 0),
            LibLeakyBucket.levelAt(level, checkpoint, timestamp, leakRate)
        );
    }

    /// Lowering capacity under an outstanding level needs no migration and no
    /// fill to take effect. Headroom reads zero immediately, every non zero
    /// fill is rejected, and the bucket leaks down under the new policy until
    /// it fits again. This is what makes a timelocked capacity change safe to
    /// land at an arbitrary moment.
    function testCapacityLoweredBelowLevelBindsImmediatelyThenDrains() external {
        uint256 leakRate = 1e18;
        uint256 level = 100e18;
        uint256 checkpoint = 1000;

        // Capacity cut to a quarter of what is already outstanding.
        uint256 capacity = 25e18;

        assertEq(LibLeakyBucket.headroomAt(level, checkpoint, checkpoint, capacity, leakRate), 0);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, level, 1));
        this.externalFillAt(level, checkpoint, checkpoint, capacity, leakRate, 1);

        // Still bound most of the way down.
        assertEq(LibLeakyBucket.headroomAt(level, checkpoint, checkpoint + 74, capacity, leakRate), 0);

        // 75 seconds at 1e18/s leaks 75e18, reaching the new capacity exactly.
        assertEq(LibLeakyBucket.levelAt(level, checkpoint, checkpoint + 75, leakRate), 25e18);
        assertEq(LibLeakyBucket.headroomAt(level, checkpoint, checkpoint + 75, capacity, leakRate), 0);

        // And from there it behaves as an ordinary bucket at the new capacity.
        assertEq(LibLeakyBucket.headroomAt(level, checkpoint, checkpoint + 85, capacity, leakRate), 10e18);
        assertEq(LibLeakyBucket.fillAt(level, checkpoint, checkpoint + 85, capacity, leakRate, 10e18), 25e18);
    }

    /// The security property on a worked policy: every burst is capped at the
    /// capacity, including the ones that come after a full drain. A full
    /// bucket, a full drain, then a second full burst, and each burst is one
    /// capacity with the unit after it rejected. `leakRate` decides how soon a
    /// burst may be repeated, never how large it may be.
    function testEachRepeatBurstIsCappedAtCapacity() external {
        uint256 capacity = 3600e18;
        // One unit per second, so a full bucket drains in exactly an hour.
        uint256 leakRate = 1e18;
        uint256 t0 = 1_700_000_000;

        // Burst the whole capacity at once out of an empty bucket.
        uint256 level = LibLeakyBucket.fillAt(0, t0, t0, capacity, leakRate, capacity);
        assertEq(level, capacity);

        // Immediately after, nothing more fits.
        assertEq(LibLeakyBucket.headroomAt(level, t0, t0, capacity, leakRate), 0);

        // The drain time for a full bucket, and the first moment it is empty.
        uint256 drain = capacity / leakRate;
        assertEq(LibLeakyBucket.levelAt(level, t0, t0 + drain, leakRate), capacity % leakRate);

        // A second burst lands, so `2 * capacity` crossed in one drain window.
        uint256 refilled = LibLeakyBucket.fillAt(level, t0, t0 + drain + 1, capacity, leakRate, capacity);
        assertEq(refilled, capacity);

        // And no third burst: the bound is `capacity + elapsed * leakRate`.
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, capacity, 1));
        this.externalFillAt(refilled, t0 + drain + 1, t0 + drain + 1, capacity, leakRate, 1);
    }

    /// `fillableAt` names the earliest second the amount fits: it fits then,
    /// and it did not fit a second earlier.
    function testFillableAtIsTheEarliestFittingSecond(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        uint256 at = LibLeakyBucket.fillableAt(level, checkpoint, timestamp, capacity, leakRate, amount);
        if (at == type(uint256).max) {
            return;
        }

        assertGe(at, timestamp);
        assertLe(amount, LibLeakyBucket.headroomAt(level, checkpoint, at, capacity, leakRate));

        if (at > timestamp) {
            assertGt(amount, LibLeakyBucket.headroomAt(level, checkpoint, at - 1, capacity, leakRate));
        }
    }

    /// An amount larger than the capacity never fits, however long anyone
    /// waits, and a bucket that does not drain never makes room.
    function testFillableAtNeverForImpossibleAmounts(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        capacity = bound(capacity, 0, type(uint256).max - 1);
        amount = bound(amount, capacity + 1, type(uint256).max);
        assertEq(LibLeakyBucket.fillableAt(level, checkpoint, timestamp, capacity, leakRate, amount), type(uint256).max);
    }

    /// When the amount already fits the answer is now, not some later second.
    function testFillableAtIsNowWhenItAlreadyFits(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        uint256 headroom = LibLeakyBucket.headroomAt(level, checkpoint, timestamp, capacity, leakRate);
        amount = bound(amount, 0, headroom);
        assertEq(LibLeakyBucket.fillableAt(level, checkpoint, timestamp, capacity, leakRate, amount), timestamp);
    }
}
