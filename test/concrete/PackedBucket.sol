// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {LibLeakyBucket, LeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title PackedBucket
/// @notice One bucket, and nothing else: the smallest embedding that can be
/// measured, so the figures in `LibLeakyBucketGas.t.sol` are the library's
/// cost rather than a harness's. `LeakyBucketMintCap` is the shape a real
/// concrete takes; this is the shape a stopwatch takes.
///
/// The policy is written once, at construction, so a measured `fill` is the
/// library reading the bucket's three fields and this contract storing the
/// checkpoint it returns, not a policy write beside it.
contract PackedBucket {
    /// The bucket. Its `checkpoint` is the first field of the first state
    /// variable, so it is slot 0, which the gas test reads back directly.
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
