// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {LibLeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketExternal
/// @notice `expectRevert` needs an external call boundary, and a `library` call
/// is internal. Inherited by every test that asserts a revert out of the
/// library, so the boundary is declared once and a change to either entry
/// point's signature is a one file edit.
///
/// There are two functions here because there are two entry points. Both of
/// them revert, and the rule that they refuse exactly the same arguments is
/// the library's central claim, so both need a boundary.
abstract contract LeakyBucketExternal {
    function externalFill(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate, uint256 amount)
        external
        pure
        returns (uint256)
    {
        return LibLeakyBucket.fill(checkpoint, timestamp, capacity, leakRate, amount);
    }

    function externalHeadroomAt(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate)
        external
        pure
        returns (uint256)
    {
        return LibLeakyBucket.headroomAt(checkpoint, timestamp, capacity, leakRate);
    }
}
