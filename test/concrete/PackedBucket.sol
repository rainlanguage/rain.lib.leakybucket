// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {LibLeakyBucket, LeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title PackedBucket
/// @notice One bucket and nothing else, so the gas tests measure the library.
contract PackedBucket {
    /// The bucket.
    LeakyBucket internal sBucket;

    constructor(uint256 capacity, uint256 leakRate) {
        sBucket.capacity = capacity;
        sBucket.leakRate = leakRate;
    }

    /// The library call and the one store, nothing else.
    function fill(uint256 amount) external {
        sBucket.checkpoint = LibLeakyBucket.fill(sBucket, block.timestamp, amount);
    }
}
