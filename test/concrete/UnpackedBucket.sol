// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {LibLeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title UnpackedBucket
/// @notice The same bucket as `PackedBucket` with the level and the checkpoint
/// in separate slots: what the codec avoids. Same arithmetic, same result, one
/// more `SLOAD` and one more `SSTORE` on every fill, and a second write the
/// caller has to remember to make. The gas subject for the unpacked side of the
/// comparison in `LibLeakyBucketGas.t.sol`.
contract UnpackedBucket {
    uint256 internal sLevel;
    uint256 internal sCheckpoint;

    /// Two `SLOAD`s, the library call, two `SSTORE`s.
    function fill(uint256 capacity, uint256 leakRate, uint256 amount) external {
        uint256 level = LibLeakyBucket.fillAt(sLevel, sCheckpoint, block.timestamp, capacity, leakRate, amount);
        sLevel = level;
        sCheckpoint = block.timestamp;
    }
}
