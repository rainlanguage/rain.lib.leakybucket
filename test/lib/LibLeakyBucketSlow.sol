// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @title LibLeakyBucketSlow
/// @notice The leak one second at a time, as an oracle for the closed form.
library LibLeakyBucketSlow {
    /// Leak `elapsed` times, one second per iteration.
    /// @param level The level at the start of the interval.
    /// @param elapsed The length of the interval in seconds. Keep it small;
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
