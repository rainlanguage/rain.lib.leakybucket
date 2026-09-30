// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {workedCapacity, workedLeakRate, workedDrain, capacityOver} from "../../lib/WorkedPolicy.sol";
import {LeakyBucketAsserts} from "../../abstract/LeakyBucketAsserts.sol";
import {float} from "../../lib/FloatWords.sol";

/// What `capacity` does and does not bound.
contract CapacityBoundTest is LeakyBucketAsserts {
    using LibDecimalFloat for Float;

    /// Idling accrues NO credit beyond the capacity: however long a bucket sits
    /// untouched, the most it can ever offer is one full capacity, and there is
    /// no input that lets waiting bank more than that.
    function testIdleForAThousandDrainTimesStillOffersOneCapacity() external pure {
        assertFloatEq(
            headroomAt(float(0), float(0), float(workedDrain() * 1000), workedCapacity(), workedLeakRate()),
            workedCapacity()
        );
    }

    /// Filling an empty bucket to the top leaves nothing further to mint, at
    /// that instant.
    function testFillingToCapacityLeavesZeroHeadroom(uint256 capacity, uint256 leakRate, uint256 timestamp)
        external
        pure
    {
        capacity = bound(capacity, 1, MAX_LEVEL);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);
        timestamp = bound(timestamp, 0, MAX_TIME);

        Float capacityFloat = float(capacity);
        (Float level, Float checkpoint) =
            fill(float(0), float(timestamp), float(timestamp), capacityFloat, float(leakRate), capacityFloat);
        assertFloatEq(level, capacityFloat);
        assertFloatEq(headroomAt(level, checkpoint, float(timestamp), capacityFloat, float(leakRate)), float(0));
    }

    /// No single fill can ever exceed the capacity, whatever the bucket's
    /// history and however long it has idled.
    function testNoSingleFillCanExceedCapacity(
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
        amount = bound(amount, capacity + 1, MAX_LEVEL + 1);

        Float levelNow = levelAt(float(level), float(checkpoint), float(timestamp), float(leakRate), probeCapacity());
        assertCapacityExceeded(
            fillRefused(
                float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate), float(amount)
            ),
            float(capacity),
            levelNow,
            float(amount)
        );
    }

    /// After any accepted fill the level is still within the capacity, unless
    /// it was already above it before the fill, which only a capacity cut can
    /// produce and which then accepts no fill at all.
    function testLevelNeverEndsAboveCapacity(
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

        Float levelNow = levelAt(float(level), float(checkpoint), float(timestamp), float(leakRate), probeCapacity());
        Float headroom = headroomAt(float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate));
        // Every level here is a whole number, so the headroom is one too and
        // converts back to a word the fuzzer can be bounded against.
        uint256 headroomWord = headroom.toFixedDecimalLossless(0);
        vm.assume(headroomWord > 0);
        amount = bound(amount, 1, headroomWord);

        (Float newLevel,) =
            fill(float(level), float(checkpoint), float(timestamp), float(capacity), float(leakRate), float(amount));
        assertTrue(newLevel.lte(LibDecimalFloat.max(levelNow, float(capacity))));
    }

    /// The deliberate other half, pinned so it cannot drift: cumulative
    /// throughput DOES grow past the capacity as time passes, at exactly the
    /// leak rate.
    function testRefillIsPacedByLeakRateAndCappedAtCapacity() external pure {
        (Float filled, Float checkpoint) =
            fill(float(0), float(0), float(0), workedCapacity(), workedLeakRate(), workedCapacity());
        assertFloatEq(filled, workedCapacity());
        assertFloatEq(headroomAt(filled, checkpoint, float(0), workedCapacity(), workedLeakRate()), float(0));

        // Half a drain time later, half the capacity has leaked out.
        Float half = float(workedDrain() / 2);
        assertFloatEq(levelAt(filled, checkpoint, half, workedLeakRate(), workedCapacity()), capacityOver(2));
        assertFloatEq(headroomAt(filled, checkpoint, half, workedCapacity(), workedLeakRate()), capacityOver(2));

        // So 1.5 capacities crossed in half a drain time, and the bucket is
        // full again rather than over full.
        (Float refilled,) = fill(filled, checkpoint, half, workedCapacity(), workedLeakRate(), capacityOver(2));
        assertFloatEq(refilled, workedCapacity());
    }

    /// A burst that follows a full drain is capped exactly as the first one
    /// was.
    function testASecondBurstAfterAFullDrainIsCappedTheSame() external view {
        (Float filled, Float checkpoint) =
            fill(float(0), float(0), float(0), workedCapacity(), workedLeakRate(), workedCapacity());
        (Float refilled, Float refilledAt) =
            fill(filled, checkpoint, float(workedDrain()), workedCapacity(), workedLeakRate(), workedCapacity());
        assertFloatEq(refilled, workedCapacity());

        assertCapacityExceeded(
            fillRefused(refilled, refilledAt, float(workedDrain()), workedCapacity(), workedLeakRate(), float(1)),
            workedCapacity(),
            workedCapacity(),
            float(1)
        );
    }

    /// You cannot leak more than the bucket before a mint.
    function testLeakCreditedNeverExceedsTheBucket(
        uint256 level,
        uint256 checkpoint,
        uint256 capacity,
        uint256 earlier,
        uint256 later,
        uint256 leakRate
    ) external pure {
        capacity = bound(capacity, 0, MAX_LEVEL);
        level = bound(level, 0, capacity);
        checkpoint = bound(checkpoint, 0, MAX_TIME);
        earlier = bound(earlier, 0, MAX_TIME);
        later = bound(later, earlier, MAX_TIME);
        leakRate = bound(leakRate, 0, MAX_LEAK_RATE);

        Float levelEarlier = levelAt(float(level), float(checkpoint), float(earlier), float(leakRate), probeCapacity());
        Float levelLater = levelAt(float(level), float(checkpoint), float(later), float(leakRate), probeCapacity());
        // Monotonic in time, so this cannot go negative.
        assertTrue(levelEarlier.sub(levelLater).lte(float(capacity)));

        // The identity the docstring names, asserted rather than implied. The
        // bound above cannot fail on its own: `bound(level, 0, capacity)` makes
        // `<= capacity` true for any leak that does not RAISE the level, which
        // `testLeakNeverRaisesLevel` pins, so the only thing left for it to
        // catch is a non-monotonic leak taking the difference below zero, which
        // `testLevelIsMonotonicInTime` catches already. What neither pins is
        // the SIZE of the leak, and the size is what decides whether the cap
        // converges to the rate the policy names or to something slacker.
        //
        // Credited leak is exactly `min(level, elapsed * leakRate)`, with
        // `elapsed` taken from the checkpoint and saturated at zero behind it.
        // The leak rate is fuzzed up to `2**128` against a level of at most the
        // same, so the product is free to run many bucket-fulls past the level
        // and the `min` is what holds it. There is no word for it to overflow
        // any more; `saturatingSub` at zero is the whole of what the old
        // saturating arithmetic left behind, and it is this identity that says where it binds.
        Float elapsed = LibDecimalFloat.max(float(later).sub(float(checkpoint)), float(0));
        Float product = elapsed.mul(float(leakRate));
        assertFloatEq(float(level).sub(levelLater), LibDecimalFloat.min(product, float(level)));
    }

    /// Consuming the bucket zeroes it immediately, in the same second, not
    /// after some delay and not partially.
    function testConsumedBucketIsZeroImmediatelyThenRefillsBoundedByCapacity(uint256 elapsed) external pure {
        elapsed = bound(elapsed, 0, MAX_TIME);
        (Float filled, Float checkpoint) =
            fill(float(0), float(0), float(0), workedCapacity(), workedLeakRate(), workedCapacity());

        // Immediately: same timestamp, nothing further fits.
        assertFloatEq(headroomAt(filled, checkpoint, float(0), workedCapacity(), workedLeakRate()), float(0));

        // Afterwards: the refill, bounded by one capacity at every wait.
        assertTrue(
            headroomAt(filled, checkpoint, float(elapsed), workedCapacity(), workedLeakRate()).lte(workedCapacity())
        );
    }
}
