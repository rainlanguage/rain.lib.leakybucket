// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {LibLeakyBucket, LeakyBucket, LeakyBucketCapacityOverflow} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketMintCap
/// @notice Test harness: one bucket per minter, a mint, and a governance setter.
contract LeakyBucketMintCap {
    /// One bucket per minter.
    mapping(address minter => LeakyBucket bucket) internal sBuckets;

    /// Total minted, standing in for an ERC20 balance.
    uint256 public totalMinted;

    /// Where governance goes.
    function setPolicy(address minter, uint256 capacity, uint256 leakRate) external {
        if (capacity > LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX) {
            revert LeakyBucketCapacityOverflow(capacity);
        }
        LeakyBucket storage bucket = sBuckets[minter];
        bucket.capacity = capacity;
        bucket.leakRate = leakRate;
    }

    /// The whole enforcement path: load the minter's bucket, hand it to `fill`,
    /// store the checkpoint it returns.
    function mint(uint256 amount) external {
        sBuckets[msg.sender].checkpoint = LibLeakyBucket.fill(sBuckets[msg.sender], block.timestamp, amount);
        totalMinted += amount;
    }

    /// What a minter could mint right now.
    function headroom(address minter) external view returns (uint256) {
        return LibLeakyBucket.headroomAt(sBuckets[minter], block.timestamp);
    }

    /// The outstanding level against a minter's cap right now.
    function level(address minter) external view returns (uint256) {
        LeakyBucket memory bucket = sBuckets[minter];
        bucket.capacity = LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX;
        return LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX - LibLeakyBucket.headroomAt(bucket, block.timestamp);
    }
}
