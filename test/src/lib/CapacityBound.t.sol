// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {LibLeakyBucket, LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {LibSaturatingMath} from "rain-math-saturating-0.1.10/src/lib/LibSaturatingMath.sol";
import {WORKED_CAPACITY, WORKED_LEAK_RATE, WORKED_DRAIN} from "../../lib/WorkedPolicy.sol";
import {LibCheckpointWord} from "../../lib/LibCheckpointWord.sol";
import {LeakyBucketScratch} from "../../abstract/LeakyBucketScratch.sol";

/// What `capacity` does and does not bound.
contract CapacityBoundTest is Test, LeakyBucketScratch {
    /// The worked policy the suite examines, from `test/lib/WorkedPolicy.sol`:
    /// a 3600 unit burst draining at one unit per second, so a full bucket
    /// empties in exactly an hour.
    uint256 internal constant CAPACITY = WORKED_CAPACITY;
    uint256 internal constant LEAK_RATE = WORKED_LEAK_RATE;
    uint256 internal constant DRAIN = WORKED_DRAIN;

    /// Idling accrues NO credit beyond the capacity: however long a bucket sits
    /// untouched, the most it can ever offer is one full capacity, and there is
    /// no input that lets waiting bank more than that.
    function testIdleForAThousandDrainTimesStillOffersOneCapacity() external pure {
        assertEq(headroomAt(0, DRAIN * 1000, CAPACITY, LEAK_RATE), CAPACITY);
    }

    /// Filling an empty bucket to the top leaves nothing further to mint, at
    /// that instant.
    function testFillingToCapacityLeavesZeroHeadroom(uint192 capacity, uint256 leakRate, uint64 timestamp)
        external
        pure
    {
        capacity = uint192(bound(capacity, 1, type(uint192).max));
        uint256 filled = fill(LibCheckpointWord.packed(0, timestamp), timestamp, capacity, leakRate, capacity);
        assertEq(LibCheckpointWord.storedLevel(filled), capacity);
        assertEq(headroomAt(filled, timestamp, capacity, leakRate), 0);
    }

    /// No single fill can ever exceed the capacity, whatever the bucket's
    /// history and however long it has idled.
    function testNoSingleFillCanExceedCapacity(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        amount = bound(amount, uint256(capacity) + 1, type(uint256).max);
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 levelNow = levelAt(checkpointWord, timestamp, leakRate);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelNow, amount));
        this.externalFill(checkpointWord, timestamp, capacity, leakRate, amount);
    }

    /// After any accepted fill the level is still within the capacity, unless
    /// it was already above it before the fill, which only a capacity cut can
    /// produce and which then accepts no fill at all.
    function testLevelNeverEndsAboveCapacity(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 levelNow = levelAt(checkpointWord, timestamp, leakRate);
        uint256 headroom = headroomAt(checkpointWord, timestamp, capacity, leakRate);
        vm.assume(headroom > 0);
        amount = bound(amount, 1, headroom);
        uint256 newLevel = LibCheckpointWord.storedLevel(fill(checkpointWord, timestamp, capacity, leakRate, amount));
        assertLe(newLevel, levelNow > capacity ? levelNow : capacity);
    }

    /// The deliberate other half, pinned so it cannot drift: cumulative
    /// throughput DOES grow past the capacity as time passes, at exactly the
    /// leak rate.
    function testRefillIsPacedByLeakRateAndCappedAtCapacity() external pure {
        uint256 filled = fill(0, 0, CAPACITY, LEAK_RATE, CAPACITY);
        assertEq(LibCheckpointWord.storedLevel(filled), CAPACITY);
        assertEq(headroomAt(filled, 0, CAPACITY, LEAK_RATE), 0);

        // Half a drain time later, half the capacity has leaked out.
        assertEq(levelAt(filled, DRAIN / 2, LEAK_RATE), CAPACITY / 2);
        assertEq(headroomAt(filled, DRAIN / 2, CAPACITY, LEAK_RATE), CAPACITY / 2);

        // So 1.5 capacities crossed in half a drain time, and the bucket is
        // full again rather than over full.
        uint256 refilled = fill(filled, DRAIN / 2, CAPACITY, LEAK_RATE, CAPACITY / 2);
        assertEq(LibCheckpointWord.storedLevel(refilled), CAPACITY);
    }

    /// A burst that follows a full drain is capped exactly as the first one
    /// was.
    function testASecondBurstAfterAFullDrainIsCappedTheSame() external {
        uint256 filled = fill(0, 0, CAPACITY, LEAK_RATE, CAPACITY);
        uint256 refilled = fill(filled, DRAIN, CAPACITY, LEAK_RATE, CAPACITY);
        assertEq(LibCheckpointWord.storedLevel(refilled), CAPACITY);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, CAPACITY, CAPACITY, 1));
        this.externalFill(refilled, DRAIN, CAPACITY, LEAK_RATE, 1);
    }

    /// You cannot leak more than the bucket before a mint.
    function testLeakCreditedNeverExceedsTheBucket(
        uint192 level,
        uint64 checkpoint,
        uint192 capacity,
        uint64 earlier,
        uint64 later,
        uint256 leakRate
    ) external pure {
        level = uint192(bound(level, 0, capacity));
        later = uint64(bound(later, earlier, type(uint64).max));
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 levelEarlier = levelAt(checkpointWord, earlier, leakRate);
        uint256 levelLater = levelAt(checkpointWord, later, leakRate);
        // Monotonic in time, so this cannot underflow.
        assertLe(levelEarlier - levelLater, capacity);

        // The identity the docstring names, asserted rather than implied. The
        // bound above cannot fail on its own: `bound(level, 0, capacity)` makes
        // `<= capacity` true for any leak that does not RAISE the level, which
        // `testLeakNeverRaisesLevel` pins, so the only thing left for it to
        // catch is a non-monotonic leak underflowing the subtraction, which
        // `testLevelIsMonotonicInTime` catches already. What neither pins is
        // the SIZE of the leak, and the size is what decides whether the cap
        // converges to the rate the policy names or to something slacker.
        //
        // Credited leak is exactly `min(level, elapsed * leakRate)`, with
        // `elapsed` taken from the checkpoint and saturating at zero behind it.
        // `testLeakIsExactWhereItCannotOverflow` states this for levels up to
        // `uint128` and products that cannot overflow; here it is stated where
        // the product is free to overflow the word, because `leakRate` takes no
        // part in the packing and so is fuzzed over the whole of it.
        uint256 product = LibSaturatingMath.saturatingMul(LibSaturatingMath.saturatingSub(later, checkpoint), leakRate);
        assertEq(level - levelLater, product < level ? product : level);
    }

    /// Consuming the bucket zeroes it immediately, in the same second, not
    /// after some delay and not partially.
    function testConsumedBucketIsZeroImmediatelyThenRefillsBoundedByCapacity(uint64 elapsed) external pure {
        uint256 filled = fill(0, 0, CAPACITY, LEAK_RATE, CAPACITY);

        // Immediately: same timestamp, nothing further fits.
        assertEq(headroomAt(filled, 0, CAPACITY, LEAK_RATE), 0);

        // Afterwards: the refill, bounded by one capacity at every wait.
        assertLe(headroomAt(filled, elapsed, CAPACITY, LEAK_RATE), CAPACITY);
    }
}
