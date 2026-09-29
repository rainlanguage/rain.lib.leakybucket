// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";

// The worked policy: a 3600 unit burst draining at one unit per second.
//
// Plain 3600 and 1, not 3600e18 and 1e18. The fixed point scale existed so a
// `uint256` could carry a fraction; a `Float` carries its own exponent, so the
// scale is noise that only moves where the precision boundary falls.
function workedCapacity() pure returns (Float) {
    return LibDecimalFloat.packLossless(3600, 0);
}

function workedLeakRate() pure returns (Float) {
    return LibDecimalFloat.packLossless(1, 0);
}

/// How long the worked policy takes to drain from full.
function workedDrain() pure returns (uint256) {
    return 3600;
}
