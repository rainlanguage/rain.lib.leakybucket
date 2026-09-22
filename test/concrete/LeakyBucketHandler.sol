// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {LeakyBucketMintCap} from "./LeakyBucketMintCap.sol";
import {LeakyBucketCapacityExceeded} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketHandler
/// @notice Call generator for `LeakyBucketInvariant.t.sol`: mints, waits and
/// policy changes in fuzzed order, recording what the cap should have done.
contract LeakyBucketHandler is Test {
    /// The cap under test.
    LeakyBucketMintCap internal immutable CAP;

    /// The one minter whose bucket this handler drives.
    address internal immutable MINTER;

    /// Held fixed for the whole run, so the throughput bound the invariant
    /// asserts stays exact.
    uint256 internal immutable LEAK_RATE;

    /// The timestamp the run started at, for the elapsed window in the
    /// throughput bound.
    uint256 public immutable START;

    /// The capacity currently in force, mirrored so the invariant can read the
    /// policy without a second source of truth.
    uint256 public capacity;

    /// What this handler believes the minter has minted, accumulated from the
    /// calls it made rather than read back from the cap.
    uint256 public minted;

    // `minter` is the address whose bucket this handler drives, supplied by the
    // test that constructs it. There is nothing to protect against here: the
    // zero address is a perfectly good key for a bucket, the handler is a test
    // harness with no funds and no authority, and a zero check would refuse an
    // input the library itself accepts.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(LeakyBucketMintCap cap, address minter, uint256 capacity_, uint256 leakRate) {
        CAP = cap;
        MINTER = minter;
        LEAK_RATE = leakRate;
        capacity = capacity_;
        START = block.timestamp;
    }

    /// A mint of an arbitrary size, at whatever point in the history the fuzzer
    /// has built up to.
    function mint(uint256 amount) external {
        amount = bound(amount, 0, capacity);
        uint256 headroomBefore = CAP.headroom(MINTER);
        uint256 levelBefore = CAP.level(MINTER);

        vm.prank(MINTER);
        try CAP.mint(amount) {
            // It landed, so it must have fitted, and it must have moved the
            // level by exactly what was minted.
            assertLe(amount, headroomBefore);
            minted += amount;
            assertEq(CAP.level(MINTER), levelBefore + amount);
        } catch (bytes memory reason) {
            // It was refused, so it must not have fitted, it must have been
            // refused for that reason and no other, and the bucket must be
            // exactly what it was.
            assertGt(amount, headroomBefore);
            assertEq(
                reason, abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, capacity, levelBefore, amount)
            );
            assertEq(CAP.level(MINTER), levelBefore);
        }
    }

    /// Time passing between calls, which is the only thing that refills the
    /// bucket.
    function wait(uint32 gap) external {
        vm.warp(block.timestamp + gap);
    }

    /// Governance moving the burst around underneath an in-flight history,
    /// which is the case a fixed loop with a constant policy cannot reach at
    /// all.
    function setCapacity(uint256 capacity_) external {
        capacity = bound(capacity_, 0, capacity);
        CAP.setPolicy(MINTER, capacity, LEAK_RATE);
    }
}
