// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {LibLeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketExternal
/// @notice `expectRevert` needs an external call boundary, and a `library`
/// call is internal. Inherited by every test that asserts a revert out of
/// `LibLeakyBucket.fillAt`, so the boundary is declared once and a change to
/// `fillAt`'s signature is a one file edit.
abstract contract LeakyBucketExternal {
    function externalFillAt(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) external pure returns (uint256) {
        return LibLeakyBucket.fillAt(level, checkpoint, timestamp, capacity, leakRate, amount);
    }
}
