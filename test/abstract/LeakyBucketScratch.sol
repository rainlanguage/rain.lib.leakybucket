// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {LibLeakyBucket, LeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketScratch
/// @notice One scratch bucket in this contract's storage, and the library's
/// two entry points over it, taking the bucket as loose words.
///
/// The library takes a `LeakyBucket storage`, because that is what a consumer
/// has. A property test has the opposite: a checkpoint word, a policy pair and
/// a clock, fuzzed over their whole ranges, that it wants to observe the
/// library's answer at. This contract is the join. Every call below loads the
/// scratch bucket from the words it is handed and then calls the real entry
/// point on it, so a property is stated over words and observed through the
/// surface a consumer sees, with no second copy of the arithmetic in between.
///
/// Loading is a full overwrite of all three fields, so the scratch carries
/// nothing from one call to the next: two calls with the same words see the
/// same bucket, however many calls came between them.
///
/// It also holds the external boundary `expectRevert` needs: a `library` call
/// is internal and cannot be expected to revert, so the two entry points are
/// exposed through `external` functions here. Inherited by every test that
/// asserts a revert out of the library, so the boundary is declared once and a
/// change to either entry point's signature is a one file edit. There are two
/// because there are two entry points, and the rule that they refuse exactly
/// the same arguments is the library's central claim, so both need a boundary.
abstract contract LeakyBucketScratch {
    /// The one bucket every word-shaped call below is loaded into. `internal`
    /// rather than `private` so a test can read a field back after a call,
    /// which is how the stored word is examined.
    LeakyBucket internal sBucket;

    /// Overwrite the scratch bucket with these three words.
    function load(uint256 checkpoint, uint256 capacity, uint256 leakRate) internal returns (LeakyBucket storage) {
        sBucket = LeakyBucket({checkpoint: checkpoint, capacity: capacity, leakRate: leakRate});
        return sBucket;
    }

    /// `LibLeakyBucket.fill` over a bucket loaded from these words. Returns
    /// the checkpoint word the fill left behind, which is the whole of what it
    /// writes.
    function fill(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate, uint256 amount)
        internal
        returns (uint256)
    {
        LeakyBucket storage bucket = load(checkpoint, capacity, leakRate);
        LibLeakyBucket.fill(bucket, timestamp, amount);
        return bucket.checkpoint;
    }

    /// `LibLeakyBucket.headroomAt` over a bucket loaded from these words.
    function headroomAt(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate)
        internal
        returns (uint256)
    {
        return LibLeakyBucket.headroomAt(load(checkpoint, capacity, leakRate), timestamp);
    }

    /// The outstanding level of a bucket at a second, derived from the one read
    /// the library exports.
    ///
    /// `headroomAt` against the widest enforceable capacity is
    /// `LEAKY_BUCKET_LEVEL_MAX - level`, exactly: a level read out of a stored
    /// word can never exceed that bound, so the saturation never bites and the
    /// subtraction here inverts it. That identity is why `levelAt` is not
    /// surface — anyone holding the word can already compute it — and using it
    /// throughout the suite is the standing demonstration that nothing here
    /// needs a read the library does not have.
    ///
    /// It lives here rather than beside the layout oracle in
    /// `LibCheckpointWord` because the read it goes through takes a bucket in
    /// storage, and a library has none to offer.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The second to evaluate at. Must be one the library can
    /// record, since `headroomAt` refuses any other.
    /// @param leakRate The leak in units per second.
    /// @return The level as at `timestamp`.
    function levelAt(uint256 checkpoint, uint256 timestamp, uint256 leakRate) internal returns (uint256) {
        return LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX
            - headroomAt(checkpoint, timestamp, LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX, leakRate);
    }

    /// `fill` across an external boundary, for `expectRevert`.
    function externalFill(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate, uint256 amount)
        external
        returns (uint256)
    {
        return fill(checkpoint, timestamp, capacity, leakRate, amount);
    }

    /// `headroomAt` across an external boundary, for `expectRevert`.
    function externalHeadroomAt(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate)
        external
        returns (uint256)
    {
        return headroomAt(checkpoint, timestamp, capacity, leakRate);
    }
}
