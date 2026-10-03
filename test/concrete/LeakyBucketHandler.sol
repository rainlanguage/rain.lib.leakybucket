// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {LeakyBucketMintCap} from "./LeakyBucketMintCap.sol";
import {LeakyBucketCapacityExceeded} from "../../src/lib/LibLeakyBucket.sol";
import {LeakyBucketAsserts} from "../abstract/LeakyBucketAsserts.sol";
import {float} from "../lib/FloatWords.sol";

/// @title LeakyBucketHandler
/// @notice Call generator for `LeakyBucketInvariant.t.sol`: mints, waits and
/// policy changes in fuzzed order, recording what the cap should have done.
///
/// Every amount is a whole number held at exponent zero, and bounded well below
/// the coefficient's range. That is what keeps `assertEq(level, before + amount)`
/// an exact claim: two `Float`s at the same exponent add without alignment, so
/// no term is lost. Fuzzing across exponents would put this handler's bookkeeping
/// on the wrong side of a precision boundary and turn a real invariant into one
/// that fails for arithmetic reasons rather than bucket reasons.
contract LeakyBucketHandler is LeakyBucketAsserts {
    using LibDecimalFloat for Float;

    /// The largest amount the fuzzer may produce. Far below the `Float`
    /// coefficient's range, so sums stay exact at exponent zero.
    uint256 internal constant MAX_AMOUNT = type(uint128).max;

    /// The cap under test.
    LeakyBucketMintCap internal immutable CAP;

    /// The one minter whose bucket this handler drives.
    address internal immutable MINTER;

    /// The largest leak rate the fuzzer may set, and the longest `tick`. Both
    /// small against the starting capacity, so a history can hold a level that
    /// has not fully drained when the rate moves. Past a full drain a re-rated
    /// interval and a correctly rated one read the same.
    uint256 internal constant LEAK_RATE_CEILING = 10;
    uint256 internal constant TICK_CEILING = 3600;

    /// The leak rate currently in force.
    uint256 public leakRate;

    /// The most the bucket can have leaked so far: every wait, priced at the
    /// rate in force while it passed.
    uint256 public leaked;

    /// The level the bucket should hold now, kept in words: each mint added,
    /// each wait leaked at the rate in force while it passed, floored at zero.
    /// A rate change that re-rated time already spent parts the cap from this.
    uint256 public expectedLevel;

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
    constructor(LeakyBucketMintCap cap, address minter, uint256 initialCapacity, uint256 initialLeakRate) {
        CAP = cap;
        MINTER = minter;
        leakRate = initialLeakRate;
        capacity = initialCapacity;
    }

    /// A mint of an arbitrary size, at whatever point in the history the fuzzer
    /// has built up to.
    function mint(uint256 amount) external {
        amount = bound(amount, 1, capacity > 0 ? capacity : 1);
        Float amountFloat = float(amount);
        Float headroomBefore = CAP.headroom(MINTER);
        Float levelBefore = CAP.level(MINTER);

        vm.prank(MINTER);
        try CAP.mint(amountFloat) {
            // It landed, so it must have fitted, and it must have moved the
            // level by exactly what was minted.
            assertTrue(amountFloat.lte(headroomBefore));
            minted += amount;
            expectedLevel += amount;
            assertTrue(CAP.level(MINTER).eq(levelBefore.add(amountFloat)));
        } catch (bytes memory reason) {
            // It was refused, so it must not have fitted, it must have been
            // refused for that reason and no other, and the bucket must be
            // exactly what it was.
            //
            // The three fields are decoded and compared as numbers rather than
            // the whole reason compared as bytes. One number has more than one
            // `Float` word — `sub` returns a maximized-then-truncated
            // coefficient where `packLossless` returns the plain one — so byte
            // equality would assert on which representation the arithmetic
            // happened to take rather than on the value it reports.
            assertTrue(amountFloat.gt(headroomBefore));
            // Truncating to the first four bytes is what reads the selector.
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes4 selector = bytes4(reason);
            assertEq(selector, LeakyBucketCapacityExceeded.selector);
            (Float reportedCapacity, Float reportedLevel, Float reportedAmount) =
                abi.decode(sliceReason(reason), (Float, Float, Float));
            assertTrue(reportedCapacity.eq(float(capacity)));
            assertTrue(reportedLevel.eq(levelBefore));
            assertTrue(reportedAmount.eq(amountFloat));
            assertTrue(CAP.level(MINTER).eq(levelBefore));
        }
    }

    /// Time passing between calls, which is the only thing that refills the
    /// bucket.
    function wait(uint32 gap) external {
        pass(gap);
    }

    /// A wait short enough to leave part of a level standing.
    function tick(uint256 gap) external {
        pass(bound(gap, 0, TICK_CEILING));
    }

    function pass(uint256 gap) internal {
        uint256 leak = gap * leakRate;
        leaked += leak;
        expectedLevel = leak >= expectedLevel ? 0 : expectedLevel - leak;
        vm.warp(block.timestamp + gap);
    }

    /// Governance moving the burst around underneath an in-flight history,
    /// which is the case a fixed loop with a constant policy cannot reach at
    /// all.
    function setCapacity(uint256 newCapacity) external {
        capacity = bound(newCapacity, 0, capacity);
        CAP.setCapacity(MINTER, float(capacity));
    }

    /// Governance moving the sustained rate in either direction, zero
    /// included, underneath an in-flight history.
    function setLeakRate(uint256 newLeakRate) external {
        leakRate = bound(newLeakRate, 0, LEAK_RATE_CEILING);
        CAP.setPolicy(MINTER, float(capacity), float(leakRate));
    }
}
