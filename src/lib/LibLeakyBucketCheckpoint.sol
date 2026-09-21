// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {LibLeakyBucket} from "./LibLeakyBucket.sol";

/// @dev Bits the timestamp occupies in a packed checkpoint, in the low end of
/// the word.
uint256 constant LEAKY_BUCKET_TIMESTAMP_BITS = 64;

/// @dev Largest timestamp a packed checkpoint can hold, in seconds. Around
/// 5.8e11 years, so it is not a deadline in any sense that needs managing; it
/// exists so the width is stated rather than assumed.
uint256 constant LEAKY_BUCKET_TIMESTAMP_MAX = type(uint64).max;

/// @dev Largest level a packed checkpoint can hold, and therefore the largest
/// `capacity` that can be enforced through this codec. Around 6.2e57, which is
/// 6.2e39 whole tokens at eighteen decimals. Governance should reject a
/// capacity above this when it is set rather than discovering it at mint time.
uint256 constant LEAKY_BUCKET_LEVEL_MAX = type(uint192).max;

/// @dev Thrown when a level does not fit the packed field. Reaching this means
/// the capacity in force is above `LEAKY_BUCKET_LEVEL_MAX`, which is a
/// misconfiguration rather than a condition to handle at the call site.
/// @param level The level that did not fit.
error LeakyBucketLevelOverflow(uint256 level);

/// @dev Thrown when a timestamp does not fit the packed field.
/// @param timestamp The timestamp that did not fit.
error LeakyBucketTimestampOverflow(uint256 timestamp);

