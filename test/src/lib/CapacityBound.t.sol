// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {LibLeakyBucket, LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {WORKED_CAPACITY, WORKED_LEAK_RATE, WORKED_DRAIN} from "../../lib/WorkedPolicy.sol";
import {LeakyBucketExternal} from "../../abstract/LeakyBucketExternal.sol";

/// What `capacity` does and does not bound.
///
/// These are separated from the rest of the suite because the distinction is
/// the one a reader is most likely to get wrong, in either direction. The
/// bucket is hard bounded by `capacity` at every instant: the level cannot pass
/// it, headroom cannot exceed it no matter how long the bucket idles, and a
/// single fill can never be larger than it. What is NOT bounded by `capacity`
/// is cumulative throughput over time, because a leak that did not let more
/// through over time would not be a leak. Both halves are asserted here so
/// neither can be changed silently.
contract CapacityBoundTest is Test, LeakyBucketExternal {
    /// The worked policy the suite examines, from `test/lib/WorkedPolicy.sol`:
    /// a 3600 unit burst draining at one unit per second, so a full bucket
    /// empties in exactly an hour. `DRAIN` is the quotient of the other two
    /// rather than a restated literal, so it cannot come to mean anything but
    /// "one full drain".
    uint256 internal constant CAPACITY = WORKED_CAPACITY;
    uint256 internal constant LEAK_RATE = WORKED_LEAK_RATE;
    uint256 internal constant DRAIN = WORKED_DRAIN;

    /// Idling accrues NO credit beyond the capacity: however long a bucket sits
    /// untouched, the most it can ever offer is one full capacity, and there is
    /// no input that lets waiting bank more than that. This is the worked-policy
    /// form of it, at a wait long enough that a design which banked credit would
    /// be obvious — a thousand drain times of idling still offers exactly one
    /// capacity, not a thousand. The general form, over arbitrary inputs, is
    /// `testHeadroomAtNeverExceedsCapacity` in `LibLeakyBucket.t.sol`.
    function testIdleForAThousandDrainTimesStillOffersOneCapacity() external pure {
        assertEq(LibLeakyBucket.headroomAt(0, 0, DRAIN * 1000, CAPACITY, LEAK_RATE), CAPACITY);
    }

    /// Filling an empty bucket to the top leaves nothing further to mint, at
    /// that instant. "Zero to full" is "zero headroom".
    function testFillingToCapacityLeavesZeroHeadroom(uint256 capacity, uint256 leakRate, uint256 timestamp)
        external
        pure
    {
        uint256 level = LibLeakyBucket.fillAt(0, timestamp, timestamp, capacity, leakRate, capacity);
        assertEq(level, capacity);
        assertEq(LibLeakyBucket.headroomAt(level, timestamp, timestamp, capacity, leakRate), 0);
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
    ) external {
        // A capacity of exactly `type(uint256).max` has no "larger than" to
        // offer, so the claim is vacuous there and the bound excludes it.
        capacity = bound(capacity, 0, type(uint256).max - 1);
        amount = bound(amount, capacity + 1, type(uint256).max);
        uint256 levelNow = LibLeakyBucket.levelAt(level, checkpoint, timestamp, leakRate);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelNow, amount));
        this.externalFillAt(level, checkpoint, timestamp, capacity, leakRate, amount);
    }

    /// After any accepted fill the level is still within the capacity, unless
    /// it was already above it before the fill, which only a capacity cut can
    /// produce and which only accepts a zero fill anyway.
    function testLevelNeverEndsAboveCapacity(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        uint256 levelNow = LibLeakyBucket.levelAt(level, checkpoint, timestamp, leakRate);
        amount = bound(amount, 0, LibLeakyBucket.headroomAt(level, checkpoint, timestamp, capacity, leakRate));
        uint256 newLevel = LibLeakyBucket.fillAt(level, checkpoint, timestamp, capacity, leakRate, amount);
        assertLe(newLevel, levelNow > capacity ? levelNow : capacity);
    }

    /// The deliberate other half, pinned so it cannot drift: cumulative
    /// throughput DOES grow past the capacity as time passes, at exactly the
    /// leak rate. Minting a full bucket and then waiting half a drain time
    /// makes half a capacity available again. This is the rate limit working,
    /// not the cap leaking: at no instant did the bucket hold more than
    /// `capacity`, and no single mint was larger than `capacity`.
    function testRefillIsPacedByLeakRateAndCappedAtCapacity() external pure {
        uint256 level = LibLeakyBucket.fillAt(0, 0, 0, CAPACITY, LEAK_RATE, CAPACITY);
        assertEq(level, CAPACITY);
        assertEq(LibLeakyBucket.headroomAt(level, 0, 0, CAPACITY, LEAK_RATE), 0);

        // Half a drain time later, half the capacity has leaked out.
        assertEq(LibLeakyBucket.levelAt(level, 0, DRAIN / 2, LEAK_RATE), CAPACITY / 2);
        assertEq(LibLeakyBucket.headroomAt(level, 0, DRAIN / 2, CAPACITY, LEAK_RATE), CAPACITY / 2);

        // So 1.5 capacities crossed in half a drain time, and the bucket is
        // full again rather than over full.
        uint256 refilled = LibLeakyBucket.fillAt(level, 0, DRAIN / 2, CAPACITY, LEAK_RATE, CAPACITY / 2);
        assertEq(refilled, CAPACITY);
    }

    /// A burst that follows a full drain is capped exactly as the first one
    /// was. Draining restores the ability to burst again, it never enlarges
    /// the burst, and the unit past the cap is still rejected.
    function testASecondBurstAfterAFullDrainIsCappedTheSame() external {
        uint256 level = LibLeakyBucket.fillAt(0, 0, 0, CAPACITY, LEAK_RATE, CAPACITY);
        uint256 refilled = LibLeakyBucket.fillAt(level, 0, DRAIN, CAPACITY, LEAK_RATE, CAPACITY);
        assertEq(refilled, CAPACITY);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, CAPACITY, CAPACITY, 1));
        this.externalFillAt(refilled, DRAIN, DRAIN, CAPACITY, LEAK_RATE, 1);
    }

    /// You cannot leak more than the bucket before a mint. The leak credited is
    /// `min(level, elapsed * leakRate)`: it is bounded by the level, which is
    /// bounded by the capacity, and the level stops at zero rather than going
    /// negative. However long the wait, it cannot manufacture more drain than
    /// there was level to drain.
    function testLeakCreditedNeverExceedsTheBucket(
        uint256 level,
        uint256 checkpoint,
        uint256 capacity,
        uint256 earlier,
        uint256 later,
        uint256 leakRate
    ) external pure {
        level = bound(level, 0, capacity);
        later = bound(later, earlier, type(uint256).max);
        uint256 levelEarlier = LibLeakyBucket.levelAt(level, checkpoint, earlier, leakRate);
        uint256 levelLater = LibLeakyBucket.levelAt(level, checkpoint, later, leakRate);
        // Monotonic in time, so this cannot underflow.
        assertLe(levelEarlier - levelLater, capacity);
    }

    /// Consuming the bucket zeroes it immediately, in the same second, not
    /// after some delay and not partially. Whatever happens afterwards is the
    /// refill, and no length of wait offers the next mint more than one
    /// capacity.
    function testConsumedBucketIsZeroImmediatelyThenRefillsBoundedByCapacity(uint256 elapsed) external pure {
        uint256 level = LibLeakyBucket.fillAt(0, 0, 0, CAPACITY, LEAK_RATE, CAPACITY);

        // Immediately: same timestamp, nothing further fits.
        assertEq(LibLeakyBucket.headroomAt(level, 0, 0, CAPACITY, LEAK_RATE), 0);

        // Afterwards: the refill, bounded by one capacity at every wait.
        assertLe(LibLeakyBucket.headroomAt(level, 0, elapsed, CAPACITY, LEAK_RATE), CAPACITY);
    }
}
