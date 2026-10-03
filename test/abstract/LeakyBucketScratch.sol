// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {LibLeakyBucket, LeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketScratch
/// @notice The library entry points taken as loose words. Every helper takes
/// the bucket as `level, checkpoint`, then the `timestamp`, then `capacity,
/// leakRate`.
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

    /// `LibLeakyBucket.levelAt` over a bucket built from these words.
    function levelAt(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate)
        internal
        pure
        returns (Float)
    {
        return LibLeakyBucket.levelAt(bucket(level, checkpoint, capacity, leakRate), timestamp);
    }

    /// `LibLeakyBucket.settle` over a bucket built from these words.
    function settle(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate)
        internal
        pure
        returns (Float, Float)
    {
        return LibLeakyBucket.settle(bucket(level, checkpoint, capacity, leakRate), timestamp);
    }

    /// `settle` across an external boundary, for `expectRevert`.
    function externalSettle(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate)
        external
        pure
        returns (Float, Float)
    {
        return settle(level, checkpoint, timestamp, capacity, leakRate);
    }

    /// `LibLeakyBucket.setPolicy` across an external boundary, for
    /// `expectRevert`.
    function externalSetPolicy(LeakyBucket memory stored, Float timestamp, Float capacity, Float leakRate)
        external
        pure
        returns (LeakyBucket memory)
    {
        return LibLeakyBucket.setPolicy(stored, timestamp, capacity, leakRate);
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

    /// `levelAt` across an external boundary, for `expectRevert`.
    function externalLevelAt(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate)
        external
        pure
        returns (Float)
    {
        return levelAt(level, checkpoint, timestamp, capacity, leakRate);
    }
}
