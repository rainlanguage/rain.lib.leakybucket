// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @title LibCheckpointWord
/// @notice The checkpoint word, restated independently of `src/`, so the tests
/// that pin the layout are an oracle rather than an echo of the thing they
/// check. `LibLeakyBucket` packs and unpacks privately and exposes neither, on
/// the grounds that a consumer stores the word whole and never looks inside it;
/// a test has to look inside it, and this is where the looking is written down.
///
/// The same role `LibLeakyBucketSlow` plays for the leak: a second, dumber
/// statement of the same thing, kept apart from the one that ships. Nothing
/// here calls into `src/` at all.
library LibCheckpointWord {
    /// @dev Bits the timestamp occupies, in the low end of the word. Spelled as
    /// a literal here on purpose — deriving it from the library would make
    /// every layout assertion below a tautology.
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
