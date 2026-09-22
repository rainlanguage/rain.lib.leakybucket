// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, console2} from "forge-std-1.16.2/src/Test.sol";
import {PackedBucket} from "../../concrete/PackedBucket.sol";
import {LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {WORKED_CAPACITY, WORKED_LEAK_RATE, WORKED_DRAIN} from "../../lib/WorkedPolicy.sol";

/// Each band asserted here is a `gasleft()` delta in the regime the test name
/// gives.
contract LibLeakyBucketGasTest is Test {
    /// The worked policy the suite examines, from `test/lib/WorkedPolicy.sol`.
    uint256 internal constant CAPACITY = WORKED_CAPACITY;
    uint256 internal constant LEAK_RATE = WORKED_LEAK_RATE;
    uint256 internal constant DRAIN = WORKED_DRAIN;

    /// Primed, so its checkpoint slot is non zero and cold.
    PackedBucket internal sPacked;

    /// Never filled, so its checkpoint slot is zero and cold, with the policy
    /// slots beside it set and cold.
    PackedBucket internal sFresh;

    /// `sPacked`'s checkpoint slot as `setUp` left it, for the rejected fill
    /// below to compare against.
    bytes32 internal sPackedSlotAtSetUp;

    function setUp() external {
        sPacked = new PackedBucket(CAPACITY, LEAK_RATE);
        sFresh = new PackedBucket(CAPACITY, LEAK_RATE);
        vm.warp(1_700_000_000);
        // Prime it so the measured fills hit a non zero slot, then move the
        // clock on by a sixth of a drain time, which is far more leak than the
        // unit primed above, so every measured fill below starts from an empty
        // bucket with a real leak to apply.
        sPacked.fill(1e18);
        vm.warp(block.timestamp + DRAIN / 6);
        sPackedSlotAtSetUp = vm.load(address(sPacked), bytes32(uint256(0)));
    }

    function measure(address target, uint256 amount) internal returns (uint256) {
        bytes memory call = abi.encodeWithSignature("fill(uint256)", amount);
        uint256 before = gasleft();
        (bool ok,) = target.call(call);
        uint256 used = before - gasleft();
        require(ok, "fill reverted");
        return used;
    }

    /// The first fill a brand new minter ever makes, against a zero checkpoint
    /// slot.
    function testGasFirstFillIntoEmptySlot() external {
        uint256 gas = measure(address(sFresh), 1e18);
        console2.log("packed first fill (zero slot)", gas);
        assertGt(gas, 24_000);
        assertLt(gas, 34_000);
    }

    /// The steady state, and the number that matters: a minter that has minted
    /// before, in a later transaction.
    function testGasSteadyStateFill() external {
        uint256 gas = measure(address(sPacked), 1e18);
        console2.log("packed steady state fill", gas);
        assertGt(gas, 9_000);
        assertLt(gas, 16_000);
    }

    /// A rejected fill costs the reads and the revert, and writes nothing.
    function testGasRejectedFill() external {
        bytes memory call = abi.encodeWithSignature("fill(uint256)", type(uint256).max);
        uint256 before = gasleft();
        (bool ok, bytes memory reason) = address(sPacked).call(call);
        uint256 gas = before - gasleft();

        // Which revert, not just "reverted". `setUp` primed the bucket with
        // 1e18 and moved the clock on `DRAIN / 6` = 600 seconds, and 600e18 of
        // leak against 1e18 of level leaves it empty, so the level the error
        // reports is zero. Copying the reason does land inside the measured
        // window; it moves the measurement by a few tens of gas, which is
        // nothing against a band 4,000 wide.
        assertTrue(!ok);
        assertEq(reason, abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, CAPACITY, 0, type(uint256).max));

        // The other half of the claim. The band is only indirect evidence for
        // it: a figure under the steady state band rules out a fresh `SSTORE`
        // but not a warm rewrite of the same slot at 100 gas, so a codec that
        // wrote before reverting, or a concrete that swallowed the revert
        // after storing, would sit inside the band. The checkpoint is the
        // first field of `PackedBucket`'s only state variable, so it is slot
        // 0.
        assertEq(vm.load(address(sPacked), bytes32(uint256(0))), sPackedSlotAtSetUp);

        console2.log("packed rejected fill", gas);
        assertGt(gas, 10_000);
        assertLt(gas, 14_000);
    }
}
