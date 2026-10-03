// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {
    LeakyBucket,
    LeakyBucketCapacityExceeded,
    LeakyBucketNegativeAmount,
    LeakyBucketNegativeCapacity,
    LeakyBucketNegativeLeakRate,
    LeakyBucketNegativeLevel,
    LeakyBucketNegativeTimestamp,
    LeakyBucketZeroAmount,
    LibLeakyBucket
} from "../../../src/lib/LibLeakyBucket.sol";
import {LibLeakyBucketSlow} from "../../lib/LibLeakyBucketSlow.sol";
import {workedCapacity, workedDrain, workedLeakRate} from "../../lib/WorkedPolicy.sol";
import {LeakyBucketAsserts} from "../../abstract/LeakyBucketAsserts.sol";
import {float, signedFloat} from "../../lib/FloatWords.sol";

/// Properties of the bucket itself, stated as invariants over the whole input
/// space rather than as a table of worked examples.
contract LibLeakyBucketTest is LeakyBucketAsserts {
    using LibDecimalFloat for Float;

    // ---------------------------------------------------------------- //
    //                              The leak                             //
    // ---------------------------------------------------------------- //

    /// Leaking can only ever lower the level, at every input.
    function testLeakNeverRaisesLevel(uint256 level, uint256 checkpoint, uint256 timestamp, uint256 leakRate)
        external
        pure
    {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        assertFloatLe(
            levelAt(float(level), float(checkpoint), float(timestamp), float(leakRate), probeCapacity()), float(level)
        );
    }

    /// A zero rate is a bucket that does not drain, forever.
    function testLeakRateZeroNeverLeaks(uint256 level, uint256 checkpoint, uint256 timestamp) external pure {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        assertFloatEq(
            levelAt(float(level), float(checkpoint), float(timestamp), float(0), probeCapacity()), float(level)
        );
    }

    /// No time, no leak.
    function testLeakZeroElapsedNeverLeaks(uint256 level, uint256 checkpoint, uint256 leakRate) external pure {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        assertFloatEq(
            levelAt(float(level), float(checkpoint), float(checkpoint), float(leakRate), probeCapacity()), float(level)
        );
    }

    /// The leak is exactly `elapsed * rate`, floored at empty.
    ///
    /// The old claim was hedged with "where the product cannot overflow",
    /// because a `uint256` product of a 64 bit elapsed and a 256 bit rate could.
    /// A `Float` product cannot, so within the precision bounds above the claim
    /// is unconditional.
    function testLeakIsExact(uint256 level, uint256 elapsed, uint256 leakRate) external pure {
        level = bound(level, 0, MAX_LEVEL);
        elapsed = bound(elapsed, 0, MAX_TIME);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        uint256 leaked = elapsed * leakRate;
        assertFloatEq(
            levelAt(float(level), float(0), float(elapsed), float(leakRate), probeCapacity()),
            leaked < level ? float(level - leaked) : float(0)
        );
    }

    /// A leak larger than the level empties the bucket, and empty is the exact
    /// answer here rather than a conservative one.
    ///
    /// The old bucket reached this case by overflowing the product, which was a
    /// leak wider than any representable level and so saturated. There is no
    /// width to overflow now; what is left is `saturatingSub` at zero, which is the
    /// property the bucket actually has.
    function testLeakLargerThanTheLevelEmptiesBucket(uint256 level, uint256 extra, uint256 leakRate) external pure {
        level = bound(level, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 1, MAX_LEAK_RATE);
        // Long enough at this rate to have leaked past whatever the level was.
        uint256 elapsed = level / leakRate + 1 + bound(extra, 0, MAX_TIME);
        assertFloatEq(levelAt(float(level), float(0), float(elapsed), float(leakRate), probeCapacity()), float(0));
    }

    /// The closed form agrees with draining one unit of time at a time,
    /// everywhere the loop is affordable to run.
    function testLeakAgainstUnitSteps(uint256 level, uint256 elapsed, uint256 leakRate) external pure {
        level = bound(level, 0, MAX_LEVEL);
        elapsed = bound(elapsed, 0, 512);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        assertFloatEq(
            levelAt(float(level), float(0), float(elapsed), float(leakRate), probeCapacity()),
            LibLeakyBucketSlow.leakSlow(float(level), elapsed, float(leakRate))
        );
    }

    /// A clock at or behind the checkpoint credits no leak.
    function testBackwardsClockCreditsNoLeak(uint256 level, uint256 checkpoint, uint256 timestamp, uint256 leakRate)
        external
        pure
    {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, checkpoint);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        assertFloatEq(
            levelAt(float(level), float(checkpoint), float(timestamp), float(leakRate), probeCapacity()), float(level)
        );
    }

    /// Later never reads fuller.
    function testLevelIsMonotonicInTime(
        uint256 level,
        uint256 checkpoint,
        uint256 earlier,
        uint256 later,
        uint256 leakRate
    ) external pure {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        earlier = bound(earlier, 0, MAX_TIME);
        later = bound(later, earlier, MAX_TIME);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        assertFloatLe(
            levelAt(float(level), float(checkpoint), float(later), float(leakRate), probeCapacity()),
            levelAt(float(level), float(checkpoint), float(earlier), float(leakRate), probeCapacity())
        );
    }

    // ---------------------------------------------------------------- //
    //                        Headroom and filling                       //
    // ---------------------------------------------------------------- //

    /// Headroom is capacity minus the level, floored at zero, so it is never
    /// more than the capacity and never goes negative when the level is above
    /// it.
    function testHeadroomNeverExceedsCapacity(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate
    ) external pure {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        assertFloatLe(
            headroomAt(float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate)),
            float(capacity)
        );
    }

    /// Whatever `headroomAt` reports is a fill `fill` takes IN FULL, at every
    /// input it will answer at all; a zero headroom is a zero fill, refused.
    function testHeadroomIsAlwaysFillable(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate
    ) external {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);

        Float levelNow = levelAt(float(level), float(checkpoint), float(timestamp), float(leakRate), probeCapacity());
        Float headroom = headroomAt(float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate));
        if (headroom.isZero()) {
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketZeroAmount.selector));
            this.externalFill(
                float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate), float(0)
            );
            return;
        }

        (Float newLevel,) =
            fill(float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate), headroom);

        // The fill was taken in full, not silently dropped or saturated.
        assertFloatEq(newLevel, levelNow.add(headroom));
        // And it lands exactly at the capacity, unless the bucket was already
        // above it, in which case the only headroom on offer was zero.
        assertFloatEq(newLevel, levelNow.gt(float(capacity)) ? levelNow : float(capacity));
    }

    /// The other half: one unit past the reported headroom is always rejected,
    /// with the capacity that was in force, the level at that second and the
    /// amount that did not fit.
    function testFillRejectsOneUnitPastTheHeadroom(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate
    ) external view {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);

        // Every level here is a whole number, so the headroom is one too and
        // converts back to a word that "one more" can be counted on.
        uint256 amount = headroomAt(float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate))
            .toFixedDecimalLossless(0) + 1;

        assertCapacityExceeded(
            fillRefused(
                float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate), float(amount)
            ),
            float(capacity),
            levelAt(float(level), float(checkpoint), float(timestamp), float(leakRate), probeCapacity()),
            float(amount)
        );
    }

    /// Filling over the headroom reverts with the same error whatever the
    /// overshoot, and nothing is written.
    function testFillRevertsOverHeadroom(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external view {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);

        uint256 headroom = headroomAt(
                float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate)
            ).toFixedDecimalLossless(0);
        amount = bound(amount, headroom + 1, headroom + 1 + MAX_LEVEL);

        assertCapacityExceeded(
            fillRefused(
                float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate), float(amount)
            ),
            float(capacity),
            levelAt(float(level), float(checkpoint), float(timestamp), float(leakRate), probeCapacity()),
            float(amount)
        );
    }

    /// A zero fill is refused at every level.
    function testFillRejectsZeroAmount(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate
    ) external {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketZeroAmount.selector));
        this.externalFill(float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate), float(0));
    }

    /// A negative fill is refused at every level, BY NAME.
    ///
    /// The old library had no such case: an amount was a `uint256` and the type
    /// carried the sign. It is a `Float` now, so a fill that drains the bucket
    /// — and so mints under a cap it never reached — is expressible, and is
    /// rejected rather than applied.
    function testFillRejectsANegativeAmount(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        int256 amount
    ) external {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        Float amountFloat = signedFloat(bound(amount, -MAX_SIGNED, -1));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeAmount.selector, amountFloat));
        this.externalFill(
            float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate), amountFloat
        );
    }

    /// Lowering capacity under an outstanding level needs no migration and no
    /// fill to take effect.
    function testCapacityLoweredBelowLevelBindsImmediatelyThenDrains() external view {
        Float leakRate = float(1);
        Float checkpoint = float(1000);
        Float level = float(100);

        // Capacity cut to a quarter of what is already outstanding.
        Float capacity = float(25);

        assertFloatEq(headroomAt(level, checkpoint, checkpoint, capacity, leakRate), float(0));
        assertCapacityExceeded(
            fillRefused(level, checkpoint, checkpoint, capacity, leakRate, float(1)), capacity, level, float(1)
        );

        // Still bound most of the way down.
        assertFloatEq(headroomAt(level, checkpoint, float(1000 + 74), capacity, leakRate), float(0));

        // 75 units of time at one per unit leaks 75, reaching the new capacity
        // exactly.
        assertFloatEq(levelAt(level, checkpoint, float(1000 + 75), leakRate, probeCapacity()), float(25));
        assertFloatEq(headroomAt(level, checkpoint, float(1000 + 75), capacity, leakRate), float(0));

        // And from there it behaves as an ordinary bucket at the new capacity.
        assertFloatEq(headroomAt(level, checkpoint, float(1000 + 85), capacity, leakRate), float(10));
        (Float newLevel,) = fill(level, checkpoint, float(1000 + 85), capacity, leakRate, float(10));
        assertFloatEq(newLevel, float(25));
    }

    /// The security property on a worked policy: every burst is capped at the
    /// capacity, including the ones that come after a full drain.
    function testEachRepeatBurstIsCappedAtCapacity() external view {
        Float t0 = float(1_700_000_000);

        // Burst the whole capacity at once out of an empty bucket.
        (Float level, Float checkpoint) = fill(float(0), t0, t0, workedCapacity(), workedLeakRate(), workedCapacity());
        assertFloatEq(level, workedCapacity());

        // Immediately after, nothing more fits.
        assertFloatEq(headroomAt(level, checkpoint, t0, workedCapacity(), workedLeakRate()), float(0));

        // The drain time for a full bucket, and the first moment it is empty.
        // The worked leak rate divides the worked capacity exactly, so there is
        // no remainder left standing at that moment.
        Float drained = float(1_700_000_000 + workedDrain());
        assertFloatEq(levelAt(level, checkpoint, drained, workedLeakRate(), probeCapacity()), float(0));

        // A second burst lands, so `2 * capacity` crossed in one drain window.
        Float next = float(1_700_000_000 + workedDrain() + 1);
        (Float refilled, Float refilledAt) =
            fill(level, checkpoint, next, workedCapacity(), workedLeakRate(), workedCapacity());
        assertFloatEq(refilled, workedCapacity());

        // And no third burst: the bound is `capacity + elapsed * leakRate`.
        assertCapacityExceeded(
            fillRefused(refilled, refilledAt, next, workedCapacity(), workedLeakRate(), float(1)),
            workedCapacity(),
            workedCapacity(),
            float(1)
        );
    }

    // ---------------------------------------------------------------- //
    //                  The level and the checkpoint back                //
    // ---------------------------------------------------------------- //

    /// The property the second return exists for: a successful fill hands back
    /// the new level *and* a timestamp that level actually belongs to.
    ///
    /// The old library packed the two into one word and this was the property
    /// the packing existed for. The word is gone and the pair is not, so the
    /// claim outlives the layout that used to carry it.
    function testFillCarriesTheTimestampWithTheLevel(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);

        uint256 headroom = headroomAt(
                float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate)
            ).toFixedDecimalLossless(0);
        vm.assume(headroom > 0);
        amount = bound(amount, 1, headroom);

        (Float newLevel, Float newTimestamp) =
            fill(float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate), float(amount));

        assertFloatGe(newTimestamp, float(checkpoint));
        assertFloatGe(newTimestamp, float(timestamp));
        assertFloatLe(newTimestamp, float(timestamp > checkpoint ? timestamp : checkpoint));

        assertFloatEq(
            newLevel,
            levelAt(float(level), float(checkpoint), newTimestamp, float(leakRate), probeCapacity()).add(float(amount))
        );
    }

    /// `fill` returns the new level and checkpoint, and touches nothing it was
    /// handed.
    function testFillMutatesNothingItIsHanded(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);

        uint256 headroom = headroomAt(
                float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate)
            ).toFixedDecimalLossless(0);
        vm.assume(headroom > 0);
        amount = bound(amount, 1, headroom);

        LeakyBucket memory handed = bucket(float(level), float(checkpoint), float(capacity), float(leakRate));
        LibLeakyBucket.fill(handed, float(timestamp), float(amount));

        // Bit for bit, not number for number: a field rewritten to another
        // spelling of the same number is still a field that was written.
        assertEq(Float.unwrap(handed.level), Float.unwrap(float(level)), "level");
        assertEq(Float.unwrap(handed.timestamp), Float.unwrap(float(checkpoint)), "timestamp");
        assertEq(Float.unwrap(handed.capacity), Float.unwrap(float(capacity)), "capacity");
        assertEq(Float.unwrap(handed.leakRate), Float.unwrap(float(leakRate)), "leakRate");
    }

    /// A zeroed bucket is an empty bucket checkpointed at the epoch, so an
    /// untouched slot needs no initializer.
    ///
    /// The old form of this was about a zero WORD, because the level and the
    /// timestamp shared one. They are separate fields now and the claim is the
    /// same for each: the zero `Float` is the number zero, so a slot that was
    /// never written reads as empty at the epoch rather than as nonsense.
    function testZeroBucketIsEmptyAtEpoch() external pure {
        LeakyBucket memory untouched;
        assertEq(Float.unwrap(untouched.level), bytes32(0), "level");
        assertEq(Float.unwrap(untouched.timestamp), bytes32(0), "timestamp");
        assertFloatEq(untouched.level, float(0));
        assertFloatEq(untouched.timestamp, float(0));

        assertFloatEq(
            levelAt(untouched.level, untouched.timestamp, float(0), workedLeakRate(), probeCapacity()), float(0)
        );
        assertFloatEq(
            headroomAt(untouched.level, untouched.timestamp, float(0), workedCapacity(), workedLeakRate()),
            workedCapacity()
        );
    }

    /// Reading a bucket is total on the fillable domain: whatever the level and
    /// whatever the clock says, a non-negative capacity and leak rate answer
    /// rather than revert.
    ///
    /// The old claim was about bits — every 256 bit word was some valid bucket,
    /// so a slot holding arbitrary bits read as one. A bucket is four `Float`s
    /// now rather than a word, and the two fields that can be meaningless are
    /// refused BY NAME instead of read, which
    /// `testEntryPointsAnswerOnExactlyTheFillableDomain` pins. What is left of
    /// the old claim is this: inside that domain there is nothing else to
    /// refuse.
    function testEveryBucketInTheDomainReads(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate
    ) external pure {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        headroomAt(float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate));
    }

    /// A fill at a timestamp *behind* the stored checkpoint must not move the
    /// checkpoint back to it.
    function testFillBehindTheCheckpointGrantsNoHeadroom() external pure {
        (Float nearlyFull, Float nearlyFullAt) =
            fill(float(0), float(0), float(1000), workedCapacity(), workedLeakRate(), float(3599));
        assertFloatEq(nearlyFull, float(3599));
        assertFloatEq(nearlyFullAt, float(1000));

        // The last unit goes in at a clock behind the checkpoint: the level
        // moves, the checkpoint stays at 1000.
        (Float backwards, Float backwardsAt) =
            fill(nearlyFull, nearlyFullAt, float(500), workedCapacity(), workedLeakRate(), float(1));
        assertFloatEq(backwards, float(3600));
        assertFloatEq(backwardsAt, float(1000));

        (Float full, Float fullAt) =
            fill(float(0), float(0), float(1000), workedCapacity(), workedLeakRate(), workedCapacity());
        assertFloatEq(headroomAt(backwards, backwardsAt, float(1001), workedCapacity(), workedLeakRate()), float(1));
        assertFloatEq(
            headroomAt(backwards, backwardsAt, float(1001), workedCapacity(), workedLeakRate()),
            headroomAt(full, fullAt, float(1001), workedCapacity(), workedLeakRate())
        );
    }

    /// The general form of the case above.
    function testFillBehindTheCheckpointIsNotObservable(
        uint256 level,
        uint256 checkpoint,
        uint256 behind,
        uint256 capacity,
        uint256 leakRate,
        uint256 later
    ) external pure {
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        behind = bound(behind, 0, checkpoint);
        later = bound(later, checkpoint, MAX_TIME);
        capacity = bound(capacity, 1, MAX_LEVEL);
        level = bound(level, 0, capacity - 1);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);

        (Float filled, Float filledAt) =
            fill(float(level), float(checkpoint), float(behind), float(capacity), float(leakRate), float(1));
        // One unit filled at `behind` is one unit on the level at `checkpoint`.
        assertFloatEq(
            levelAt(filled, filledAt, float(later), float(leakRate), probeCapacity()),
            levelAt(float(level + 1), float(checkpoint), float(later), float(leakRate), probeCapacity())
        );
        assertFloatEq(
            headroomAt(filled, filledAt, float(later), float(capacity), float(leakRate)),
            headroomAt(float(level + 1), float(checkpoint), float(later), float(capacity), float(leakRate))
        );
    }

    /// The headline property of the leak, through the write path, which is the
    /// only path there is.
    function testFillThroughACheckpointHasNoDrift(
        uint256 capacity,
        uint256 leakRate,
        uint256 t0,
        uint256 gapA,
        uint256 gapB
    ) external pure {
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        t0 = bound(t0, 0, MAX_TIME);
        uint256 t1 = bound(gapA, 0, MAX_TIME - t0) + t0;
        uint256 t2 = bound(gapB, 0, MAX_TIME - t1) + t1;

        capacity = bound(capacity, 1, MAX_LEVEL);

        // A hand-built checkpoint of the level at t1 plus one unit.
        Float direct = levelAt(
            levelAt(float(capacity - 1), float(t0), float(t1), float(leakRate), probeCapacity()).add(float(1)),
            float(t1),
            float(t2),
            float(leakRate),
            probeCapacity()
        );

        // The same through a fill of one unit at t1.
        (Float filled, Float filledAt) =
            fill(float(capacity - 1), float(t0), float(t1), float(capacity), float(leakRate), float(1));

        assertFloatEq(direct, levelAt(filled, filledAt, float(t2), float(leakRate), probeCapacity()));
    }

    /// The other half of "a zeroed bucket is a valid initial state", asserted
    /// rather than described because the library warns about it: it cannot tell
    /// a *cleared* level from one that was never written, so clearing a bucket
    /// is a full refund of whatever was outstanding rather than cleanup.
    function testAClearedBucketIsAFullRefundAtTheSameSecond() external pure {
        (Float full, Float fullAt) =
            fill(float(0), float(0), float(1000), workedCapacity(), workedLeakRate(), workedCapacity());
        assertFloatEq(headroomAt(full, fullAt, float(1000), workedCapacity(), workedLeakRate()), float(0));

        // `delete sBuckets[minter]`, or writing a zero level back, is exactly
        // this.
        assertFloatEq(headroomAt(float(0), float(0), float(1000), workedCapacity(), workedLeakRate()), workedCapacity());

        // And it is what an untouched bucket holds, so no read here can
        // distinguish the two. The warning is a warning because the library
        // cannot enforce it.
        LeakyBucket memory untouched;
        assertEq(Float.unwrap(untouched.level), Float.unwrap(float(0)));
        assertEq(Float.unwrap(untouched.timestamp), Float.unwrap(float(0)));
    }

    // ---------------------------------------------------------------- //
    //                          The fillable domain                      //
    // ---------------------------------------------------------------- //

    /// The rule both entry points obey, stated once: **a read answers exactly
    /// where `fill` acts**, and refuses exactly what `fill` refuses, with the
    /// same error carrying the same argument.
    ///
    /// The old domain was everything the packing could hold, and this was
    /// fuzzed over unbounded `uint256` parameters so that the bounds were
    /// checked rather than assumed. Nothing is packed now, so the domain is not
    /// a width at all: it is the SIGN of the capacity and of the leak rate, and
    /// the fuzz runs over both signs of each.
    function testEntryPointsAnswerOnExactlyTheFillableDomain(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        int256 capacity,
        int256 leakRate
    ) external {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        Float capacityFloat = signedFloat(bound(capacity, -MAX_SIGNED, MAX_SIGNED));
        Float leakRateFloat = signedFloat(bound(leakRate, -MAX_SIGNED, MAX_SIGNED));

        if (capacityFloat.lt(float(0))) {
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeCapacity.selector, capacityFloat));
            this.externalHeadroomAt(float(level), float(checkpoint), float(timestamp), capacityFloat, leakRateFloat);
            // The domain is checked before the amount, so a zero amount still
            // reports the capacity.
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeCapacity.selector, capacityFloat));
            this.externalFill(float(level), float(checkpoint), float(timestamp), capacityFloat, leakRateFloat, float(0));
            return;
        }

        if (leakRateFloat.lt(float(0))) {
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLeakRate.selector, leakRateFloat));
            this.externalHeadroomAt(float(level), float(checkpoint), float(timestamp), capacityFloat, leakRateFloat);
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLeakRate.selector, leakRateFloat));
            this.externalFill(float(level), float(checkpoint), float(timestamp), capacityFloat, leakRateFloat, float(0));
            return;
        }

        // Inside the domain both of them answer, and what `headroomAt` names is
        // what `fill` takes.
        Float headroom = headroomAt(float(level), float(checkpoint), float(timestamp), capacityFloat, leakRateFloat);
        if (headroom.isZero()) {
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketZeroAmount.selector));
            this.externalFill(float(level), float(checkpoint), float(timestamp), capacityFloat, leakRateFloat, float(0));
        } else {
            fill(float(level), float(checkpoint), float(timestamp), capacityFloat, leakRateFloat, headroom);
        }
    }

    /// No fill could ever fit a negative capacity, so the library refuses one
    /// rather than answering questions about it.
    ///
    /// This is where the old `LEAKY_BUCKET_LEVEL_MAX` guard went. The old
    /// refusal was of a capacity too WIDE to store; a `Float` capacity has no
    /// width to exceed, and what is left to refuse is the one that is
    /// meaningless.
    function testEntryPointsRejectANegativeCapacity(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        int256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        amount = bound(amount, 0, MAX_LEVEL);
        Float capacityFloat = signedFloat(bound(capacity, -MAX_SIGNED, -1));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeCapacity.selector, capacityFloat));
        this.externalHeadroomAt(float(level), float(checkpoint), float(timestamp), capacityFloat, float(leakRate));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeCapacity.selector, capacityFloat));
        this.externalLevelAt(float(level), float(checkpoint), float(timestamp), capacityFloat, float(leakRate));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeCapacity.selector, capacityFloat));
        this.externalFill(
            float(level), float(checkpoint), float(timestamp), capacityFloat, float(leakRate), float(amount)
        );

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeCapacity.selector, capacityFloat));
        this.externalSettle(float(level), float(checkpoint), float(timestamp), capacityFloat, float(leakRate));
    }

    /// A negative leak rate fills the bucket as time passes, which is the
    /// opposite of a leak, so both entry points refuse it BY NAME and nothing
    /// is stored.
    ///
    /// The old suite refused a `timestamp` the packed field could not hold. The
    /// field is gone and a `Float` holds any clock, so this is the guard that
    /// took its place: the one input that would turn the cap into a faucet.
    function testEntryPointsRejectANegativeLeakRate(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        int256 leakRate,
        uint256 amount
    ) external {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        amount = bound(amount, 0, MAX_LEVEL);
        Float leakRateFloat = signedFloat(bound(leakRate, -MAX_SIGNED, -1));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLeakRate.selector, leakRateFloat));
        this.externalHeadroomAt(float(level), float(checkpoint), float(timestamp), float(capacity), leakRateFloat);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLeakRate.selector, leakRateFloat));
        this.externalLevelAt(float(level), float(checkpoint), float(timestamp), float(capacity), leakRateFloat);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLeakRate.selector, leakRateFloat));
        this.externalFill(
            float(level), float(checkpoint), float(timestamp), float(capacity), leakRateFloat, float(amount)
        );

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLeakRate.selector, leakRateFloat));
        this.externalSettle(float(level), float(checkpoint), float(timestamp), float(capacity), leakRateFloat);
    }

    // ---------------------------------------------------------------- //
    //                               Settle                              //
    // ---------------------------------------------------------------- //

    /// What `settle` returns, against arithmetic done in words rather than
    /// through the library: the level less the leak, floored at zero, and the
    /// later of the two times.
    function testSettleReturnsTheLeakedLevelAndTheLaterTime(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 leakRate
    ) external pure {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);

        uint256 elapsed = timestamp > checkpoint ? timestamp - checkpoint : 0;
        uint256 leaked = elapsed * leakRate;
        uint256 expectedLevel = leaked >= level ? 0 : level - leaked;
        uint256 expectedCheckpoint = timestamp > checkpoint ? timestamp : checkpoint;

        (Float settled, Float settledAt) =
            settle(float(level), float(checkpoint), float(timestamp), probeCapacity(), float(leakRate));
        assertFloatEq(settled, float(expectedLevel));
        assertFloatEq(settledAt, float(expectedCheckpoint));
    }

    /// Under an unchanged rate a settle is invisible: every later read of the
    /// settled bucket is the read of the bucket it was settled from.
    function testSettleUnderAnUnchangedRateChangesNoLaterRead(
        uint256 level,
        uint256 leakRate,
        uint256 t0,
        uint256 gapA,
        uint256 gapB
    ) external pure {
        level = bound(level, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        t0 = bound(t0, 0, MAX_TIME);
        uint256 t1 = bound(gapA, 0, MAX_TIME - t0) + t0;
        uint256 t2 = bound(gapB, 0, MAX_TIME - t1) + t1;

        (Float settled, Float settledAt) = settle(float(level), float(t0), float(t1), probeCapacity(), float(leakRate));
        assertFloatEq(
            levelAt(settled, settledAt, float(t2), float(leakRate), probeCapacity()),
            levelAt(float(level), float(t0), float(t2), float(leakRate), probeCapacity())
        );
    }

    /// The worked example of a rate rise. A bucket of 100 filled at second 0
    /// and leaking 1 a second has earned 10 of headroom by second 10. Raising
    /// the rate to 100 without settling re-rates those ten seconds and offers
    /// the whole capacity at once; settled first, the ten seconds stay priced
    /// at 1 and the new rate starts from second 10.
    function testARateRiseIsRetroactiveUnlessSettled() external pure {
        Float capacity = float(100);

        assertFloatEq(headroomAt(float(100), float(0), float(10), capacity, float(1)), float(10));

        // The rate written alone.
        assertFloatEq(headroomAt(float(100), float(0), float(10), capacity, float(100)), float(100));

        // Settled at the old rate, then the new rate.
        (Float settled, Float settledAt) = settle(float(100), float(0), float(10), capacity, float(1));
        assertFloatEq(settled, float(90));
        assertFloatEq(settledAt, float(10));
        assertFloatEq(headroomAt(settled, settledAt, float(10), capacity, float(2)), float(10));
        assertFloatEq(headroomAt(settled, settledAt, float(15), capacity, float(2)), float(20));
    }

    /// A zero rate pauses the leak only between two settles. Without them the
    /// paused time is leaked at the restored rate.
    function testAZeroRateIsAPauseOnlyWhenSettled() external pure {
        Float capacity = float(100);

        // Never settled: a full bucket at second 0, read at second 1000 at the
        // restored rate, has drained whatever the rate was in between.
        assertFloatEq(headroomAt(float(100), float(0), float(1000), capacity, float(1)), float(100));

        // Settled into the pause at second 10 and out of it at second 1000.
        (Float paused, Float pausedAt) = settle(float(100), float(0), float(10), capacity, float(1));
        (Float resumed, Float resumedAt) = settle(paused, pausedAt, float(1000), capacity, float(0));
        assertFloatEq(resumed, float(90));
        assertFloatEq(resumedAt, float(1000));
        assertFloatEq(headroomAt(resumed, resumedAt, float(1000), capacity, float(1)), float(10));
        assertFloatEq(headroomAt(resumed, resumedAt, float(1005), capacity, float(1)), float(15));
    }

    /// A negative stored level leaks to zero given time, but before it does it
    /// reads as headroom above the capacity. Every entry point refuses it.
    function testEntryPointsRejectANegativeLevel(
        int256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        amount = bound(amount, 0, MAX_LEVEL);
        Float levelFloat = signedFloat(bound(level, -MAX_SIGNED, -1));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLevel.selector, levelFloat));
        this.externalHeadroomAt(levelFloat, float(checkpoint), float(timestamp), float(capacity), float(leakRate));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLevel.selector, levelFloat));
        this.externalLevelAt(levelFloat, float(checkpoint), float(timestamp), float(capacity), float(leakRate));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLevel.selector, levelFloat));
        this.externalFill(
            levelFloat, float(checkpoint), float(timestamp), float(capacity), float(leakRate), float(amount)
        );
    }

    /// What the guard on the level prevents, stated on the numbers: without it
    /// a level of -1 under a capacity of 10 would offer 11.
    function testANegativeLevelCannotBuyHeadroomAboveCapacity() external {
        Float level = signedFloat(-1);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLevel.selector, level));
        this.externalFill(level, float(0), float(0), float(10), float(0), float(11));
    }

    /// A negative stored timestamp is refused by every entry point.
    function testEntryPointsRejectANegativeStoredTimestamp(
        uint256 level,
        int256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        level = bound(level, 0, MAX_LEVEL);
        timestamp = bound(timestamp, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        amount = bound(amount, 0, MAX_LEVEL);
        Float checkpointFloat = signedFloat(bound(checkpoint, -MAX_SIGNED, -1));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeTimestamp.selector, checkpointFloat));
        this.externalHeadroomAt(float(level), checkpointFloat, float(timestamp), float(capacity), float(leakRate));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeTimestamp.selector, checkpointFloat));
        this.externalLevelAt(float(level), checkpointFloat, float(timestamp), float(capacity), float(leakRate));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeTimestamp.selector, checkpointFloat));
        this.externalFill(
            float(level), checkpointFloat, float(timestamp), float(capacity), float(leakRate), float(amount)
        );
    }

    /// A negative timestamp to read or fill at is refused by every entry point.
    function testEntryPointsRejectANegativeTimestamp(
        uint256 level,
        uint256 checkpoint,
        int256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        capacity = bound(capacity, 0, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        amount = bound(amount, 0, MAX_LEVEL);
        Float timestampFloat = signedFloat(bound(timestamp, -MAX_SIGNED, -1));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeTimestamp.selector, timestampFloat));
        this.externalHeadroomAt(float(level), float(checkpoint), timestampFloat, float(capacity), float(leakRate));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeTimestamp.selector, timestampFloat));
        this.externalLevelAt(float(level), float(checkpoint), timestampFloat, float(capacity), float(leakRate));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeTimestamp.selector, timestampFloat));
        this.externalFill(
            float(level), float(checkpoint), timestampFloat, float(capacity), float(leakRate), float(amount)
        );
    }

    /// The guards are on the sign and not the magnitude: a negative fraction
    /// far under one unit is refused like any other negative.
    function testANegativeFractionIsRefusedLikeAnyNegative() external {
        Float tiny = LibDecimalFloat.packLossless(-1, -60);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeLevel.selector, tiny));
        this.externalHeadroomAt(tiny, float(0), float(0), float(10), float(1));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeTimestamp.selector, tiny));
        this.externalHeadroomAt(float(0), tiny, float(0), float(10), float(1));

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketNegativeTimestamp.selector, tiny));
        this.externalHeadroomAt(float(0), float(0), tiny, float(10), float(1));
    }

    /// The other side of that guard: every non-negative capacity is accepted,
    /// at any magnitude and any scale, so the check is a check on the sign and
    /// not a narrowing of the policy space.
    ///
    /// The old form of this bounded the capacity by `LEAKY_BUCKET_LEVEL_MAX`,
    /// which was exported for exactly that purpose. There is no such bound to
    /// assert against, so the fuzz walks the coefficient and the exponent
    /// instead — the two halves a `Float` actually has.
    function testEveryNonNegativeCapacityIsAccepted(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 coefficient,
        int256 exponent
    ) external pure {
        level = bound(level, 0, MAX_LEVEL);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        timestamp = bound(timestamp, 0, MAX_TIME);
        //forge-lint: disable-next-line(unsafe-typecast)
        int256 signedCoefficient = int256(bound(coefficient, 0, uint256(int256(type(int224).max))));

        headroomAt(
            float(level),
            float(checkpoint),
            float(timestamp),
            LibDecimalFloat.packLossless(signedCoefficient, bound(exponent, -1000, 1000)),
            float(0)
        );
    }

    /// At a capacity far wider than any packed field could have held, the
    /// documented agreement still holds exactly: `headroomAt` names the largest
    /// amount `fill` accepts, `fill` accepts it and stores it without
    /// truncating, and one unit more is rejected with the capacity error rather
    /// than with an arithmetic failure.
    ///
    /// `1e60` is the point: it is about `2**199`, so the old library could not
    /// have stored it as a level at all, and one unit on top of it is still an
    /// exact `Float` rather than a rounding of it.
    function testAVeryWideCapacityIsExactlyFillableAndNotTruncated() external view {
        Float capacity = LibDecimalFloat.packLossless(1e60, 0);

        Float headroom = headroomAt(float(0), float(0), float(0), capacity, float(0));
        assertFloatEq(headroom, capacity);

        (Float level, Float checkpoint) = fill(float(0), float(0), float(0), capacity, float(0), headroom);
        assertFloatEq(level, capacity);
        assertFloatEq(checkpoint, float(0));
        // Not truncated: the level that went in is the level that reads back,
        // and it offers nothing further at that same second.
        assertFloatEq(headroomAt(level, checkpoint, float(0), capacity, float(0)), float(0));

        Float overshoot = headroom.add(float(1));
        assertTrue(overshoot.gt(headroom), "one unit was lost");
        assertCapacityExceeded(
            fillRefused(float(0), float(0), float(0), capacity, float(0), overshoot), capacity, float(0), overshoot
        );
    }

    /// The error identities are a published surface: a consumer that catches a
    /// rejection, an indexer, or a frontend decoding a failed simulation all
    /// match on the four byte selector, which is the hash of the signature.
    ///
    /// A `Float` is a user defined value type over `bytes32`, and the ABI names
    /// the underlying type, so that is what the signatures below say.
    function testErrorSelectorsArePinnedToTheirSignatures() external pure {
        assertEq(
            bytes32(LeakyBucketCapacityExceeded.selector),
            bytes32(bytes4(keccak256("LeakyBucketCapacityExceeded(bytes32,bytes32,bytes32)")))
        );
        assertEq(bytes32(LeakyBucketZeroAmount.selector), bytes32(bytes4(keccak256("LeakyBucketZeroAmount()"))));
        assertEq(
            bytes32(LeakyBucketNegativeAmount.selector),
            bytes32(bytes4(keccak256("LeakyBucketNegativeAmount(bytes32)")))
        );
        assertEq(
            bytes32(LeakyBucketNegativeCapacity.selector),
            bytes32(bytes4(keccak256("LeakyBucketNegativeCapacity(bytes32)")))
        );
        assertEq(
            bytes32(LeakyBucketNegativeLeakRate.selector),
            bytes32(bytes4(keccak256("LeakyBucketNegativeLeakRate(bytes32)")))
        );
        assertEq(
            bytes32(LeakyBucketNegativeLevel.selector), bytes32(bytes4(keccak256("LeakyBucketNegativeLevel(bytes32)")))
        );
        assertEq(
            bytes32(LeakyBucketNegativeTimestamp.selector),
            bytes32(bytes4(keccak256("LeakyBucketNegativeTimestamp(bytes32)")))
        );
    }
}
