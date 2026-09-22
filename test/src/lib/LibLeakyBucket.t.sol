// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {
    LeakyBucketZeroAmount,
    LibLeakyBucket,
    LeakyBucket,
    LeakyBucketCapacityExceeded,
    LeakyBucketCapacityOverflow,
    LeakyBucketTimestampOverflow
} from "../../../src/lib/LibLeakyBucket.sol";
import {LibLeakyBucketSlow} from "../../lib/LibLeakyBucketSlow.sol";
import {LibCheckpointWord} from "../../lib/LibCheckpointWord.sol";
import {LeakyBucketScratch} from "../../abstract/LeakyBucketScratch.sol";

/// Properties of the bucket itself, stated as invariants over the whole input
/// space rather than as a table of worked examples.
contract LibLeakyBucketTest is Test, LeakyBucketScratch {
    // ---------------------------------------------------------------- //
    //                              The leak                             //
    // ---------------------------------------------------------------- //

    /// Leaking can only ever lower the level, at every input.
    function testLeakNeverRaisesLevel(uint192 level, uint64 checkpoint, uint64 timestamp, uint256 leakRate)
        external
        pure
    {
        assertLe(levelAt(LibCheckpointWord.packed(level, checkpoint), timestamp, leakRate), level);
    }

    /// A zero rate is a bucket that does not drain, forever.
    function testLeakRateZeroNeverLeaks(uint192 level, uint64 checkpoint, uint64 timestamp) external pure {
        assertEq(levelAt(LibCheckpointWord.packed(level, checkpoint), timestamp, 0), level);
    }

    /// No time, no leak.
    function testLeakZeroElapsedNeverLeaks(uint192 level, uint64 checkpoint, uint256 leakRate) external pure {
        assertEq(levelAt(LibCheckpointWord.packed(level, checkpoint), checkpoint, leakRate), level);
    }

    /// Where the product cannot overflow the leak is exactly `elapsed * rate`,
    /// floored at empty.
    function testLeakIsExactWhereItCannotOverflow(uint128 level, uint64 elapsed, uint64 leakRate) external pure {
        uint256 leaked = uint256(elapsed) * uint256(leakRate);
        assertEq(levelAt(LibCheckpointWord.packed(level, 0), elapsed, leakRate), leaked < level ? level - leaked : 0);
    }

    /// An overflowing product is a leak larger than any representable level, so
    /// the bucket reads empty, and empty is the exact answer here rather than a
    /// conservative one.
    function testLeakOverflowingProductEmptiesBucket(uint192 level, uint64 elapsed, uint256 leakRate) external pure {
        elapsed = uint64(bound(elapsed, 1 << 32, type(uint64).max));
        leakRate = bound(leakRate, 1 << 224, type(uint256).max);
        assertEq(levelAt(LibCheckpointWord.packed(level, 0), elapsed, leakRate), 0);
    }

    /// The closed form agrees with draining one second at a time, everywhere
    /// the loop is affordable to run.
    function testLeakAgainstUnitSteps(uint192 level, uint64 elapsed, uint256 leakRate) external pure {
        elapsed = uint64(bound(elapsed, 0, 512));
        leakRate = bound(leakRate, 0, type(uint128).max);
        assertEq(
            levelAt(LibCheckpointWord.packed(level, 0), elapsed, leakRate),
            LibLeakyBucketSlow.leakSlow(level, elapsed, leakRate)
        );
    }

    /// A clock at or behind the checkpoint credits no leak.
    function testBackwardsClockCreditsNoLeak(uint192 level, uint64 checkpoint, uint64 timestamp, uint256 leakRate)
        external
        pure
    {
        timestamp = uint64(bound(timestamp, 0, checkpoint));
        assertEq(levelAt(LibCheckpointWord.packed(level, checkpoint), timestamp, leakRate), level);
    }

    /// Later never reads fuller.
    function testLevelIsMonotonicInTime(
        uint192 level,
        uint64 checkpoint,
        uint64 earlier,
        uint64 later,
        uint256 leakRate
    ) external pure {
        later = uint64(bound(later, earlier, type(uint64).max));
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        assertLe(levelAt(checkpointWord, later, leakRate), levelAt(checkpointWord, earlier, leakRate));
    }

    // ---------------------------------------------------------------- //
    //                        Headroom and filling                       //
    // ---------------------------------------------------------------- //

    /// Headroom is capacity minus the level, floored at zero, so it is never
    /// more than the capacity and never underflows when the level is above it.
    function testHeadroomNeverExceedsCapacity(uint256 checkpoint, uint64 timestamp, uint192 capacity, uint256 leakRate)
        external
        pure
    {
        assertLe(headroomAt(checkpoint, timestamp, capacity, leakRate), capacity);
    }

    /// Whatever `headroomAt` reports is a fill `fill` takes IN FULL, at every
    /// input it will answer at all; a zero headroom is a zero fill, refused.
    function testHeadroomIsAlwaysFillable(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate
    ) external {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 levelNow = levelAt(checkpointWord, timestamp, leakRate);
        uint256 headroom = headroomAt(checkpointWord, timestamp, capacity, leakRate);
        if (headroom == 0) {
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketZeroAmount.selector));
            this.externalFill(checkpointWord, timestamp, capacity, leakRate, 0);
            return;
        }

        uint256 newLevel = LibCheckpointWord.storedLevel(fill(checkpointWord, timestamp, capacity, leakRate, headroom));

        // The fill was taken in full, not silently dropped or clamped.
        assertEq(newLevel, levelNow + headroom);
        // And it lands exactly at the capacity, unless the bucket was already
        // above it, in which case the only headroom on offer was zero.
        assertEq(newLevel, levelNow > capacity ? levelNow : capacity);
    }

    /// The other half: one unit past the reported headroom is always rejected,
    /// with the capacity that was in force, the level at that second and the
    /// amount that did not fit.
    function testFillRejectsOneUnitPastTheHeadroom(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate
    ) external {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 levelNow = levelAt(checkpointWord, timestamp, leakRate);
        uint256 headroom = headroomAt(checkpointWord, timestamp, capacity, leakRate);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelNow, headroom + 1));
        this.externalFill(checkpointWord, timestamp, capacity, leakRate, headroom + 1);
    }

    /// Filling over the headroom reverts with the same error whatever the
    /// overshoot, and nothing is written.
    function testFillRevertsOverHeadroom(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 levelNow = levelAt(checkpointWord, timestamp, leakRate);
        uint256 headroom = headroomAt(checkpointWord, timestamp, capacity, leakRate);
        amount = bound(amount, headroom + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelNow, amount));
        this.externalFill(checkpointWord, timestamp, capacity, leakRate, amount);
    }

    /// A zero fill is refused at every level.
    function testFillRejectsZeroAmount(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate
    ) external {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketZeroAmount.selector));
        this.externalFill(checkpointWord, timestamp, capacity, leakRate, 0);
    }

    /// Lowering capacity under an outstanding level needs no migration and no
    /// fill to take effect.
    function testCapacityLoweredBelowLevelBindsImmediatelyThenDrains() external {
        uint256 leakRate = 1e18;
        uint64 checkpoint = 1000;
        uint256 checkpointWord = LibCheckpointWord.packed(100e18, checkpoint);

        // Capacity cut to a quarter of what is already outstanding.
        uint256 capacity = 25e18;

        assertEq(headroomAt(checkpointWord, checkpoint, capacity, leakRate), 0);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, 100e18, 1));
        this.externalFill(checkpointWord, checkpoint, capacity, leakRate, 1);

        // Still bound most of the way down.
        assertEq(headroomAt(checkpointWord, checkpoint + 74, capacity, leakRate), 0);

        // 75 seconds at 1e18/s leaks 75e18, reaching the new capacity exactly.
        assertEq(levelAt(checkpointWord, checkpoint + 75, leakRate), 25e18);
        assertEq(headroomAt(checkpointWord, checkpoint + 75, capacity, leakRate), 0);

        // And from there it behaves as an ordinary bucket at the new capacity.
        assertEq(headroomAt(checkpointWord, checkpoint + 85, capacity, leakRate), 10e18);
        assertEq(LibCheckpointWord.storedLevel(fill(checkpointWord, checkpoint + 85, capacity, leakRate, 10e18)), 25e18);
    }

    /// The security property on a worked policy: every burst is capped at the
    /// capacity, including the ones that come after a full drain.
    function testEachRepeatBurstIsCappedAtCapacity() external {
        uint256 capacity = 3600e18;
        // One unit per second, so a full bucket drains in exactly an hour.
        uint256 leakRate = 1e18;
        uint64 t0 = 1_700_000_000;

        // Burst the whole capacity at once out of an empty bucket.
        uint256 filled = fill(LibCheckpointWord.packed(0, t0), t0, capacity, leakRate, capacity);
        assertEq(LibCheckpointWord.storedLevel(filled), capacity);

        // Immediately after, nothing more fits.
        assertEq(headroomAt(filled, t0, capacity, leakRate), 0);

        // The drain time for a full bucket, and the first moment it is empty.
        // Bounded by the fuzz bounds above, which keep the quotient far inside
        // 64 bits, so this narrowing cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 drain = uint64(capacity / leakRate);
        assertEq(levelAt(filled, t0 + drain, leakRate), capacity % leakRate);

        // A second burst lands, so `2 * capacity` crossed in one drain window.
        uint256 refilled = fill(filled, t0 + drain + 1, capacity, leakRate, capacity);
        assertEq(LibCheckpointWord.storedLevel(refilled), capacity);

        // And no third burst: the bound is `capacity + elapsed * leakRate`.
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, capacity, 1));
        this.externalFill(refilled, t0 + drain + 1, capacity, leakRate, 1);
    }

    // ---------------------------------------------------------------- //
    //                        The word that is stored                    //
    // ---------------------------------------------------------------- //

    /// The property the packing exists for: a successful fill writes a word
    /// that carries the new level *and* a timestamp that level actually belongs
    /// to.
    function testFillCarriesTheTimestampWithTheLevel(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 headroom = headroomAt(checkpointWord, timestamp, capacity, leakRate);
        vm.assume(headroom > 0);
        amount = bound(amount, 1, headroom);

        uint256 result = fill(checkpointWord, timestamp, capacity, leakRate, amount);
        uint256 newLevel = LibCheckpointWord.storedLevel(result);
        uint256 newTimestamp = LibCheckpointWord.storedTimestamp(result);

        assertGe(newTimestamp, checkpoint);
        assertGe(newTimestamp, timestamp);
        assertLe(newTimestamp, timestamp > checkpoint ? timestamp : checkpoint);

        assertEq(newLevel, levelAt(checkpointWord, newTimestamp, leakRate) + amount);
    }

    /// `fill` returns the new checkpoint and touches nothing it was handed.
    function testFillMutatesNothingItIsHanded(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 headroom = headroomAt(checkpointWord, timestamp, capacity, leakRate);
        vm.assume(headroom > 0);
        amount = bound(amount, 1, headroom);

        LeakyBucket memory handed = bucket(checkpointWord, capacity, leakRate);
        LibLeakyBucket.fill(handed, timestamp, amount);

        assertEq(handed.checkpoint, checkpointWord);
        assertEq(handed.capacity, capacity);
        assertEq(handed.leakRate, leakRate);
    }

    /// The layout is the level in the high bits and the timestamp in the low
    /// ones, stated as values rather than left to the library.
    function testLayoutIsLevelHighTimestampLow() external pure {
        assertEq(LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX, type(uint192).max);
        assertEq(LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX, type(uint256).max >> LibCheckpointWord.TIMESTAMP_BITS);

        // One unit in the level field is one unit above the timestamp field,
        // and one second is the lowest bit of the word. A zero rate keeps the
        // leak out of it, so what comes back is the packing and nothing else.
        assertEq(fill(0, 0, type(uint192).max, 0, 1), uint256(1) << LibCheckpointWord.TIMESTAMP_BITS);
        assertEq(fill(0, 1, type(uint192).max, 0, 1), (uint256(1) << LibCheckpointWord.TIMESTAMP_BITS) | 1);

        // And the two fields tile the word exactly: no gap, no overlap. The
        // widest level at the last recordable second is every bit set.
        assertEq(fill(0, type(uint64).max, type(uint192).max, 0, type(uint192).max), type(uint256).max);
    }

    /// A zero word is an empty bucket checkpointed at the epoch, so an
    /// untouched slot needs no initializer.
    function testZeroWordIsEmptyAtEpoch() external pure {
        assertEq(LibCheckpointWord.storedLevel(0), 0);
        assertEq(LibCheckpointWord.storedTimestamp(0), 0);
        assertEq(levelAt(0, 0, 1e18), 0);
        assertEq(headroomAt(0, 0, 3600e18, 1e18), 3600e18);
    }

    /// Reading a checkpoint is total: every word in the space is some valid
    /// bucket, so a slot holding arbitrary bits reads as one rather than
    /// reverting.
    function testEveryWordReadsAsABucket(uint256 checkpoint, uint64 timestamp, uint192 capacity, uint256 leakRate)
        external
        pure
    {
        headroomAt(checkpoint, timestamp, capacity, leakRate);
    }

    /// The fields do not bleed into each other.
    function testFieldsDoNotAlias(uint192 level, uint64 timestamp, uint192 otherLevel, uint64 otherTimestamp)
        external
        pure
    {
        // Moving the level across its whole range never moves the timestamp.
        // A fill of one unit rewrites the word, so the timestamp that comes
        // back is the one that went in whatever the level beside it was.
        level = uint192(bound(level, 0, type(uint192).max - 1));
        otherLevel = uint192(bound(otherLevel, 0, type(uint192).max - 1));
        assertEq(
            LibCheckpointWord.storedTimestamp(
                fill(LibCheckpointWord.packed(level, timestamp), timestamp, type(uint192).max, 0, 1)
            ),
            timestamp
        );
        assertEq(
            LibCheckpointWord.storedTimestamp(
                fill(LibCheckpointWord.packed(otherLevel, timestamp), timestamp, type(uint192).max, 0, 1)
            ),
            timestamp
        );

        // And moving the timestamp across its whole range never moves the
        // level.
        assertEq(levelAt(LibCheckpointWord.packed(level, timestamp), timestamp, 0), level);
        assertEq(levelAt(LibCheckpointWord.packed(level, otherTimestamp), otherTimestamp, 0), level);
    }

    /// A fill at a timestamp *behind* the stored checkpoint must not move the
    /// checkpoint back to it.
    function testFillBehindTheCheckpointGrantsNoHeadroom() external pure {
        uint256 capacity = 3600e18;
        uint256 leakRate = 1e18;

        uint256 nearlyFull = fill(0, 1000, capacity, leakRate, capacity - 1e18);
        assertEq(LibCheckpointWord.storedLevel(nearlyFull), 3599e18);
        assertEq(LibCheckpointWord.storedTimestamp(nearlyFull), 1000);

        // The last unit goes in at a clock behind the checkpoint: the level
        // moves, the checkpoint stays at 1000.
        uint256 backwards = fill(nearlyFull, 500, capacity, leakRate, 1e18);
        assertEq(LibCheckpointWord.storedLevel(backwards), 3600e18);
        assertEq(LibCheckpointWord.storedTimestamp(backwards), 1000);

        uint256 full = fill(0, 1000, capacity, leakRate, capacity);
        assertEq(headroomAt(backwards, 1001, capacity, leakRate), 1e18);
        assertEq(headroomAt(backwards, 1001, capacity, leakRate), headroomAt(full, 1001, capacity, leakRate));
    }

    /// The general form of the case above.
    function testFillBehindTheCheckpointIsNotObservable(
        uint192 level,
        uint64 checkpoint,
        uint64 behind,
        uint192 capacity,
        uint256 leakRate,
        uint64 later
    ) external pure {
        behind = uint64(bound(behind, 0, checkpoint));
        later = uint64(bound(later, checkpoint, type(uint64).max));

        vm.assume(capacity > level);
        uint256 filled = fill(LibCheckpointWord.packed(level, checkpoint), behind, capacity, leakRate, 1);
        // One unit filled at `behind` is one unit on the level at `checkpoint`.
        uint256 expected = LibCheckpointWord.packed(level + 1, checkpoint);

        assertEq(levelAt(filled, later, leakRate), levelAt(expected, later, leakRate));
        assertEq(headroomAt(filled, later, capacity, leakRate), headroomAt(expected, later, capacity, leakRate));
    }

    /// The headline property of the leak, through the write path, which is the
    /// only path there is.
    function testFillThroughACheckpointHasNoDrift(
        uint192 capacity,
        uint256 leakRate,
        uint64 t0,
        uint64 gapA,
        uint64 gapB
    ) external pure {
        leakRate = bound(leakRate, 0, type(uint128).max);
        uint64 t1 = uint64(bound(gapA, 0, type(uint64).max - t0)) + t0;
        uint64 t2 = uint64(bound(gapB, 0, type(uint64).max - t1)) + t1;

        capacity = uint192(bound(capacity, 1, type(uint192).max));
        uint256 start = LibCheckpointWord.packed(capacity - 1, t0);

        // A hand-built checkpoint of the level at t1 plus one unit.
        uint256 direct = levelAt(LibCheckpointWord.packed(uint192(levelAt(start, t1, leakRate) + 1), t1), t2, leakRate);

        // The same through a fill of one unit at t1.
        uint256 viaFill = levelAt(fill(start, t1, capacity, leakRate, 1), t2, leakRate);

        assertEq(direct, viaFill);
    }

    /// The other half of "a zero word is a valid initial state", asserted
    /// rather than described because the library warns about it: it cannot tell
    /// a *cleared* slot from an untouched one, so `delete` on a bucket is a
    /// full refund of whatever was outstanding rather than cleanup.
    function testAClearedSlotIsAFullRefundAtTheSameSecond() external pure {
        uint256 capacity = 3600e18;
        uint256 leakRate = 1e18;

        uint256 full = fill(0, 1000, capacity, leakRate, capacity);
        assertEq(headroomAt(full, 1000, capacity, leakRate), 0);

        // `delete sBuckets[minter]` is exactly this: the word becomes zero.
        uint256 cleared = 0;
        assertEq(headroomAt(cleared, 1000, capacity, leakRate), capacity);

        // And it is the same word an untouched slot holds, so no read here can
        // distinguish the two. The warning is a warning because the library
        // cannot enforce it.
        assertEq(cleared, LibCheckpointWord.packed(0, 0));
    }

    // ---------------------------------------------------------------- //
    //                          The fillable domain                      //
    // ---------------------------------------------------------------- //

    /// The rule both entry points obey, stated once and fuzzed over the
    /// UNBOUNDED input space rather than over `uint64`/`uint192` parameters
    /// that assume the bounds instead of checking them: **a read answers
    /// exactly where `fill` acts**, and refuses exactly what `fill` refuses,
    /// with the same error carrying the same argument.
    function testEntryPointsAnswerOnExactlyTheFillableDomain(
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate
    ) external {
        if (capacity > LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX) {
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityOverflow.selector, capacity));
            this.externalHeadroomAt(checkpoint, timestamp, capacity, leakRate);
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityOverflow.selector, capacity));
            this.externalFill(checkpoint, timestamp, capacity, leakRate, 0);
            return;
        }

        if (timestamp > type(uint64).max) {
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketTimestampOverflow.selector, timestamp));
            this.externalHeadroomAt(checkpoint, timestamp, capacity, leakRate);
            // The domain is checked before the amount, so a zero amount still
            // reports the second.
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketTimestampOverflow.selector, timestamp));
            this.externalFill(checkpoint, timestamp, capacity, leakRate, 0);
            return;
        }

        // Inside the domain both of them answer, and what `headroomAt` names is
        // what `fill` takes.
        uint256 headroom = headroomAt(checkpoint, timestamp, capacity, leakRate);
        if (headroom == 0) {
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketZeroAmount.selector));
            this.externalFill(checkpoint, timestamp, capacity, leakRate, 0);
        } else {
            fill(checkpoint, timestamp, capacity, leakRate, headroom);
        }
    }

    /// The library cannot enforce a capacity it cannot store, so it refuses one
    /// rather than answering questions about it.
    function testEntryPointsRejectAnUnenforceableCapacity(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        capacity = bound(capacity, LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX + 1, type(uint256).max);
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityOverflow.selector, capacity));
        this.externalHeadroomAt(checkpointWord, timestamp, capacity, leakRate);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityOverflow.selector, capacity));
        this.externalFill(checkpointWord, timestamp, capacity, leakRate, amount);
    }

    /// The other side of that guard, and the bound `LEAKY_BUCKET_LEVEL_MAX` is
    /// exported for: everything up to and including the level width is
    /// accepted, so the check is a bound on what can be stored and not a
    /// narrowing of the policy space.
    function testEveryStorableCapacityIsAccepted(uint256 checkpoint, uint64 timestamp, uint256 capacity) external pure {
        capacity = bound(capacity, 0, LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX);
        headroomAt(checkpoint, timestamp, capacity, 0);
    }

    /// At the widest capacity the library can store, the documented agreement
    /// holds exactly: `headroomAt` names the largest amount `fill` accepts,
    /// `fill` accepts it and stores it without truncating, and one unit more is
    /// rejected with the capacity error rather than with an arithmetic failure.
    function testTheWidestStorableCapacityIsExactlyFillableAndNotTruncated() external {
        uint256 capacity = LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX;

        uint256 headroom = headroomAt(0, 0, capacity, 0);
        assertEq(headroom, LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX);

        uint256 result = fill(0, 0, capacity, 0, headroom);
        assertEq(LibCheckpointWord.storedLevel(result), LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX);
        assertEq(LibCheckpointWord.storedTimestamp(result), 0);
        // Not truncated: the level that went in is the level that reads back,
        // and it offers nothing further at that same second.
        assertEq(headroomAt(result, 0, capacity, 0), 0);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, 0, headroom + 1));
        this.externalFill(0, 0, capacity, 0, headroom + 1);
    }

    /// A `timestamp` the packed field cannot hold is refused BY NAME, and
    /// nothing is stored.
    function testFillRevertsOnATimestampItCannotStore(
        uint192 level,
        uint64 checkpoint,
        uint256 timestamp,
        uint192 capacity,
        uint256 leakRate
    ) external {
        timestamp = bound(timestamp, uint256(type(uint64).max) + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketTimestampOverflow.selector, timestamp));
        this.externalFill(LibCheckpointWord.packed(level, checkpoint), timestamp, capacity, leakRate, 0);
    }

    /// The error identities are a published surface: a consumer that catches a
    /// rejection, an indexer, or a frontend decoding a failed simulation all
    /// match on the four byte selector, which is the hash of the signature.
    function testErrorSelectorsArePinnedToTheirSignatures() external pure {
        assertEq(
            bytes32(LeakyBucketCapacityExceeded.selector),
            bytes32(bytes4(keccak256("LeakyBucketCapacityExceeded(uint256,uint256,uint256)")))
        );
        assertEq(
            bytes32(LeakyBucketCapacityOverflow.selector),
            bytes32(bytes4(keccak256("LeakyBucketCapacityOverflow(uint256)")))
        );
        assertEq(
            bytes32(LeakyBucketTimestampOverflow.selector),
            bytes32(bytes4(keccak256("LeakyBucketTimestampOverflow(uint256)")))
        );
    }
}
