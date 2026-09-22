// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {LibLeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title PackedBucket
/// @notice The bucket in one slot, and nothing else: the smallest embedding
/// that can be measured, so the figures in `LibLeakyBucketGas.t.sol` are the
/// library's cost rather than a harness's. `LeakyBucketMintCap` is the shape a
/// real concrete takes; this is the shape a stopwatch takes.
contract PackedBucket {
    uint256 internal sCheckpoint;

    /// One `SLOAD`, the library call, one `SSTORE`.
    function fill(uint256 capacity, uint256 leakRate, uint256 amount) external {
        sCheckpoint = LibLeakyBucket.fill(sCheckpoint, block.timestamp, capacity, leakRate, amount);
    }
}
