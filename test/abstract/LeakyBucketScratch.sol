// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {LibLeakyBucket, LeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketScratch
/// @notice The library's two entry points taken as loose words.
///
/// The library takes a `LeakyBucket` in memory. A property test has a
/// checkpoint word, a policy pair and a clock, fuzzed over their whole ranges,
/// that it wants the library's answer at. Every call below builds the struct
/// from the words it is handed and calls the real entry point, so a property is
/// stated over words and observed through the surface a consumer sees, with no
/// second copy of the arithmetic in between.
///
/// It also holds the external boundary `expectRevert` needs: a `library` call
/// is internal and cannot be expected to revert, so both entry points are
/// exposed through `external` functions here. There are two because there are
/// two entry points, and the rule that they refuse exactly the same arguments
/// is the library's central claim, so both need a boundary.
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
    ///
    /// `headroomAt` against the widest enforceable capacity is
    /// `LEAKY_BUCKET_LEVEL_MAX - level`, exactly: a level read out of a stored
    /// word can never exceed that bound, so the saturation never bites and the
    /// subtraction here inverts it. That identity is why `levelAt` is not
    /// surface — anyone holding the word can already compute it.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The second to evaluate at. Must be one the library can
    /// record, since `headroomAt` refuses any other.
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
}