/// @title LibLeakyBucketCheckpoint
/// @notice `LibLeakyBucket` state packed into a single 256 bit word, so that a
/// concrete contract can keep a bucket in one storage slot and touch it with
/// one `SLOAD` and one `SSTORE` per fill.
///
/// The layout is the level in the high 192 bits and the timestamp in the low
/// 64. Both fields are read with a shift or a mask and no keccak, so the whole
/// hot path of a capped mint is: load one word, one multiply for the leak, one
/// compare against capacity, store one word.
///
/// ## Why this exists rather than two return values
///
/// `LibLeakyBucket.fillAt` returns a level that belongs to the timestamp it was
/// evaluated at. Storing that level while leaving the old checkpoint timestamp
/// in place credits the same leak again on the next call, and the cap quietly
/// stops binding. It is a one line mistake with no symptom until it is
/// exploited, which is the worst shape a bug in a mint cap can have. Here the
/// level and the timestamp are one word, `fill` returns that word, and the only
/// thing a caller can do with it is write it back whole. The failure mode is
/// removed rather than documented.
///
/// ## What is still the caller's
///
/// The slot. The key, if there is more than one bucket. Where `capacity` and
/// `leakRate` come from and who is allowed to change them. This library is
/// reached the same way from an immutable pair, a timelocked setter, a staged
/// upgrade, or a per minter mapping holding a different pair for every minter,
/// and it cannot tell which it is being used from.
///
/// ```solidity
/// // One bucket per minter, each with its own policy, governed however the
/// // concrete likes.
/// mapping(address minter => uint256 checkpoint) internal _buckets;
///
/// function mint(address to, uint256 amount) external {
///     _buckets[msg.sender] = LibLeakyBucketCheckpoint.fill(
///         _buckets[msg.sender], block.timestamp, capacity[msg.sender], leakRate[msg.sender], amount
///     );
///     _mint(to, amount);
/// }
/// ```
///
/// A zero word is a valid initial state and means an empty bucket checkpointed
/// at the epoch. No initializer is needed: an untouched slot is a bucket that
/// has been empty since before the chain existed, which is exactly what it
/// should be. Concretes that want the opposite, a bucket that starts full,
/// write `pack(capacity, block.timestamp)` once.
library LibLeakyBucketCheckpoint {
    /// Pack a level and a timestamp into one word. Reverts rather than
    /// truncating if either does not fit.
    ///
    /// Truncation is the specific failure this guards. A time field that wraps
    /// reads as a checkpoint far in the past, which is an enormous leak, which
    /// is a full bucket of headroom that was never earned. A cap that fails
    /// open at a fixed future date is worse than one that fails closed, so both
    /// fields revert.
    /// @param level The level to pack.
    /// @param timestamp The timestamp to pack, in seconds.
    /// @return The packed checkpoint.
    function pack(uint256 level, uint256 timestamp) internal pure returns (uint256) {
        if (level > LEAKY_BUCKET_LEVEL_MAX) {
            revert LeakyBucketLevelOverflow(level);
        }
        if (timestamp > LEAKY_BUCKET_TIMESTAMP_MAX) {
            revert LeakyBucketTimestampOverflow(timestamp);
        }
        unchecked {
            return (level << LEAKY_BUCKET_TIMESTAMP_BITS) | timestamp;
        }
    }

    /// Unpack a checkpoint into its level and timestamp. Total over every 256
    /// bit word, and the exact inverse of `pack` over every packable pair.
    /// @param checkpoint The packed checkpoint.
    /// @return level The level recorded at the checkpoint.
    /// @return timestamp The timestamp the level was recorded at, in seconds.
    function unpack(uint256 checkpoint) internal pure returns (uint256 level, uint256 timestamp) {
        unchecked {
            level = checkpoint >> LEAKY_BUCKET_TIMESTAMP_BITS;
            timestamp = checkpoint & LEAKY_BUCKET_TIMESTAMP_MAX;
        }
    }

    /// The level of a packed bucket as at `timestamp`.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The timestamp to evaluate the bucket at, in seconds.
    /// @param leakRate The leak in units per second.
    /// @return The level as at `timestamp`.
    function levelAt(uint256 checkpoint, uint256 timestamp, uint256 leakRate) internal pure returns (uint256) {
        (uint256 level, uint256 checkpointTimestamp) = unpack(checkpoint);
        return LibLeakyBucket.levelAt(level, checkpointTimestamp, timestamp, leakRate);
    }

    /// The largest amount `fill` would accept at `timestamp`.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The timestamp to evaluate the bucket at, in seconds.
    /// @param capacity The bucket capacity.
    /// @param leakRate The leak in units per second.
    /// @return The amount that would fit at `timestamp`.
    function headroomAt(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate)
        internal
        pure
        returns (uint256)
    {
        (uint256 level, uint256 checkpointTimestamp) = unpack(checkpoint);
        return LibLeakyBucket.headroomAt(level, checkpointTimestamp, timestamp, capacity, leakRate);
    }

    /// The earliest timestamp `amount` would fit at. See
    /// `LibLeakyBucket.fillableAt` for what the sentinel means.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The timestamp to evaluate the bucket at, in seconds.
    /// @param capacity The bucket capacity.
    /// @param leakRate The leak in units per second.
    /// @param amount The amount to wait for.
    /// @return The earliest timestamp `amount` fits at, or `type(uint256).max`.
    function fillableAt(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        (uint256 level, uint256 checkpointTimestamp) = unpack(checkpoint);
        return LibLeakyBucket.fillableAt(level, checkpointTimestamp, timestamp, capacity, leakRate, amount);
    }

    /// Fill a packed bucket with `amount` at `timestamp`, returning the new
    /// packed checkpoint to store. Reverts with `LeakyBucketCapacityExceeded`
    /// if the amount does not fit, and the caller stores nothing.
    ///
    /// The returned word carries the new level and `timestamp` together, so
    /// writing it back is the whole of the state update.
    /// @param checkpoint The packed checkpoint.
    /// @param timestamp The timestamp to fill at, in seconds.
    /// @param capacity The bucket capacity.
    /// @param leakRate The leak in units per second.
    /// @param amount The amount to fill.
    /// @return The new packed checkpoint.
    function fill(uint256 checkpoint, uint256 timestamp, uint256 capacity, uint256 leakRate, uint256 amount)
        internal
        pure
        returns (uint256)
    {
        (uint256 level, uint256 checkpointTimestamp) = unpack(checkpoint);
        return pack(LibLeakyBucket.fillAt(level, checkpointTimestamp, timestamp, capacity, leakRate, amount), timestamp);
    }
}
