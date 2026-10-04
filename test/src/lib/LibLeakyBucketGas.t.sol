// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, console2} from "forge-std-1.16.2/src/Test.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {GasBucket} from "../../concrete/GasBucket.sol";
import {LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {workedCapacity, workedLeakRate, workedDrain} from "../../lib/WorkedPolicy.sol";

/// Each band asserted here is a `gasleft()` delta in the regime the test name
/// gives.
///
/// The bands are higher than the fixed point ones they replace, and measured
/// rather than carried across: a `Float` operation is a library call over a
/// packed coefficient and exponent rather than an opcode, and a bucket now
/// writes two slots where it wrote one. A steady state fill went from the
/// 9,000-16,000 band to 30,048.
contract LibLeakyBucketGasTest is Test {
    using LibDecimalFloat for Float;

    /// Primed, so its level slot is non zero and cold.
    GasBucket internal sPrimed;

    /// Never filled, so its level slot is zero and cold, with the policy slots
    /// beside it set and cold.
    GasBucket internal sFresh;

    /// `sPrimed`'s level slot as `setUp` left it, for the rejected fill below to
    /// compare against.
    bytes32 internal sPrimedSlotAtSetUp;

    function setUp() external {
        sPrimed = new GasBucket(workedCapacity(), workedLeakRate());
        sFresh = new GasBucket(workedCapacity(), workedLeakRate());
        vm.warp(1_700_000_000);
        // Prime it so the measured fills hit a non zero slot, then move the
        // clock on by a sixth of a drain time, which is far more leak than the
        // unit primed above, so every measured fill below starts from an empty
        // bucket with a real leak to apply.
        sPrimed.fill(LibDecimalFloat.packLossless(1, 0));
        vm.warp(block.timestamp + workedDrain() / 6);
        sPrimedSlotAtSetUp = vm.load(address(sPrimed), bytes32(uint256(0)));
    }

    function measure(address target, Float amount) internal returns (uint256) {
        bytes memory call = abi.encodeWithSignature("fill(bytes32)", amount);
        uint256 before = gasleft();
        (bool ok,) = target.call(call);
        uint256 used = before - gasleft();
        require(ok, "fill reverted");
        return used;
    }

    /// The first fill a brand new minter ever makes, against a zero level slot.
    function testGasFirstFillIntoEmptySlot() external {
        uint256 gas = measure(address(sFresh), LibDecimalFloat.packLossless(1, 0));
        console2.log("first fill (zero slot)", gas);
        assertGt(gas, 58_000);
        assertLt(gas, 66_000);
    }

    /// The steady state, and the number that matters: a minter that has minted
    /// before, in a later transaction.
    function testGasSteadyStateFill() external {
        uint256 gas = measure(address(sPrimed), LibDecimalFloat.packLossless(1, 0));
        console2.log("steady state fill", gas);
        assertGt(gas, 27_000);
        assertLt(gas, 34_000);
    }

    /// A rejected fill costs the reads and the revert, and writes nothing.
    function testGasRejectedFill() external {
        Float huge = LibDecimalFloat.packLossless(1, 30);
        bytes memory call = abi.encodeWithSignature("fill(bytes32)", huge);
        uint256 before = gasleft();
        (bool ok, bytes memory reason) = address(sPrimed).call(call);
        uint256 gas = before - gasleft();

        // Which revert, not just "reverted". `setUp` primed the bucket with one
        // unit and moved the clock on `workedDrain() / 6` = 600, and 600 of leak
        // against 1 of level leaves it empty, so the level the error reports is
        // zero. Copying the reason does land inside the measured window; it
        // moves the measurement by a few tens of gas, which is nothing against
        // the band.
        // Field by field as numbers, not the whole reason as bytes. One number
        // has more than one `Float` word, so byte equality asserts on which
        // representation the arithmetic reached rather than on the value.
        assertTrue(!ok);
        // Truncating to the first four bytes is what reads the selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = bytes4(reason);
        assertEq(selector, LeakyBucketCapacityExceeded.selector);
        bytes memory args = new bytes(reason.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = reason[i + 4];
        }
        (Float capacity, Float level, Float amount) = abi.decode(args, (Float, Float, Float));
        assertTrue(capacity.eq(workedCapacity()));
        assertTrue(level.eq(LibDecimalFloat.packLossless(0, 0)));
        assertTrue(amount.eq(huge));

        // The other half of the claim. The band is only indirect evidence for
        // it: a figure under the steady state band rules out a fresh `SSTORE`
        // but not a warm rewrite of the same slot at 100 gas, so a codec that
        // wrote before reverting, or a concrete that swallowed the revert after
        // storing, would sit inside the band. The level is the first field of
        // `GasBucket`'s only state variable, so it is slot 0.
        assertEq(vm.load(address(sPrimed), bytes32(uint256(0))), sPrimedSlotAtSetUp);

        console2.log("rejected fill", gas);
        assertGt(gas, 25_000);
        assertLt(gas, 32_000);
    }
}
