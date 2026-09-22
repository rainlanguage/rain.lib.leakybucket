// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {LibLeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title UnpackedBucket
/// @notice The same bucket as `PackedBucket` with the level and the checkpoint
/// in separate slots: what the codec avoids. One more `SLOAD` and one more
/// `SSTORE` on every fill, a second write the caller has to remember to make,
/// and the monotonic-checkpoint comparison the caller has to write itself
/// because nothing packs it in for them.
///
/// This is the CORRECT unpacked embedding, written out in full, because it is
/// the one a reader copies when the README sends them to `LibLeakyBucket`
/// directly. A minimal version that stored the clock unconditionally would be
/// shorter and cheaper and would reintroduce, in the repo's own example, the
/// backwards-checkpoint bug the codec was fixed for.
///
/// The gas subject for the unpacked side of the comparison in
/// `LibLeakyBucketGas.t.sol`.
contract UnpackedBucket {
    uint256 internal sLevel;
    uint256 internal sCheckpoint;

    /// Two `SLOAD`s, the library call, two `SSTORE`s.
    function fill(uint256 capacity, uint256 leakRate, uint256 amount) external {
        uint256 level = LibLeakyBucket.fillAt(sLevel, sCheckpoint, block.timestamp, capacity, leakRate, amount);
        sLevel = level;
        // The obligation a direct caller takes on, per `levelAt`'s NatSpec and
        // the README: never move the stored checkpoint backwards. A fill at or
        // behind the stored second credited no leak, so the level just computed
        // belongs to the stored second and not to the clock; writing the clock
        // back would leave an interval that has already been paid for to be
        // measured again on the next read.
        //
        // Comparing the clock is the whole point of the line, and it is the
        // conservative direction: a validator nudging `block.timestamp` can
        // only ever make the stored checkpoint later, never earlier, and a
        // later checkpoint credits less leak rather than more.
        // forge-lint: disable-next-line(block-timestamp)
        sCheckpoint = block.timestamp > sCheckpoint ? block.timestamp : sCheckpoint;
    }

    /// What would fit right now. A real embedding needs a view like this, and
    /// it is how the tests observe the checkpoint without reaching into slots.
    function headroom(uint256 capacity, uint256 leakRate) external view returns (uint256) {
        return LibLeakyBucket.headroomAt(sLevel, sCheckpoint, block.timestamp, capacity, leakRate);
    }
}
