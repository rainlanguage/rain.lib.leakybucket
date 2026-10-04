// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {LeakyBucketMintCap} from "../../concrete/LeakyBucketMintCap.sol";
import {LeakyBucketHandler} from "../../concrete/LeakyBucketHandler.sol";

/// The one stateful invariant run in the suite.
contract LeakyBucketInvariantTest is Test {
    using LibDecimalFloat for Float;

    /// The worked policy, as whole numbers. The handler fuzzes amounts as whole
    /// numbers at exponent zero, so the capacity and the leak rate are written
    /// the same way and every sum below stays exact.
    uint256 internal constant CAPACITY = 3600;
    uint256 internal constant LEAK_RATE = 1;

    address internal constant ALICE = address(uint160(uint256(keccak256("alice"))));

    LeakyBucketMintCap internal cap;
    LeakyBucketHandler internal handler;

    function asFloat(uint256 value) internal pure returns (Float) {
        //forge-lint: disable-next-line(unsafe-typecast)
        return LibDecimalFloat.packLossless(int256(value), 0);
    }

    function setUp() external {
        vm.warp(1_700_000_000);
        cap = new LeakyBucketMintCap();
        cap.setPolicy(ALICE, asFloat(CAPACITY), asFloat(LEAK_RATE));
        handler = new LeakyBucketHandler(cap, ALICE, CAPACITY, LEAK_RATE);

        // The selectors are named rather than left to the default, which
        // would be every external function on the target INCLUDING the ones
        // `Test` brings in by inheritance. Under `fail-on-revert = true` a
        // fuzzer call into one of those that reverted would fail the run for a
        // reason that has nothing to do with the bucket.
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LeakyBucketHandler.mint.selector;
        selectors[1] = LeakyBucketHandler.wait.selector;
        selectors[2] = LeakyBucketHandler.setCapacity.selector;
        selectors[3] = LeakyBucketHandler.setLeakRate.selector;
        selectors[4] = LeakyBucketHandler.tick.selector;
        selectors[5] = LeakyBucketHandler.stepBack.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// No instant of any history offers more than the burst in force, and the
    /// burst in force is never more than the one the run started with.
    function invariant_headroomNeverExceedsCapacity() external view {
        assertTrue(cap.headroom(ALICE).lte(asFloat(handler.capacity())));
        assertTrue(cap.headroom(ALICE).lte(asFloat(CAPACITY)));
    }

    /// The level is what was minted less what each rate leaked over the time
    /// it was in force, at every step of every history. A rate change that
    /// reached back over time already spent would break this at the write.
    function invariant_levelLeaksAtTheRateInForce() external view {
        assertTrue(cap.level(ALICE).eq(asFloat(handler.expectedLevel())));
    }

    /// Cumulative throughput is bounded by one burst plus what each rate leaked
    /// over the time it was in force, however the calls are interleaved and
    /// however the rate moves.
    function invariant_throughputIsBoundedByBurstPlusLeak() external view {
        assertTrue(asFloat(handler.minted()).eq(cap.totalMinted()));
        assertLe(handler.minted(), CAPACITY + handler.leaked());
    }

    function assertInvariants() internal view {
        this.invariant_headroomNeverExceedsCapacity();
        this.invariant_levelLeaksAtTheRateInForce();
        this.invariant_throughputIsBoundedByBurstPlusLeak();
    }

    /// The invariants across a mint, a rate change and a capacity cut that each
    /// land behind the checkpoint. The fuzzer reaches these through `stepBack`
    /// only when it happens to pick it.
    function testInvariantsHoldBehindTheCheckpoint() external {
        handler.mint(1000);
        handler.tick(100);
        handler.mint(500);
        assertTrue(cap.level(ALICE).eq(asFloat(1400)));

        handler.stepBack(50);
        assertInvariants();
        handler.mint(200);
        assertInvariants();
        handler.setLeakRate(5);
        assertInvariants();
        handler.setCapacity(2000);
        assertInvariants();
        assertTrue(cap.level(ALICE).eq(asFloat(1600)));

        // 150 seconds past the checkpoint the writes left standing, at 5.
        handler.tick(200);
        assertInvariants();
        assertTrue(cap.level(ALICE).eq(asFloat(850)));
    }
}
