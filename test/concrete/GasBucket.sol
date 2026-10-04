// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Float, LibDecimalFloat} from "rain-math-float-0.2.5/src/lib/LibDecimalFloat.sol";
import {LibLeakyBucket, LeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title GasBucket
/// @notice One bucket and nothing else, so the gas tests measure the library.
///
/// Was `PackedBucket`, when the level and the timestamp shared a word. They do
/// not any more, so the name would have described a layout the contract no
/// longer has.
contract GasBucket {
    /// The bucket.
    LeakyBucket internal sBucket;

    constructor(Float capacity, Float leakRate) {
        sBucket.capacity = capacity;
        sBucket.leakRate = leakRate;
    }

    /// The library call and the stores, nothing else.
    function fill(Float amount) external {
        //forge-lint: disable-next-line(unsafe-typecast)
        Float timestamp = LibDecimalFloat.packLossless(int256(block.timestamp), 0);
        (Float level, Float checkpoint) = LibLeakyBucket.fill(sBucket, timestamp, amount);
        sBucket.level = level;
        sBucket.timestamp = checkpoint;
    }
}
