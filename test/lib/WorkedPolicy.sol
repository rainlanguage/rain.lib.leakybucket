// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

// The worked policy: a 3600 unit burst draining at one unit per second.
uint256 constant WORKED_CAPACITY = 3600e18;
uint256 constant WORKED_LEAK_RATE = 1e18;
uint256 constant WORKED_DRAIN = WORKED_CAPACITY / WORKED_LEAK_RATE;
