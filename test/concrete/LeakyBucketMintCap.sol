// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {LibLeakyBucket, LeakyBucket} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketMintCap
/// @notice Test harness: one bucket per minter, a mint, and a governance setter.
contract LeakyBucketMintCap {
    using LibDecimalFloat for Float;

    /// One bucket per minter.
    mapping(address minter => LeakyBucket bucket) internal sBuckets;

    /// Total minted, standing in for an ERC20 balance.
    Float public totalMinted;

    /// Where governance goes.
    ///
    /// Settled before the write, so the old rate is charged for the time it was
    /// in force and the new one starts from now.
    function setPolicy(address minter, Float capacity, Float leakRate) external {
        LibLeakyBucket.checkPolicy(capacity, leakRate);
        LeakyBucket storage bucket = sBuckets[minter];
        (Float newLevel, Float checkpoint) = LibLeakyBucket.settle(bucket, now_());
        bucket.level = newLevel;
        bucket.timestamp = checkpoint;
        bucket.capacity = capacity;
        bucket.leakRate = leakRate;
    }

    /// The whole enforcement path: load the minter's bucket, hand it to `fill`,
    /// store the level and checkpoint it returns.
    function mint(Float amount) external {
        (Float newLevel, Float checkpoint) = LibLeakyBucket.fill(sBuckets[msg.sender], now_(), amount);
        sBuckets[msg.sender].level = newLevel;
        sBuckets[msg.sender].timestamp = checkpoint;
        totalMinted = totalMinted.add(amount);
    }

    /// What a minter could mint right now.
    function headroom(address minter) external view returns (Float) {
        return LibLeakyBucket.headroomAt(sBuckets[minter], now_());
    }

    /// The outstanding level against a minter's cap right now.
    ///
    /// `levelAt`, not `capacity - headroomAt`. The headroom saturates at zero, so
    /// after governance lowers a capacity under an outstanding level that
    /// subtraction returns the new capacity and under-reports what is owed —
    /// which is exactly the state a capacity cut leaves behind.
    function level(address minter) external view returns (Float) {
        return LibLeakyBucket.levelAt(sBuckets[minter], now_());
    }

    /// `block.timestamp` as a `Float`.
    function now_() internal view returns (Float) {
        //forge-lint: disable-next-line(unsafe-typecast)
        return LibDecimalFloat.packLossless(int256(block.timestamp), 0);
    }
}
