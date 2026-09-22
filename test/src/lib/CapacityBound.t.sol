// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {LibLeakyBucket, LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {LibSaturatingMath} from "rain-math-saturating-0.1.10/src/lib/LibSaturatingMath.sol";
import {WORKED_CAPACITY, WORKED_LEAK_RATE, WORKED_DRAIN} from "../../lib/WorkedPolicy.sol";
import {LibCheckpointWord} from "../../lib/LibCheckpointWord.sol";
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
///
/// Every assertion goes through `fill` and `headroomAt`, which are the whole of
/// the library's surface. The level a bucket is carrying is read with
/// `LibCheckpointWord.levelAt`, which derives it from `headroomAt` against the
/// widest enforceable capacity rather than from a library function of its own —
/// see that library for why the derivation is exact.
///
/// The fuzzed parameters are typed to the packed fields: a `capacity` wider
/// than the level field and a `timestamp` wider than the timestamp field are
/// refused outright by both entry points, and that refusal is a separate claim
/// pinned in `LibLeakyBucket.t.sol`. Everything here is about what the cap does
/// on the domain where it answers at all.
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
    /// `testHeadroomNeverExceedsCapacity` in `LibLeakyBucket.t.sol`.
    function testIdleForAThousandDrainTimesStillOffersOneCapacity() external pure {
        assertEq(LibLeakyBucket.headroomAt(0, DRAIN * 1000, CAPACITY, LEAK_RATE), CAPACITY);
    }

    /// Filling an empty bucket to the top leaves nothing further to mint, at
    /// that instant. "Zero to full" is "zero headroom".
    function testFillingToCapacityLeavesZeroHeadroom(uint192 capacity, uint256 leakRate, uint64 timestamp)
        external
        pure
    {
        uint256 filled =
            LibLeakyBucket.fill(LibCheckpointWord.packed(0, timestamp), timestamp, capacity, leakRate, capacity);
        assertEq(LibCheckpointWord.storedLevel(filled), capacity);
        assertEq(LibLeakyBucket.headroomAt(filled, timestamp, capacity, leakRate), 0);
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
        uint256 levelNow = LibCheckpointWord.levelAt(checkpointWord, timestamp, leakRate);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelNow, amount));
        this.externalFill(checkpointWord, timestamp, capacity, leakRate, amount);
    }

    /// After any accepted fill the level is still within the capacity, unless
    /// it was already above it before the fill, which only a capacity cut can
    /// produce and which only accepts a zero fill anyway.
    function testLevelNeverEndsAboveCapacity(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 levelNow = LibCheckpointWord.levelAt(checkpointWord, timestamp, leakRate);
        amount = bound(amount, 0, LibLeakyBucket.headroomAt(checkpointWord, timestamp, capacity, leakRate));
        uint256 newLevel =
            LibCheckpointWord.storedLevel(LibLeakyBucket.fill(checkpointWord, timestamp, capacity, leakRate, amount));
        assertLe(newLevel, levelNow > capacity ? levelNow : capacity);
    }

    /// The deliberate other half, pinned so it cannot drift: cumulative
    /// throughput DOES grow past the capacity as time passes, at exactly the
    /// leak rate. Minting a full bucket and then waiting half a drain time
    /// makes half a capacity available again. This is the rate limit working,
    /// not the cap leaking: at no instant did the bucket hold more than
    /// `capacity`, and no single mint was larger than `capacity`.
    function testRefillIsPacedByLeakRateAndCappedAtCapacity() external pure {
        uint256 filled = LibLeakyBucket.fill(0, 0, CAPACITY, LEAK_RATE, CAPACITY);
        assertEq(LibCheckpointWord.storedLevel(filled), CAPACITY);
        assertEq(LibLeakyBucket.headroomAt(filled, 0, CAPACITY, LEAK_RATE), 0);

        // Half a drain time later, half the capacity has leaked out.
        assertEq(LibCheckpointWord.levelAt(filled, DRAIN / 2, LEAK_RATE), CAPACITY / 2);
        assertEq(LibLeakyBucket.headroomAt(filled, DRAIN / 2, CAPACITY, LEAK_RATE), CAPACITY / 2);

        // So 1.5 capacities crossed in half a drain time, and the bucket is
        // full again rather than over full.
        uint256 refilled = LibLeakyBucket.fill(filled, DRAIN / 2, CAPACITY, LEAK_RATE, CAPACITY / 2);
        assertEq(LibCheckpointWord.storedLevel(refilled), CAPACITY);
    }

    /// A burst that follows a full drain is capped exactly as the first one
    /// was. Draining restores the ability to burst again, it never enlarges
    /// the burst, and the unit past the cap is still rejected.
    function testASecondBurstAfterAFullDrainIsCappedTheSame() external {
        uint256 filled = LibLeakyBucket.fill(0, 0, CAPACITY, LEAK_RATE, CAPACITY);
        uint256 refilled = LibLeakyBucket.fill(filled, DRAIN, CAPACITY, LEAK_RATE, CAPACITY);
        assertEq(LibCheckpointWord.storedLevel(refilled), CAPACITY);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, CAPACITY, CAPACITY, 1));
        this.externalFill(refilled, DRAIN, CAPACITY, LEAK_RATE, 1);
    }

    /// You cannot leak more than the bucket before a mint. The leak credited is
    /// `min(level, elapsed * leakRate)`: it is bounded by the level, which is
    /// bounded by the capacity, and the level stops at zero rather than going
    /// negative. However long the wait, it cannot manufacture more drain than
    /// there was level to drain.
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
        uint256 levelEarlier = LibCheckpointWord.levelAt(checkpointWord, earlier, leakRate);
        uint256 levelLater = LibCheckpointWord.levelAt(checkpointWord, later, leakRate);
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
    /// after some delay and not partially. Whatever happens afterwards is the
    /// refill, and no length of wait offers the next mint more than one
    /// capacity.
    function testConsumedBucketIsZeroImmediatelyThenRefillsBoundedByCapacity(uint64 elapsed) external pure {
        uint256 filled = LibLeakyBucket.fill(0, 0, CAPACITY, LEAK_RATE, CAPACITY);

        // Immediately: same timestamp, nothing further fits.
        assertEq(LibLeakyBucket.headroomAt(filled, 0, CAPACITY, LEAK_RATE), 0);

        // Afterwards: the refill, bounded by one capacity at every wait.
        assertLe(LibLeakyBucket.headroomAt(filled, elapsed, CAPACITY, LEAK_RATE), CAPACITY);
    }
}
