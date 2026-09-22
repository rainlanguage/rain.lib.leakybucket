// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {
    LibLeakyBucket,
    LeakyBucketCapacityExceeded,
    LeakyBucketCapacityOverflow,
    LeakyBucketTimestampOverflow
} from "../../../src/lib/LibLeakyBucket.sol";
import {LibLeakyBucketSlow} from "../../lib/LibLeakyBucketSlow.sol";
import {LibCheckpointWord} from "../../lib/LibCheckpointWord.sol";
import {LeakyBucketExternal} from "../../abstract/LeakyBucketExternal.sol";

/// Properties of the bucket itself, stated as invariants over the whole input
/// space rather than as a table of worked examples. The cap is only as good as
/// the arithmetic under it, so the bounds that make it a cap at all — that the
/// level never rises on its own, never underflows, and never grants headroom
/// that time did not earn — are asserted directly.
///
/// The library exports two functions and one constant. Everything else it does
/// is a private step of `fill`, so everything below is observed through those
/// two functions, which is also the only way a consumer can observe it. Where
/// a property is about a step rather than an entry point — the leak, the
/// packing — the step is restated independently in `test/lib/` — the loop in
/// `LibLeakyBucketSlow`, the word layout in `LibCheckpointWord` — and the two
/// are compared, rather than the library being asked to confirm itself.
contract LibLeakyBucketTest is Test, LeakyBucketExternal {
    // ---------------------------------------------------------------- //
    //                              The leak                             //
    // ---------------------------------------------------------------- //

    /// Leaking can only ever lower the level, at every input. This is the
    /// underflow guard stated as a property: there is no input where the
    /// subtraction wraps and reports a level above where it started.
    function testLeakNeverRaisesLevel(uint192 level, uint64 checkpoint, uint64 timestamp, uint256 leakRate)
        external
        pure
    {
        assertLe(LibCheckpointWord.levelAt(LibCheckpointWord.packed(level, checkpoint), timestamp, leakRate), level);
    }

    /// A zero rate is a bucket that does not drain, forever.
    function testLeakRateZeroNeverLeaks(uint192 level, uint64 checkpoint, uint64 timestamp) external pure {
        assertEq(LibCheckpointWord.levelAt(LibCheckpointWord.packed(level, checkpoint), timestamp, 0), level);
    }

    /// No time, no leak.
    function testLeakZeroElapsedNeverLeaks(uint192 level, uint64 checkpoint, uint256 leakRate) external pure {
        assertEq(LibCheckpointWord.levelAt(LibCheckpointWord.packed(level, checkpoint), checkpoint, leakRate), level);
    }

    /// Where the product cannot overflow the leak is exactly `elapsed * rate`,
    /// floored at empty. No rounding, no slack.
    function testLeakIsExactWhereItCannotOverflow(uint128 level, uint64 elapsed, uint64 leakRate) external pure {
        uint256 leaked = uint256(elapsed) * uint256(leakRate);
        assertEq(
            LibCheckpointWord.levelAt(LibCheckpointWord.packed(level, 0), elapsed, leakRate),
            leaked < level ? level - leaked : 0
        );
    }

    /// An overflowing product is a leak larger than any representable level, so
    /// the bucket reads empty, and empty is the exact answer here rather than a
    /// conservative one. The bug this pins is a wrapped product: reducing the
    /// product modulo the word is a SMALLER leak than the truth, which leaves a
    /// level above the true level and so a cap tighter than the policy. A wrap
    /// is a bucket that stops draining, not one that hands out free headroom.
    ///
    /// The elapsed time is bounded by the timestamp field rather than by the
    /// word, so the product is pushed over the top of the word from the rate
    /// side. That is the only side a caller controls freely: `leakRate` takes
    /// no part in the packing and is unbounded.
    function testLeakOverflowingProductEmptiesBucket(uint192 level, uint64 elapsed, uint256 leakRate) external pure {
        elapsed = uint64(bound(elapsed, 1 << 32, type(uint64).max));
        leakRate = bound(leakRate, 1 << 224, type(uint256).max);
        assertEq(LibCheckpointWord.levelAt(LibCheckpointWord.packed(level, 0), elapsed, leakRate), 0);
    }

    /// The closed form agrees with draining one second at a time, everywhere
    /// the loop is affordable to run.
    function testLeakAgainstUnitSteps(uint192 level, uint64 elapsed, uint256 leakRate) external pure {
        elapsed = uint64(bound(elapsed, 0, 512));
        leakRate = bound(leakRate, 0, type(uint128).max);
        assertEq(
            LibCheckpointWord.levelAt(LibCheckpointWord.packed(level, 0), elapsed, leakRate),
            LibLeakyBucketSlow.leakSlow(level, elapsed, leakRate)
        );
    }

    /// A clock at or behind the checkpoint credits no leak. Not a revert, which
    /// would brick minting until the clock caught up, and not an unsigned wrap,
    /// which would read as billions of years of leak and empty the bucket.
    function testBackwardsClockCreditsNoLeak(uint192 level, uint64 checkpoint, uint64 timestamp, uint256 leakRate)
        external
        pure
    {
        timestamp = uint64(bound(timestamp, 0, checkpoint));
        assertEq(LibCheckpointWord.levelAt(LibCheckpointWord.packed(level, checkpoint), timestamp, leakRate), level);
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
        assertLe(
            LibCheckpointWord.levelAt(checkpointWord, later, leakRate),
            LibCheckpointWord.levelAt(checkpointWord, earlier, leakRate)
        );
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
        assertLe(LibLeakyBucket.headroomAt(checkpoint, timestamp, capacity, leakRate), capacity);
    }

    /// Whatever `headroomAt` reports is a fill `fill` takes IN FULL, at every
    /// input it will answer at all. The claim is the NatSpec's own words — "the
    /// largest amount `fill` would accept" — and the half that has failed
    /// before was acceptance, not rejection, so acceptance is what is fuzzed.
    ///
    /// Acceptance means the level moved by exactly the amount reported. Only
    /// checking that `fill` did not revert leaves a `fill` that took the amount
    /// and then stored the old level passing unchanged: the level field of a
    /// word is bounded by `LEAKY_BUCKET_LEVEL_MAX` for every word in existence,
    /// so bounding it asserts nothing about what the library did.
    function testHeadroomIsAlwaysFillable(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate
    ) external pure {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 levelNow = LibCheckpointWord.levelAt(checkpointWord, timestamp, leakRate);
        uint256 headroom = LibLeakyBucket.headroomAt(checkpointWord, timestamp, capacity, leakRate);

        uint256 newLevel =
            LibCheckpointWord.storedLevel(LibLeakyBucket.fill(checkpointWord, timestamp, capacity, leakRate, headroom));

        // The fill was taken in full, not silently dropped or clamped.
        assertEq(newLevel, levelNow + headroom);
        // And it lands exactly at the capacity, unless the bucket was already
        // above it, in which case the only headroom on offer was zero.
        assertEq(newLevel, levelNow > capacity ? levelNow : capacity);
    }

    /// The other half: one unit past the reported headroom is always rejected,
    /// with the capacity that was in force, the level at that second and the
    /// amount that did not fit. The first half is the cap not being stricter
    /// than it claims, this one is the cap actually binding.
    function testFillRejectsOneUnitPastTheHeadroom(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate
    ) external {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 levelNow = LibCheckpointWord.levelAt(checkpointWord, timestamp, leakRate);
        uint256 headroom = LibLeakyBucket.headroomAt(checkpointWord, timestamp, capacity, leakRate);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelNow, headroom + 1));
        this.externalFill(checkpointWord, timestamp, capacity, leakRate, headroom + 1);
    }

    /// Filling over the headroom reverts with the same error whatever the
    /// overshoot, and the caller stores nothing.
    function testFillRevertsOverHeadroom(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 levelNow = LibCheckpointWord.levelAt(checkpointWord, timestamp, leakRate);
        uint256 headroom = LibLeakyBucket.headroomAt(checkpointWord, timestamp, capacity, leakRate);
        amount = bound(amount, headroom + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelNow, amount));
        this.externalFill(checkpointWord, timestamp, capacity, leakRate, amount);
    }

    /// A zero fill is accepted at any level, including above capacity, and
    /// moves nothing. It is a checkpoint and nothing else.
    function testFillZeroAmountIsCheckpointOnly(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate
    ) external pure {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        assertEq(
            LibCheckpointWord.storedLevel(LibLeakyBucket.fill(checkpointWord, timestamp, capacity, leakRate, 0)),
            LibCheckpointWord.levelAt(checkpointWord, timestamp, leakRate)
        );
    }

    /// Lowering capacity under an outstanding level needs no migration and no
    /// fill to take effect. Headroom reads zero immediately, every non zero
    /// fill is rejected, and the bucket leaks down under the new policy until
    /// it fits again. This is what makes a timelocked capacity change safe to
    /// land at an arbitrary moment.
    function testCapacityLoweredBelowLevelBindsImmediatelyThenDrains() external {
        uint256 leakRate = 1e18;
        uint64 checkpoint = 1000;
        uint256 checkpointWord = LibCheckpointWord.packed(100e18, checkpoint);

        // Capacity cut to a quarter of what is already outstanding.
        uint256 capacity = 25e18;

        assertEq(LibLeakyBucket.headroomAt(checkpointWord, checkpoint, capacity, leakRate), 0);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, 100e18, 1));
        this.externalFill(checkpointWord, checkpoint, capacity, leakRate, 1);

        // Still bound most of the way down.
        assertEq(LibLeakyBucket.headroomAt(checkpointWord, checkpoint + 74, capacity, leakRate), 0);

        // 75 seconds at 1e18/s leaks 75e18, reaching the new capacity exactly.
        assertEq(LibCheckpointWord.levelAt(checkpointWord, checkpoint + 75, leakRate), 25e18);
        assertEq(LibLeakyBucket.headroomAt(checkpointWord, checkpoint + 75, capacity, leakRate), 0);

        // And from there it behaves as an ordinary bucket at the new capacity.
        assertEq(LibLeakyBucket.headroomAt(checkpointWord, checkpoint + 85, capacity, leakRate), 10e18);
        assertEq(
            LibCheckpointWord.storedLevel(
                LibLeakyBucket.fill(checkpointWord, checkpoint + 85, capacity, leakRate, 10e18)
            ),
            25e18
        );
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
        uint64 t0 = 1_700_000_000;

        // Burst the whole capacity at once out of an empty bucket.
        uint256 filled = LibLeakyBucket.fill(LibCheckpointWord.packed(0, t0), t0, capacity, leakRate, capacity);
        assertEq(LibCheckpointWord.storedLevel(filled), capacity);

        // Immediately after, nothing more fits.
        assertEq(LibLeakyBucket.headroomAt(filled, t0, capacity, leakRate), 0);

        // The drain time for a full bucket, and the first moment it is empty.
        // Bounded by the fuzz bounds above, which keep the quotient far inside
        // 64 bits, so this narrowing cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 drain = uint64(capacity / leakRate);
        assertEq(LibCheckpointWord.levelAt(filled, t0 + drain, leakRate), capacity % leakRate);

        // A second burst lands, so `2 * capacity` crossed in one drain window.
        uint256 refilled = LibLeakyBucket.fill(filled, t0 + drain + 1, capacity, leakRate, capacity);
        assertEq(LibCheckpointWord.storedLevel(refilled), capacity);

        // And no third burst: the bound is `capacity + elapsed * leakRate`.
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, capacity, 1));
        this.externalFill(refilled, t0 + drain + 1, capacity, leakRate, 1);
    }

    // ---------------------------------------------------------------- //
    //                        The word that is stored                    //
    // ---------------------------------------------------------------- //

    /// The property the packing exists for: a successful fill returns a word
    /// that carries the new level *and* a timestamp that level actually belongs
    /// to. A caller cannot store one without the other, so the double credit
    /// bug that a two value API invites is not reachable at all.
    ///
    /// Three directional bounds pin the stored timestamp without restating the
    /// expression that produces it:
    ///
    /// - It is never behind the checkpoint it replaces. A regressed checkpoint
    ///   is measured from again on the next read, so it pays out leak for time
    ///   that had already elapsed before this fill — headroom nobody waited
    ///   for, which is the failure direction every saturation here avoids.
    /// - It is never behind the clock the fill was made at, so the fill is
    ///   recorded no earlier than it happened.
    /// - It is never ahead of both, so the library is not silently freezing the
    ///   bucket forward into time that has not passed.
    ///
    /// And the level is checked against the stored timestamp rather than
    /// against the supplied one: whatever second the word claims, the level in
    /// it is the level the bucket truly has at that second, plus the fill.
    function testFillCarriesTheTimestampWithTheLevel(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        amount = bound(amount, 0, LibLeakyBucket.headroomAt(checkpointWord, timestamp, capacity, leakRate));

        uint256 result = LibLeakyBucket.fill(checkpointWord, timestamp, capacity, leakRate, amount);
        uint256 newLevel = LibCheckpointWord.storedLevel(result);
        uint256 newTimestamp = LibCheckpointWord.storedTimestamp(result);

        assertGe(newTimestamp, checkpoint);
        assertGe(newTimestamp, timestamp);
        assertLe(newTimestamp, timestamp > checkpoint ? timestamp : checkpoint);

        assertEq(newLevel, LibCheckpointWord.levelAt(checkpointWord, newTimestamp, leakRate) + amount);
    }

    /// The layout is the level in the high bits and the timestamp in the low
    /// ones, stated as values rather than left to the library.
    ///
    /// The widths are what this version ships: change one and this fails, by
    /// design, so the change is deliberate rather than incidental. A consumer
    /// keeps the word in a slot and reads nothing out of it, but the width is
    /// still published surface — it is what bounds the capacity that can be
    /// enforced and the second that can be recorded, and both of those are
    /// governance-visible.
    function testLayoutIsLevelHighTimestampLow() external pure {
        assertEq(LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX, type(uint192).max);
        assertEq(LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX, type(uint256).max >> LibCheckpointWord.TIMESTAMP_BITS);

        // One unit in the level field is one unit above the timestamp field,
        // and one second is the lowest bit of the word. A zero rate keeps the
        // leak out of it, so what comes back is the packing and nothing else.
        assertEq(LibLeakyBucket.fill(0, 0, type(uint192).max, 0, 1), uint256(1) << LibCheckpointWord.TIMESTAMP_BITS);
        assertEq(LibLeakyBucket.fill(0, 1, type(uint192).max, 0, 0), 1);

        // And the two fields tile the word exactly: no gap, no overlap. The
        // widest level at the last recordable second is every bit set.
        assertEq(LibLeakyBucket.fill(0, type(uint64).max, type(uint192).max, 0, type(uint192).max), type(uint256).max);
    }

    /// A zero word is an empty bucket checkpointed at the epoch, so an
    /// untouched slot needs no initializer.
    function testZeroWordIsEmptyAtEpoch() external pure {
        assertEq(LibCheckpointWord.storedLevel(0), 0);
        assertEq(LibCheckpointWord.storedTimestamp(0), 0);
        assertEq(LibCheckpointWord.levelAt(0, 0, 1e18), 0);
        assertEq(LibLeakyBucket.headroomAt(0, 0, 3600e18, 1e18), 3600e18);
    }

    /// Reading a checkpoint is total: every word in the space is some valid
    /// bucket, so a slot holding arbitrary bits reads as one rather than
    /// reverting. A concrete that re-keys its storage, or a proxy whose layout
    /// shifted under it, gets a bucket rather than a brick.
    function testEveryWordReadsAsABucket(uint256 checkpoint, uint64 timestamp, uint192 capacity, uint256 leakRate)
        external
        pure
    {
        LibLeakyBucket.headroomAt(checkpoint, timestamp, capacity, leakRate);
    }

    /// The fields do not bleed into each other. Changing one across its whole
    /// range never moves the other — both directions, which is what the claim
    /// says and what a packing bug needs.
    ///
    /// The timestamp is in the low bits, so its overspill would land in the
    /// level, which is a bucket reading fuller or emptier than it is. The level
    /// is read at its own checkpoint so no leak is credited and the reading is
    /// the field itself.
    function testFieldsDoNotAlias(uint192 level, uint64 timestamp, uint192 otherLevel, uint64 otherTimestamp)
        external
        pure
    {
        // Moving the level across its whole range never moves the timestamp.
        // A fill of zero rewrites the word, so the timestamp that comes back is
        // the one that went in whatever the level beside it was.
        assertEq(
            LibCheckpointWord.storedTimestamp(
                LibLeakyBucket.fill(LibCheckpointWord.packed(level, timestamp), timestamp, type(uint192).max, 0, 0)
            ),
            timestamp
        );
        assertEq(
            LibCheckpointWord.storedTimestamp(
                LibLeakyBucket.fill(LibCheckpointWord.packed(otherLevel, timestamp), timestamp, type(uint192).max, 0, 0)
            ),
            timestamp
        );

        // And moving the timestamp across its whole range never moves the
        // level.
        assertEq(LibCheckpointWord.levelAt(LibCheckpointWord.packed(level, timestamp), timestamp, 0), level);
        assertEq(LibCheckpointWord.levelAt(LibCheckpointWord.packed(level, otherTimestamp), otherTimestamp, 0), level);
    }

    /// A fill at a timestamp *behind* the stored checkpoint must not move the
    /// checkpoint back to it. The read path saturates the elapsed time at zero
    /// and credits no leak for the backwards step, so nothing is handed out on
    /// the way in; a regressed checkpoint hands it out on the way out instead,
    /// because the next read measures its elapsed time from the earlier second
    /// and credits leak for time that had already passed before this fill.
    ///
    /// A full bucket of 3600 at t=1000, leaking one unit a second, then a zero
    /// amount fill at t=500 — which is documented as "a checkpoint and nothing
    /// else". One second after the original fill exactly one unit has leaked,
    /// so exactly one unit fits. Regressing the checkpoint to 500 would measure
    /// 501 seconds and offer 501 units.
    function testFillBehindTheCheckpointGrantsNoHeadroom() external pure {
        uint256 capacity = 3600e18;
        uint256 leakRate = 1e18;

        uint256 full = LibLeakyBucket.fill(0, 1000, capacity, leakRate, capacity);
        assertEq(LibCheckpointWord.storedLevel(full), 3600e18);
        assertEq(LibCheckpointWord.storedTimestamp(full), 1000);

        uint256 backwards = LibLeakyBucket.fill(full, 500, capacity, leakRate, 0);
        assertEq(LibCheckpointWord.storedLevel(backwards), 3600e18);
        assertEq(LibCheckpointWord.storedTimestamp(backwards), 1000);

        assertEq(LibLeakyBucket.headroomAt(backwards, 1001, capacity, leakRate), 1e18);
        assertEq(
            LibLeakyBucket.headroomAt(backwards, 1001, capacity, leakRate),
            LibLeakyBucket.headroomAt(full, 1001, capacity, leakRate)
        );
    }

    /// The general form of the case above. A zero amount fill at any second at
    /// or behind the stored checkpoint is not observable at any later second:
    /// the level and the headroom both read exactly as they would have if the
    /// call had never been made. Nothing is gained by calling with a stale
    /// clock, so a non monotonic clock is not an attack on the cap.
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

        uint256 checkpointWord = LibCheckpointWord.packed(level, checkpoint);
        uint256 filled = LibLeakyBucket.fill(checkpointWord, behind, capacity, leakRate, 0);

        assertEq(
            LibCheckpointWord.levelAt(filled, later, leakRate),
            LibCheckpointWord.levelAt(checkpointWord, later, leakRate)
        );
        assertEq(
            LibLeakyBucket.headroomAt(filled, later, capacity, leakRate),
            LibLeakyBucket.headroomAt(checkpointWord, later, capacity, leakRate)
        );
    }

    /// The headline property of the leak, through the write path, which is the
    /// only path there is. Checkpointing part way through an interval gives the
    /// identical level to not checkpointing at all, with no rounding slack.
    /// Call frequency is therefore not observable in the cap, so a caller
    /// cannot gain or lose allowance by touching the bucket more or less often.
    /// Implementations that leak at `capacity / window` per second take a floor
    /// division per checkpoint and fail this.
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

        uint256 start = LibCheckpointWord.packed(capacity, t0);

        // Straight to t2.
        uint256 direct = LibCheckpointWord.levelAt(start, t2, leakRate);

        // Through a zero fill at t1, which is a pure checkpoint.
        uint256 viaCheckpoint =
            LibCheckpointWord.levelAt(LibLeakyBucket.fill(start, t1, capacity, leakRate, 0), t2, leakRate);

        assertEq(direct, viaCheckpoint);
    }

    /// The other half of "a zero word is a valid initial state", asserted
    /// rather than described because the library warns about it: it cannot tell
    /// a *cleared* slot from an untouched one, so `delete` on a bucket is a
    /// full refund of whatever was outstanding rather than cleanup.
    ///
    /// A bucket burst to its whole capacity at t=1000 offers nothing at t=1000.
    /// Cleared, it offers the entire capacity at that same second, with no time
    /// elapsed in between and nothing in the word to say it was ever used. The
    /// per-burst bound is per slot, and slots are erasable.
    function testAClearedSlotIsAFullRefundAtTheSameSecond() external pure {
        uint256 capacity = 3600e18;
        uint256 leakRate = 1e18;

        uint256 full = LibLeakyBucket.fill(0, 1000, capacity, leakRate, capacity);
        assertEq(LibLeakyBucket.headroomAt(full, 1000, capacity, leakRate), 0);

        // `delete sBuckets[minter]` is exactly this: the word becomes zero.
        uint256 cleared = 0;
        assertEq(LibLeakyBucket.headroomAt(cleared, 1000, capacity, leakRate), capacity);

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
    ///
    /// A future packed field whose bound is guarded at one entry point and
    /// forgotten at the other fails here.
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
            // A zero amount fits in every bucket, at or over capacity alike, so
            // the only thing left that can stop this fill is the second it was
            // asked to record.
            vm.expectRevert(abi.encodeWithSelector(LeakyBucketTimestampOverflow.selector, timestamp));
            this.externalFill(checkpoint, timestamp, capacity, leakRate, 0);
            return;
        }

        // Inside the domain both of them answer, and what `headroomAt` names is
        // what `fill` takes.
        uint256 headroom = LibLeakyBucket.headroomAt(checkpoint, timestamp, capacity, leakRate);
        LibLeakyBucket.fill(checkpoint, timestamp, capacity, leakRate, headroom);
    }

    /// The library cannot enforce a capacity it cannot store, so it refuses one
    /// rather than answering questions about it. Before this guard, `headroomAt`
    /// at a capacity above the level width named an amount that `fill` would
    /// not take, and the rejection carried the packing width rather than
    /// anything naming the misconfigured capacity. The error carries the
    /// capacity so whoever debugs it is pointed at the governance parameter
    /// rather than at the packing.
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
    /// narrowing of the policy space. This is the comparison a governance
    /// setter makes at the moment the capacity is set, which is the only point
    /// the misconfiguration can be fixed rather than merely detected.
    function testEveryStorableCapacityIsAccepted(uint256 checkpoint, uint64 timestamp, uint256 capacity) external pure {
        capacity = bound(capacity, 0, LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX);
        LibLeakyBucket.headroomAt(checkpoint, timestamp, capacity, 0);
    }

    /// At the widest capacity the library can store, the documented agreement
    /// holds exactly: `headroomAt` names the largest amount `fill` accepts,
    /// `fill` accepts it and stores it without truncating, and one unit more is
    /// rejected with the capacity error rather than with an arithmetic failure.
    ///
    /// This is the boundary the capacity guard exists to defend, so it is
    /// asserted as literals rather than left to the fuzzer. `pack` re-checks
    /// nothing, on the argument that `checkCapacity` bounds every level that
    /// can reach it; this is that argument stated as a test, at the one input
    /// where it is tight.
    function testTheWidestStorableCapacityIsExactlyFillableAndNotTruncated() external {
        uint256 capacity = LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX;

        uint256 headroom = LibLeakyBucket.headroomAt(0, 0, capacity, 0);
        assertEq(headroom, LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX);

        uint256 result = LibLeakyBucket.fill(0, 0, capacity, 0, headroom);
        assertEq(LibCheckpointWord.storedLevel(result), LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX);
        assertEq(LibCheckpointWord.storedTimestamp(result), 0);
        // Not truncated: the level that went in is the level that reads back,
        // and it offers nothing further at that same second.
        assertEq(LibLeakyBucket.headroomAt(result, 0, capacity, 0), 0);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, 0, headroom + 1));
        this.externalFill(0, 0, capacity, 0, headroom + 1);
    }

    /// A `timestamp` the packed field cannot hold is refused BY NAME, and
    /// nothing is stored. Failing closed at an unreachable date is the choice
    /// the library documents: a wrapped time field would read as a checkpoint
    /// in the distant past, which is an enormous leak, which is a full bucket
    /// of headroom nobody waited for.
    ///
    /// The amount is zero, so nothing but the second can be what refuses it: a
    /// zero fill fits in every bucket, at or over capacity alike.
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
    /// Every other test here names the errors symbolically, so the selector the
    /// suite expects is recomputed from whatever the signature currently is —
    /// a parameter added, removed, reordered or retyped keeps the suite green
    /// while silently changing what consumers decode.
    ///
    /// These three are the whole error surface: they are exactly what `fill`
    /// can raise, and `headroomAt` raises a subset of them. A fourth appearing
    /// here is a new thing for a consumer to handle and has to be added
    /// deliberately, where it can be recognised as the breaking change it is.
    ///
    /// The `bytes32` casts are because forge-std has no `bytes4` overload of
    /// `assertEq`.
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
