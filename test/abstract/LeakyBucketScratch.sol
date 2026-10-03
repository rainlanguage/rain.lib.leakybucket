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

    /// `LibLeakyBucket.levelAt` over a bucket built from these words.
    ///
    /// This derived the level as `capacity - headroomAt` while the library had
    /// no level read to call, which meant every assertion spelled `levelAt` was
    /// in fact exercising `headroomAt`. The library exports `levelAt` now, so
    /// this calls it: the tests that name the level read are the tests that
    /// cover it. That the two reads agree on a bucket under its capacity is
    /// pinned separately, in `LeakyBucketEmbedding`.
    ///
    /// `capacity` no longer has to be at or above the level and is here only to
    /// build the bucket and pass the domain check.
    /// @param level The stored level.
    /// @param checkpoint When `level` was recorded.
    /// @param timestamp The time to evaluate at.
    /// @param leakRate The leak in units per unit of time.
    /// @param capacity Any capacity the domain check accepts.
    /// @return The level as at `timestamp`.
    function levelAt(Float level, Float checkpoint, Float timestamp, Float leakRate, Float capacity)
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

    /// `checkPolicy` across an external boundary, for `expectRevert`.
    function externalCheckPolicy(Float capacity, Float leakRate) external pure {
        LibLeakyBucket.checkPolicy(capacity, leakRate);
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

    /// The library's own `levelAt` across an external boundary, for
    /// `expectRevert`. Distinct from the derived `levelAt` above, which reads
    /// through a headroom: this one is the export, and it carries its own domain
    /// check.
    function externalLevelAt(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate)
        external
        pure
        returns (Float)
    {
        return LibLeakyBucket.levelAt(bucket(level, checkpoint, capacity, leakRate), timestamp);
    }
}
