// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {LibLeakyBucket, LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
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

    /// The two boundaries of `fillableAt` that the bounded fuzz tests step
    /// around, worked as concrete numbers.
    ///
    /// Neither is an uncovered behaviour: the fuzz test already kills a guard
    /// flipped to `>=` and both a floored and a truncated wait. What it does
    /// not do is state the answers. It finds them by drawing an input that
    /// happens to sit on the boundary, which depends on the seed, and it never
    /// writes down which way the division rounds. `amount == capacity` is
    /// excluded by construction from the two bounded tests either side of it,
    /// and every other concrete example of `fillableAt` in the suite picks a
    /// deficit that is an exact multiple of the rate, where ceiling and floor
    /// agree. So the rounding direction is nowhere in writing, and the
    /// boundary is only ever hit by chance.
    function testFillableAtBoundariesOfAmountAndRounding() external pure {
        uint256 capacity = 3600e18;
        uint256 level = 3600e18;
        uint256 checkpoint = 1000;

        // `amount == capacity` is the EQUAL side of the `amount > capacity`
        // guard: possible, and it needs the bucket completely empty. One
        // capacity out of a full bucket at one unit a second is 3600 seconds.
        uint256 at = LibLeakyBucket.fillableAt(level, checkpoint, checkpoint, capacity, 1e18, capacity);
        assertEq(at, checkpoint + 3600);
        assertEq(LibLeakyBucket.levelAt(level, checkpoint, at, 1e18), 0);
        assertEq(LibLeakyBucket.headroomAt(level, checkpoint, at, capacity, 1e18), capacity);
        assertLt(LibLeakyBucket.headroomAt(level, checkpoint, at - 1, capacity, 1e18), capacity);

        // And one unit past the capacity is the strict side: never. The two
        // together are what make the guard `>` rather than `>=`.
        assertEq(
            LibLeakyBucket.fillableAt(level, checkpoint, checkpoint, capacity, 1e18, capacity + 1), type(uint256).max
        );

        // The wait rounds UP. At 7e18 a second a full 3600e18 bucket drains in
        // 514.28... seconds, so the answer is the 515th second and not the
        // 514th. A floor division would name 514, where 2e18 is still
        // outstanding and one capacity does not fit.
        uint256 odd = LibLeakyBucket.fillableAt(level, checkpoint, checkpoint, capacity, 7e18, capacity);
        assertEq(odd, checkpoint + 515);
        assertEq(LibLeakyBucket.levelAt(level, checkpoint, checkpoint + 514, 7e18), 2e18);
        assertLt(LibLeakyBucket.headroomAt(level, checkpoint, checkpoint + 514, capacity, 7e18), capacity);
        assertEq(LibLeakyBucket.headroomAt(level, checkpoint, odd, capacity, 7e18), capacity);
    }
}
