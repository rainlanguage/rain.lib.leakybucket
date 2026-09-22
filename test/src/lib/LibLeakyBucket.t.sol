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
    /// and it did not fit a second earlier. Where it names never, never is
    /// true.
    ///
    /// The sentinel used to be returned from unasserted, which made the one
    /// general test of this function blind to exactly the value in question.
    /// A `fillableAt` that answered never too readily satisfied every
    /// assertion in the suite, because the test walked away the moment the
    /// answer was `type(uint256).max`.
    ///
    /// The sentinel is in band, so `type(uint256).max` coming back is not on
    /// its own a claim of never. It is also the honest answer "now" for a
    /// caller whose own clock is the last second the word can name, since a
    /// fit at `timestamp` returns `timestamp`. That collision is separated
    /// here rather than assumed away: where the amount fits at `timestamp`
    /// the answer is now and the clock has to be the top of the word, and
    /// only where it does not fit is never asserted.
    ///
    /// Never is then checked one second below the top of the word rather than
    /// at it, because an arrival of exactly `type(uint256).max` is
    /// representable: the saturating add returns the sentinel both for a wait
    /// landing exactly on the last second and for one landing past the end of
    /// it, so asserting the amount does not fit at `type(uint256).max` would
    /// be asserting a defect. At `type(uint256).max - 1` there is no
    /// ambiguity, whichever route produced the sentinel. An amount larger
    /// than the capacity fits nowhere. A zero rate holds the headroom fixed
    /// forever, so a non fitting amount never fits. A saturated arrival is at
    /// the earliest `type(uint256).max` itself, which is later than the
    /// second being asked about.
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
            if (amount <= LibLeakyBucket.headroomAt(level, checkpoint, timestamp, capacity, leakRate)) {
                // Not never. The amount fits at `timestamp`, so the answer is
                // `timestamp`, and the only clock that answer can collide with
                // the sentinel at is the top of the word.
                assertEq(timestamp, type(uint256).max);
                return;
            }
            assertGt(amount, LibLeakyBucket.headroomAt(level, checkpoint, type(uint256).max - 1, capacity, leakRate));
            return;
        }

        assertGe(at, timestamp);
        assertLe(amount, LibLeakyBucket.headroomAt(level, checkpoint, at, capacity, leakRate));

        if (at > timestamp) {
            assertGt(amount, LibLeakyBucket.headroomAt(level, checkpoint, at - 1, capacity, leakRate));
        }
    }

    /// An amount larger than the capacity never fits, however long anyone
    /// waits. That is the only claim this test makes: `leakRate` is
    /// unconstrained here, but `amount > capacity` short circuits before the
    /// zero rate branch is reached, so nothing about a bucket that does not
    /// drain is exercised by any input to this test.
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
