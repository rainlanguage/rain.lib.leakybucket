// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {LibLeakyBucket, LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {
    LibLeakyBucketCheckpoint,
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
    function testPackedReadsMatchCore(
        uint192 level,
        uint64 checkpoint,
        uint64 timestamp,
        uint256 capacity,
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
    /// carries the new level *and* the timestamp it was computed at. A caller
    /// cannot store one without the other, so the double credit bug that a two
    /// value API invites is not reachable from here.
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

        assertEq(newTimestamp, timestamp);
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
}
