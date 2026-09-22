// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {LibLeakyBucket, LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {
    LibLeakyBucketCheckpoint,
    LeakyBucketCapacityOverflow,
    LeakyBucketLevelOverflow,
    LeakyBucketTimestampOverflow,
    LEAKY_BUCKET_LEVEL_MAX,
    LEAKY_BUCKET_TIMESTAMP_MAX,
    LEAKY_BUCKET_TIMESTAMP_BITS
} from "../../../src/lib/LibLeakyBucketCheckpoint.sol";

/// The codec has one job beyond packing: making it impossible to store a level
/// without storing the timestamp it belongs to. Everything here is either that
/// property or the truncation guards that keep the cap from failing open.
contract LibLeakyBucketCheckpointTest is Test {
    /// `expectRevert` needs an external call boundary.
    function externalPack(uint256 level, uint256 timestamp) external pure returns (uint256) {
        return LibLeakyBucketCheckpoint.pack(level, timestamp);
    }

    function externalFill(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate, uint256 amount)
        external
        pure
        returns (uint256)
    {
        return LibLeakyBucketCheckpoint.fill(checkpoint, timestamp, capacity, leakRate, amount);
    }

    function externalHeadroomAt(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate)
        external
        pure
        returns (uint256)
    {
        return LibLeakyBucketCheckpoint.headroomAt(checkpoint, timestamp, capacity, leakRate);
    }

    function externalFillableAt(
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure returns (uint256) {
        return LibLeakyBucketCheckpoint.fillableAt(checkpoint, timestamp, capacity, leakRate, amount);
    }

    function externalCheckCapacity(uint256 capacity) external pure {
        LibLeakyBucketCheckpoint.checkCapacity(capacity);
    }

    /// Every packable pair survives the round trip.
    function testPackUnpackRoundTrip(uint192 level, uint64 timestamp) external pure {
        (uint256 unpackedLevel, uint256 unpackedTimestamp) =
            LibLeakyBucketCheckpoint.unpack(LibLeakyBucketCheckpoint.pack(level, timestamp));
        assertEq(unpackedLevel, level);
        assertEq(unpackedTimestamp, timestamp);
    }

    /// `unpack` is total: every word in the space is some valid checkpoint, so
    /// a slot holding arbitrary bits reads as a bucket rather than reverting.
    function testUnpackIsTotalAndInvertsToTheSameWord(uint256 checkpoint) external pure {
        (uint256 level, uint256 timestamp) = LibLeakyBucketCheckpoint.unpack(checkpoint);
        assertEq(LibLeakyBucketCheckpoint.pack(level, timestamp), checkpoint);
    }

    /// The fields do not bleed into each other. Changing one across its whole
    /// range never moves the other.
    function testFieldsDoNotAlias(uint192 level, uint64 timestamp, uint192 otherLevel) external pure {
        (, uint256 timestampA) = LibLeakyBucketCheckpoint.unpack(LibLeakyBucketCheckpoint.pack(level, timestamp));
        (, uint256 timestampB) = LibLeakyBucketCheckpoint.unpack(LibLeakyBucketCheckpoint.pack(otherLevel, timestamp));
        assertEq(timestampA, timestampB);
        assertEq(timestampA, timestamp);
    }

    /// A zero word is an empty bucket checkpointed at the epoch, so an
    /// untouched slot needs no initializer.
    function testZeroWordIsEmptyAtEpoch() external pure {
        (uint256 level, uint256 timestamp) = LibLeakyBucketCheckpoint.unpack(0);
        assertEq(level, 0);
        assertEq(timestamp, 0);
    }

    /// An oversized level reverts rather than truncating. Truncation here would
    /// silently drop the high bits of the outstanding level, which reads as a
    /// far emptier bucket than reality.
    function testPackRevertsOnOversizedLevel(uint256 level, uint64 timestamp) external {
        level = bound(level, LEAKY_BUCKET_LEVEL_MAX + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketLevelOverflow.selector, level));
        this.externalPack(level, timestamp);
    }

    /// An oversized timestamp reverts rather than truncating. A wrapped time
    /// field reads as a checkpoint in the distant past, which is an enormous
    /// leak, which is a full bucket of headroom nobody waited for. Failing
    /// closed at an unreachable date beats failing open at a reachable one.
    function testPackRevertsOnOversizedTimestamp(uint192 level, uint256 timestamp) external {
        timestamp = bound(timestamp, LEAKY_BUCKET_TIMESTAMP_MAX + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketTimestampOverflow.selector, timestamp));
        this.externalPack(level, timestamp);
    }

    /// The packed reads agree with the unpacked library they delegate to. Every
    /// read is covered, including `fillableAt`: a delegation that passed the
    /// clock where the stored checkpoint belongs would answer from an unleaked
    /// level and name a later second than the true one.
    ///
    /// The `capacity` is `uint192` because that is the whole domain the packed
    /// reads accept. Above `LEAKY_BUCKET_LEVEL_MAX` they refuse to answer
    /// rather than answering something `fill` would not honour, which is
    /// `testPackedReadsRejectAnUnenforceableCapacity` below.
    function testPackedReadsMatchCore(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure {
        uint256 packed = LibLeakyBucketCheckpoint.pack(level, checkpoint);
        assertEq(
            LibLeakyBucketCheckpoint.levelAt(packed, timestamp, leakRate),
            LibLeakyBucket.levelAt(level, checkpoint, timestamp, leakRate)
        );
        assertEq(
            LibLeakyBucketCheckpoint.headroomAt(packed, timestamp, capacity, leakRate),
            LibLeakyBucket.headroomAt(level, checkpoint, timestamp, capacity, leakRate)
        );
        assertEq(
            LibLeakyBucketCheckpoint.fillableAt(packed, timestamp, capacity, leakRate, amount),
            LibLeakyBucket.fillableAt(level, checkpoint, timestamp, capacity, leakRate, amount)
        );
    }

    /// The property the codec exists for: a successful fill returns a word that
    /// carries the new level *and* a timestamp that level actually belongs to.
    /// A caller cannot store one without the other, so the double credit bug
    /// that a two value API invites is not reachable from here.
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
    /// - It is never ahead of both, so the codec is not silently freezing the
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
        uint256 packed = LibLeakyBucketCheckpoint.pack(level, checkpoint);
        uint256 headroom = LibLeakyBucketCheckpoint.headroomAt(packed, timestamp, capacity, leakRate);
        amount = bound(amount, 0, headroom);

        (uint256 newLevel, uint256 newTimestamp) = LibLeakyBucketCheckpoint.unpack(
            LibLeakyBucketCheckpoint.fill(packed, timestamp, capacity, leakRate, amount)
        );

        assertGe(newTimestamp, checkpoint);
        assertGe(newTimestamp, timestamp);
        assertLe(newTimestamp, timestamp > checkpoint ? timestamp : checkpoint);

        assertEq(newLevel, LibLeakyBucket.levelAt(level, checkpoint, newTimestamp, leakRate) + amount);
        assertEq(newLevel, LibLeakyBucket.fillAt(level, checkpoint, timestamp, capacity, leakRate, amount));
    }

    /// Filling over the headroom reverts with the core error and the caller
    /// stores nothing.
    function testFillRevertsOverHeadroom(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        uint256 packed = LibLeakyBucketCheckpoint.pack(level, checkpoint);
        uint256 levelNow = LibLeakyBucketCheckpoint.levelAt(packed, timestamp, leakRate);
        uint256 headroom = LibLeakyBucketCheckpoint.headroomAt(packed, timestamp, capacity, leakRate);
        amount = bound(amount, headroom + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelNow, amount));
        this.externalFill(packed, timestamp, capacity, leakRate, amount);
    }

    /// Repeated fills through the codec obey the same no drift property as the
    /// core: splitting one fill into two at an intermediate second lands on the
    /// same level as doing it in one go.
    function testFillThroughCheckpointHasNoDrift(
        uint192 capacity,
        uint256 leakRate,
        uint64 t0,
        uint64 gapA,
        uint64 gapB
    ) external pure {
        leakRate = bound(leakRate, 0, type(uint128).max);
        uint64 t1 = uint64(bound(gapA, 0, type(uint64).max - t0)) + t0;
        uint64 t2 = uint64(bound(gapB, 0, type(uint64).max - t1)) + t1;

        uint256 start = LibLeakyBucketCheckpoint.pack(capacity, t0);

        // Straight to t2.
        uint256 direct = LibLeakyBucketCheckpoint.levelAt(start, t2, leakRate);

        // Through a zero fill at t1, which is a pure checkpoint.
        uint256 viaCheckpoint = LibLeakyBucketCheckpoint.levelAt(
            LibLeakyBucketCheckpoint.fill(start, t1, capacity, leakRate, 0), t2, leakRate
        );

        assertEq(direct, viaCheckpoint);
    }

    /// The layout is the level in the high bits and the timestamp in the low
    /// ones, stated as a value rather than left to the constants.
    function testLayoutIsLevelHighTimestampLow() external pure {
        assertEq(LEAKY_BUCKET_TIMESTAMP_BITS, 64);
        assertEq(LEAKY_BUCKET_TIMESTAMP_MAX, type(uint64).max);
        assertEq(LEAKY_BUCKET_LEVEL_MAX, type(uint192).max);
        assertEq(LibLeakyBucketCheckpoint.pack(1, 0), 1 << 64);
        assertEq(LibLeakyBucketCheckpoint.pack(0, 1), 1);
        assertEq(LibLeakyBucketCheckpoint.pack(LEAKY_BUCKET_LEVEL_MAX, LEAKY_BUCKET_TIMESTAMP_MAX), type(uint256).max);
    }

    /// `fillableAt` answers from the STORED checkpoint, not from the clock it
    /// is asked about. A bucket filled to 3600 at t=1000, asked at t=1900 when
    /// it can next take 1800: 900 seconds have leaked, so the level is 2700 and
    /// it needs to reach 1800, which is another 900 seconds — t=2800.
    ///
    /// Reading the clock as the checkpoint instead would see an unleaked 3600,
    /// need 1800 seconds rather than 900, and answer t=3700. The exact second
    /// is asserted so the two are distinguishable.
    function testFillableAtAnswersFromTheStoredCheckpointNotTheClock() external pure {
        uint256 capacity = 3600e18;
        uint256 leakRate = 1e18;
        uint256 packed = LibLeakyBucketCheckpoint.pack(3600e18, 1000);

        // Sanity: at t=1900 the bucket has leaked 900 and 1800 does not fit.
        assertEq(LibLeakyBucketCheckpoint.levelAt(packed, 1900, leakRate), 2700e18);
        assertEq(LibLeakyBucketCheckpoint.headroomAt(packed, 1900, capacity, leakRate), 900e18);

        assertEq(LibLeakyBucketCheckpoint.fillableAt(packed, 1900, capacity, leakRate, 1800e18), 2800);

        // And it is exactly right: 1800 fits at 2800 and does not at 2799.
        assertGe(LibLeakyBucketCheckpoint.headroomAt(packed, 2800, capacity, leakRate), 1800e18);
        assertLt(LibLeakyBucketCheckpoint.headroomAt(packed, 2799, capacity, leakRate), 1800e18);
    }

    /// A fill at a timestamp *behind* the stored checkpoint must not move the
    /// checkpoint back to it. The read path saturates the elapsed time at zero
    /// and credits no leak for the backwards step, so nothing is handed out on
    /// the way in; a regressed checkpoint hands it out on the way out instead,
    /// because the next read measures its elapsed time from the earlier second
    /// and credits leak for time that had already passed before this fill.
    ///
    /// A full bucket of 3600 at t=1000, leaking one unit a second, then a zero
    /// amount fill at t=500 — which the core documents as "a checkpoint and
    /// nothing else". One second after the original fill exactly one unit has
    /// leaked, so exactly one unit fits. Regressing the checkpoint to 500 would
    /// measure 501 seconds and offer 501 units.
    function testFillBehindTheCheckpointGrantsNoHeadroom() external pure {
        uint256 capacity = 3600e18;
        uint256 leakRate = 1e18;

        uint256 packed = LibLeakyBucketCheckpoint.fill(0, 1000, capacity, leakRate, capacity);
        (uint256 level, uint256 checkpoint) = LibLeakyBucketCheckpoint.unpack(packed);
        assertEq(level, 3600e18);
        assertEq(checkpoint, 1000);

        uint256 backwards = LibLeakyBucketCheckpoint.fill(packed, 500, capacity, leakRate, 0);
        (uint256 backwardsLevel, uint256 backwardsCheckpoint) = LibLeakyBucketCheckpoint.unpack(backwards);
        assertEq(backwardsLevel, 3600e18);
        assertEq(backwardsCheckpoint, 1000);

        assertEq(LibLeakyBucketCheckpoint.headroomAt(backwards, 1001, capacity, leakRate), 1e18);
        assertEq(
            LibLeakyBucketCheckpoint.headroomAt(backwards, 1001, capacity, leakRate),
            LibLeakyBucketCheckpoint.headroomAt(packed, 1001, capacity, leakRate)
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

        uint256 packed = LibLeakyBucketCheckpoint.pack(level, checkpoint);
        uint256 filled = LibLeakyBucketCheckpoint.fill(packed, behind, capacity, leakRate, 0);

        assertEq(
            LibLeakyBucketCheckpoint.levelAt(filled, later, leakRate),
            LibLeakyBucketCheckpoint.levelAt(packed, later, leakRate)
        );
        assertEq(
            LibLeakyBucketCheckpoint.headroomAt(filled, later, capacity, leakRate),
            LibLeakyBucketCheckpoint.headroomAt(packed, later, capacity, leakRate)
        );
    }

    /// The packed API cannot enforce a capacity it cannot store, so it refuses
    /// one rather than answering questions about it. Before this guard,
    /// `headroomAt` at a capacity above the level width named an amount that
    /// `fill` would not take, and the rejection carried `LeakyBucketLevelOverflow`
    /// — the packing width — rather than anything naming the misconfigured
    /// capacity. Every entry point that takes a `capacity` is covered, and the
    /// error carries the capacity so whoever debugs it is pointed at the
    /// governance parameter rather than at the codec.
    function testPackedReadsRejectAnUnenforceableCapacity(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external {
        capacity = bound(capacity, LEAKY_BUCKET_LEVEL_MAX + 1, type(uint256).max);
        uint256 packed = LibLeakyBucketCheckpoint.pack(level, checkpoint);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityOverflow.selector, capacity));
        this.externalCheckCapacity(capacity);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityOverflow.selector, capacity));
        this.externalHeadroomAt(packed, timestamp, capacity, leakRate);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityOverflow.selector, capacity));
        this.externalFillableAt(packed, timestamp, capacity, leakRate, amount);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityOverflow.selector, capacity));
        this.externalFill(packed, timestamp, capacity, leakRate, amount);
    }

    /// The other side of the guard: everything up to and including the level
    /// width is accepted, so the check is a bound on what the codec can store
    /// and not a narrowing of the policy space. This is what a governance
    /// setter calls at the moment the capacity is set, which is the point the
    /// constant's documentation asks for.
    function testCheckCapacityAcceptsEverythingItCanStore(uint256 capacity) external pure {
        capacity = bound(capacity, 0, LEAKY_BUCKET_LEVEL_MAX);
        LibLeakyBucketCheckpoint.checkCapacity(capacity);
    }

    /// At the widest capacity the codec can store, the documented agreement
    /// holds exactly: `headroomAt` names the largest amount `fill` accepts,
    /// `fill` accepts it, and one unit more is rejected with the capacity error
    /// rather than the packing width. The boundary is where the two used to
    /// disagree, so it is asserted as literals rather than left to the fuzzer.
    function testHeadroomAtTheWidestStorableCapacityIsExactlyFillable() external {
        uint256 capacity = LEAKY_BUCKET_LEVEL_MAX;

        uint256 headroom = LibLeakyBucketCheckpoint.headroomAt(0, 0, capacity, 0);
        assertEq(headroom, LEAKY_BUCKET_LEVEL_MAX);

        (uint256 newLevel, uint256 newTimestamp) =
            LibLeakyBucketCheckpoint.unpack(LibLeakyBucketCheckpoint.fill(0, 0, capacity, 0, headroom));
        assertEq(newLevel, LEAKY_BUCKET_LEVEL_MAX);
        assertEq(newTimestamp, 0);

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, 0, headroom + 1));
        this.externalFill(0, 0, capacity, 0, headroom + 1);
    }

    /// Whatever `headroomAt` reports is a fill the codec takes, at every input
    /// it will answer at all. The claim is the NatSpec's own words — "the
    /// largest amount `fill` would accept" — and the half that failed was
    /// acceptance, not rejection, so acceptance is what is fuzzed here.
    function testHeadroomAtIsAlwaysFillable(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint192 capacity,
        uint256 leakRate
    ) external pure {
        uint256 packed = LibLeakyBucketCheckpoint.pack(level, checkpoint);
        uint256 headroom = LibLeakyBucketCheckpoint.headroomAt(packed, timestamp, capacity, leakRate);

        (uint256 newLevel,) = LibLeakyBucketCheckpoint.unpack(
            LibLeakyBucketCheckpoint.fill(packed, timestamp, capacity, leakRate, headroom)
        );
        assertLe(newLevel, LEAKY_BUCKET_LEVEL_MAX);
    }

    /// The other half of "a zero word is a valid initial state", asserted
    /// rather than described because the library now warns about it: the codec
    /// cannot tell a *cleared* slot from an untouched one, so `delete` on a
    /// bucket is a full refund of whatever was outstanding rather than cleanup.
    ///
    /// A bucket burst to its whole capacity at t=1000 offers nothing at t=1000.
    /// Cleared, it offers the entire capacity at that same second, with no time
    /// elapsed in between and nothing in the word to say it was ever used. The
    /// per-burst bound is per slot, and slots are erasable.
    function testAClearedSlotIsAFullRefundAtTheSameSecond() external pure {
        uint256 capacity = 3600e18;
        uint256 leakRate = 1e18;

        uint256 full = LibLeakyBucketCheckpoint.fill(0, 1000, capacity, leakRate, capacity);
        assertEq(LibLeakyBucketCheckpoint.headroomAt(full, 1000, capacity, leakRate), 0);

        // `delete sBuckets[minter]` is exactly this: the word becomes zero.
        uint256 cleared = 0;
        assertEq(LibLeakyBucketCheckpoint.headroomAt(cleared, 1000, capacity, leakRate), capacity);

        // And it is the same word an untouched slot holds, so no read here can
        // distinguish the two. The warning is a warning because the codec
        // cannot enforce it.
        assertEq(cleared, LibLeakyBucketCheckpoint.pack(0, 0));
    }
}
