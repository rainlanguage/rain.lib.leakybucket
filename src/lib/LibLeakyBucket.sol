// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {LibSaturatingMath} from "rain-math-saturating-0.1.10/src/lib/LibSaturatingMath.sol";

/// A fill of `amount` does not fit: `level + amount > capacity`.
error LeakyBucketCapacityExceeded(uint256 capacity, uint256 level, uint256 amount);

/// `capacity` is above `LEAKY_BUCKET_LEVEL_MAX`.
error LeakyBucketCapacityOverflow(uint256 capacity);

/// `timestamp` does not fit the 64 bit timestamp field.
error LeakyBucketTimestampOverflow(uint256 timestamp);

/// `level` does not fit the 192 bit level field.
error LeakyBucketLevelOverflow(uint256 level);

/// A bucket. The caller stores it; the library never writes it.
/// @param checkpoint Packed `(level << 64) | timestamp`. Zero is empty.
/// @param capacity Burst. At most `LEAKY_BUCKET_LEVEL_MAX`.
/// @param leakRate Units leaked per second.
struct LeakyBucket {
    uint256 checkpoint;
    uint256 capacity;
    uint256 leakRate;
}

/// @title LibLeakyBucket
/// @notice Pure leaky bucket over a `LeakyBucket` the caller holds. Timestamps
/// are seconds. Arithmetic saturates: a leak never underflows the level and a
/// backwards clock credits no leak.
library LibLeakyBucket {
    uint256 private constant LEAKY_BUCKET_TIMESTAMP_BITS = 64;
    uint256 private constant LEAKY_BUCKET_TIMESTAMP_MAX = (uint256(1) << LEAKY_BUCKET_TIMESTAMP_BITS) - 1;

    /// Largest level a checkpoint holds, and so the largest usable capacity.
    uint256 internal constant LEAKY_BUCKET_LEVEL_MAX = type(uint256).max >> LEAKY_BUCKET_TIMESTAMP_BITS;

    /// `level` after `elapsed` seconds of leak, saturating at zero.
    function leak(uint256 level, uint256 elapsed, uint256 leakRate) private pure returns (uint256) {
        return LibSaturatingMath.saturatingSub(level, LibSaturatingMath.saturatingMul(elapsed, leakRate));
    }

    /// The level recorded at `checkpoint` leaked forward to `timestamp`.
    function levelAt(uint256 level, uint256 checkpoint, uint256 timestamp, uint256 leakRate)
        private
        pure
        returns (uint256)
    {
        return leak(level, LibSaturatingMath.saturatingSub(timestamp, checkpoint), leakRate);
    }

    /// `capacity - levelNow`, saturating at zero.
    function headroomFrom(uint256 capacity, uint256 levelNow) private pure returns (uint256) {
        return LibSaturatingMath.saturatingSub(capacity, levelNow);
    }

    /// The level after filling `amount` at `timestamp`. Reverts with
    /// `LeakyBucketCapacityExceeded` if `amount` is over the headroom.
    function fillAt(
        uint256 level,
        uint256 checkpoint,
        uint256 timestamp,
        uint256 capacity,
        uint256 leakRate,
        uint256 amount
    ) private pure returns (uint256) {
        uint256 levelNow = levelAt(level, checkpoint, timestamp, leakRate);
        uint256 headroom = headroomFrom(capacity, levelNow);
        if (amount > headroom) {
            revert LeakyBucketCapacityExceeded(capacity, levelNow, amount);
        }
        unchecked {
            // `amount <= headroom <= capacity - levelNow`.
            return levelNow + amount;
        }
    }

    function checkCapacity(uint256 capacity) private pure {
        if (capacity > LEAKY_BUCKET_LEVEL_MAX) {
            revert LeakyBucketCapacityOverflow(capacity);
        }
    }

    function checkTimestamp(uint256 timestamp) private pure {
        if (timestamp > LEAKY_BUCKET_TIMESTAMP_MAX) {
            revert LeakyBucketTimestampOverflow(timestamp);
        }
    }

    /// Reverts unless both `fill` and `headroomAt` accept the pair, so a read
    /// never answers where a fill would refuse.
    function checkFillableDomain(uint256 capacity, uint256 timestamp) private pure {
        checkCapacity(capacity);
        checkTimestamp(timestamp);
    }

    function pack(uint256 level, uint256 timestamp) private pure returns (uint256) {
        if (level > LEAKY_BUCKET_LEVEL_MAX) {
            revert LeakyBucketLevelOverflow(level);
        }
        checkTimestamp(timestamp);
        unchecked {
            return (level << LEAKY_BUCKET_TIMESTAMP_BITS) | timestamp;
        }
    }

    function max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    function unpack(uint256 checkpoint) private pure returns (uint256 level, uint256 timestamp) {
        unchecked {
            level = checkpoint >> LEAKY_BUCKET_TIMESTAMP_BITS;
            timestamp = checkpoint & LEAKY_BUCKET_TIMESTAMP_MAX;
        }
    }

    /// The amount `fill` would accept at `timestamp`. Reverts on the same
    /// capacity and timestamp `fill` refuses.
    /// @param bucket The bucket. Not modified.
    /// @param timestamp Seconds.
    /// @return Headroom at `timestamp`.
    function headroomAt(LeakyBucket memory bucket, uint256 timestamp) internal pure returns (uint256) {
        checkFillableDomain(bucket.capacity, timestamp);
        (uint256 level, uint256 checkpointTimestamp) = unpack(bucket.checkpoint);
        return headroomFrom(bucket.capacity, levelAt(level, checkpointTimestamp, timestamp, bucket.leakRate));
    }

    /// Fill `amount` at `timestamp`. The returned checkpoint carries the later
    /// of `timestamp` and the stored timestamp, so a backwards clock never
    /// re-credits leak.
    /// @param bucket The bucket. Not modified.
    /// @param timestamp Seconds.
    /// @param amount The amount to fill.
    /// @return The new checkpoint, to store as `bucket.checkpoint`.
    function fill(LeakyBucket memory bucket, uint256 timestamp, uint256 amount) internal pure returns (uint256) {
        checkFillableDomain(bucket.capacity, timestamp);
        (uint256 level, uint256 checkpointTimestamp) = unpack(bucket.checkpoint);
        return pack(
            fillAt(level, checkpointTimestamp, timestamp, bucket.capacity, bucket.leakRate, amount),
            max(timestamp, checkpointTimestamp)
        );
    }
}
