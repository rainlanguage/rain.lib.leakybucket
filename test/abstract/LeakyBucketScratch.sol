// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {LibLeakyBucket, LeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketScratch
/// @notice The library entry points taken as loose words.
abstract contract LeakyBucketScratch {
    using LibDecimalFloat for Float;

    function bucket(Float level, Float checkpoint, Float capacity, Float leakRate)
        internal
        pure
        returns (LeakyBucket memory)
    {
        return LeakyBucket({level: level, timestamp: checkpoint, capacity: capacity, leakRate: leakRate});
    }

    /// `LibLeakyBucket.fill` over a bucket built from these words.
    function fill(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate, Float amount)
        internal
        pure
        returns (Float, Float)
    {
        return LibLeakyBucket.fill(bucket(level, checkpoint, capacity, leakRate), timestamp, amount);
    }

    /// `LibLeakyBucket.headroomAt` over a bucket built from these words.
    function headroomAt(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate)
        internal
        pure
        returns (Float)
    {
        return LibLeakyBucket.headroomAt(bucket(level, checkpoint, capacity, leakRate), timestamp);
    }

    /// The outstanding level of a bucket at a time, derived from the one read
    /// the library exports rather than from the stored field, so a test that
    /// asserts on it is asserting on what a reader would see.
    ///
    /// `capacity` must be at or above the level, or the headroom clamps at zero
    /// and this returns the capacity rather than the level. The old version
    /// used `LEAKY_BUCKET_LEVEL_MAX` for the same purpose; there is no such
    /// bound on a `Float`, so the caller names a capacity it knows is enough.
    /// @param level The stored level.
    /// @param checkpoint When `level` was recorded.
    /// @param timestamp The time to evaluate at.
    /// @param leakRate The leak in units per unit of time.
    /// @param capacity A capacity at or above the level at `timestamp`.
    /// @return The level as at `timestamp`.
    function levelAt(Float level, Float checkpoint, Float timestamp, Float leakRate, Float capacity)
        internal
        pure
        returns (Float)
    {
        return capacity.sub(headroomAt(level, checkpoint, timestamp, capacity, leakRate));
    }

    /// `fill` across an external boundary, for `expectRevert`.
    function externalFill(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate, Float amount)
        external
        pure
        returns (Float, Float)
    {
        return fill(level, checkpoint, timestamp, capacity, leakRate, amount);
    }

    /// `headroomAt` across an external boundary, for `expectRevert`.
    function externalHeadroomAt(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate)
        external
        pure
        returns (Float)
    {
        return headroomAt(level, checkpoint, timestamp, capacity, leakRate);
    }
}
