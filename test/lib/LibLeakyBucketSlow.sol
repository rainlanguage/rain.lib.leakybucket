// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title LibLeakyBucketSlow
/// @notice The leak, written the way the bucket is described rather than the
/// way it is computed: one second at a time, subtracting `leakRate` and
/// stopping at empty. It is `O(elapsed)` and would never ship, which is the
/// point. `LibLeakyBucket.leak` collapses the same loop into one multiply, and
/// the differential test asserts the two agree over every input where the loop
/// is affordable to run.
library LibLeakyBucketSlow {
    /// Leak `elapsed` times, one second per iteration.
    /// @param level The level at the start of the interval.
    /// @param elapsed The length of the interval in seconds. Keep it small;
    /// this is a loop.
    /// @param leakRate The leak in units per second.
    /// @return The level at the end of the interval.
    function leakSlow(uint256 level, uint256 elapsed, uint256 leakRate) internal pure returns (uint256) {
        for (uint256 i = 0; i < elapsed; i++) {
            if (level <= leakRate) {
                return 0;
            }
            level -= leakRate;
        }
        return level;
    }
}
