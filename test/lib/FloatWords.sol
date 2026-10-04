// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {Float, LibDecimalFloat} from "rain-math-float-0.2.5/src/lib/LibDecimalFloat.sol";

/// A whole number as a `Float` at exponent zero.
///
/// Every number in the suite is built here, fuzzed ones included: the fuzzer
/// draws a word, the bounds in `LeakyBucketAsserts` narrow it, and this packs
/// it. Fuzzing a `Float` directly would draw an exponent as well, and what a
/// bound said about the word would say nothing about the number.
function float(uint256 value) pure returns (Float) {
    //forge-lint: disable-next-line(unsafe-typecast)
    return LibDecimalFloat.packLossless(int256(value), 0);
}

/// The same, for the two numbers a bucket is allowed to be asked about with a
/// sign on them: a capacity and a leak rate, which the library refuses when
/// they are negative.
function signedFloat(int256 value) pure returns (Float) {
    return LibDecimalFloat.packLossless(value, 0);
}
