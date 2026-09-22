// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// The one worked policy the suite examines: a 3600 unit burst draining at one
/// unit per second. Defined here once so that every test saying "half a drain
/// time" is talking about the same half hour, and so `WORKED_DRAIN` cannot
/// drift away from the two numbers it is a quotient of.

/// @dev The burst.
uint256 constant WORKED_CAPACITY = 3600e18;

/// @dev The sustained rate, in units per second.
uint256 constant WORKED_LEAK_RATE = 1e18;

/// @dev Derived, not restated: the seconds a full bucket takes to empty. One
/// hour, at the values above.
uint256 constant WORKED_DRAIN = WORKED_CAPACITY / WORKED_LEAK_RATE;
