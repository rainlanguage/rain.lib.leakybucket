// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {Float, LibDecimalFloat} from "rain-math-float-0.2.5/src/lib/LibDecimalFloat.sol";

/// @title LibLeakyBucketSlow
/// @notice The leak one step at a time, as an oracle for the closed form.
library LibLeakyBucketSlow {
    using LibDecimalFloat for Float;

    /// Leak `steps` times, one unit of time per iteration.
    ///
    /// The oracle subtracts `leakRate` repeatedly where the library multiplies
    /// once and subtracts once, so the two agree only where `Float` addition is
    /// exact. That is the point: a disagreement is either a bug in the closed
    /// form or a precision boundary worth naming, and the tests keep `steps`
    /// small and the magnitudes near each other so neither hides the other.
    /// @param level The level at the start of the interval.
    /// @param steps How many whole units of time to leak. Keep it small.
    /// @param leakRate The leak in units per unit of time.
    /// @return The level at the end of the interval.
    function leakSlow(Float level, uint256 steps, Float leakRate) internal pure returns (Float) {
        Float zero = LibDecimalFloat.packLossless(0, 0);
        for (uint256 i = 0; i < steps; i++) {
            if (level.lte(leakRate)) {
                return zero;
            }
            level = level.sub(leakRate);
        }
        return level;
    }
}
