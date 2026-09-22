// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {LibLeakyBucket, LeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketScratch
/// @notice The library entry points taken as loose words.
abstract contract LeakyBucketScratch {
    function bucket(uint256 checkpoint, uint256 capacity, uint256 leakRate) internal pure returns (LeakyBucket memory) {
        return LeakyBucket({checkpoint: checkpoint, capacity: capacity, leakRate: leakRate});
    }

    /// `LibLeakyBucket.fill` over a bucket built from these words.
    function fill(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        return LibLeakyBucket.fill(bucket(checkpoint, capacity, leakRate), timestamp, amount);
    }

    /// `LibLeakyBucket.headroomAt` over a bucket built from these words.
    function headroomAt(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate)
        internal
        pure
        returns (uint256)
    {
        return LibLeakyBucket.headroomAt(bucket(checkpoint, capacity, leakRate), timestamp);
    }

    /// The outstanding level of a bucket at a second, derived from the one read
    /// the library exports.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The second to evaluate at. Must be one the library can
    /// @param leakRate The leak in units per second.
    /// @return The level as at `timestamp`.
    function levelAt(uint256 checkpoint, uint256 timestamp, uint256 leakRate) internal pure returns (uint256) {
        return LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX
            - headroomAt(checkpoint, timestamp, LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX, leakRate);
    }

    /// `fill` across an external boundary, for `expectRevert`.
    function externalFill(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate, uint256 amount)
        external
        pure
        returns (uint256)
    {
        return fill(checkpoint, timestamp, capacity, leakRate, amount);
    }

    /// `headroomAt` across an external boundary, for `expectRevert`.
    function externalHeadroomAt(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate)
        external
        pure
        returns (uint256)
    {
        return headroomAt(checkpoint, timestamp, capacity, leakRate);
    }

    /// `pack` across an external boundary, for `expectRevert`.
    function externalPack(uint256 level, uint256 timestamp) external pure returns (uint256) {
        return LibLeakyBucket.pack(level, timestamp);
    }
}
