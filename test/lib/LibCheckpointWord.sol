// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @title LibCheckpointWord
/// @notice The checkpoint word layout restated independently of `src/`.
library LibCheckpointWord {
    /// A literal on purpose; deriving it from the library would be a tautology.
    uint256 internal constant TIMESTAMP_BITS = 64;

    /// Build a checkpoint word from its two fields.
    function packed(uint192 level, uint64 timestamp) internal pure returns (uint256) {
        return (uint256(level) << TIMESTAMP_BITS) | uint256(timestamp);
    }

    /// The level field of a checkpoint word.
    function storedLevel(uint256 checkpoint) internal pure returns (uint256) {
        return checkpoint >> TIMESTAMP_BITS;
    }

    /// The timestamp field of a checkpoint word.
    function storedTimestamp(uint256 checkpoint) internal pure returns (uint256) {
        return checkpoint & type(uint64).max;
    }
}
