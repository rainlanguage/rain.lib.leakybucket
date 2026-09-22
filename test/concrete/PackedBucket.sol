// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {LibLeakyBucketCheckpoint} from "../../src/lib/LibLeakyBucketCheckpoint.sol";

/// @title PackedBucket
/// @notice The bucket in one slot: what a concrete embedding the shipped codec
/// pays per fill. The gas subject for the packed side of the comparison in
/// `LibLeakyBucketGas.t.sol`.
contract PackedBucket {
    uint256 internal sCheckpoint;

    /// One `SLOAD`, the library call, one `SSTORE`.
    function fill(uint256 capacity, uint256 leakRate, uint256 amount) external {
        sCheckpoint = LibLeakyBucketCheckpoint.fill(sCheckpoint, block.timestamp, capacity, leakRate, amount);
    }
}
