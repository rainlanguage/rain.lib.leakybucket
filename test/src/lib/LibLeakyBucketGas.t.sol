// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, console2} from "forge-std-1.16.2/src/Test.sol";
import {PackedBucket} from "../../lib/PackedBucket.sol";
import {UnpackedBucket} from "../../lib/UnpackedBucket.sol";

/// Each band asserted here is a `gasleft()` delta in the regime the test name
/// gives. A compiler or EVM change that moves a measurement out of its band
/// fails here, and the documented band is corrected with it.
///
/// Every measurement is the *first* touch of the subject's storage within its
/// test, because `forge` keeps slots warm for the whole of a test body and a
/// second measurement in the same body would price warm slots at 100 gas and
/// report a saving an order of magnitude too small. Priming happens in
/// `setUp`, which is a separate call, so the slots are non zero and cold when
/// the measurement starts, exactly as they are for a mint in a fresh
/// transaction.
contract LibLeakyBucketGasTest is Test {
    uint256 internal constant CAPACITY = 3600e18;
    uint256 internal constant LEAK_RATE = 1e18;

    PackedBucket internal packed;
    UnpackedBucket internal unpacked;

    function setUp() external {
        packed = new PackedBucket();
        unpacked = new UnpackedBucket();
        vm.warp(1_700_000_000);
        // Prime both so the measured fills hit non zero slots, then move the
        // clock on so there is a real leak to apply.
        packed.fill(CAPACITY, LEAK_RATE, 1e18);
        unpacked.fill(CAPACITY, LEAK_RATE, 1e18);
        vm.warp(block.timestamp + 600);
    }

    function measure(address target, uint256 amount) internal returns (uint256) {
        bytes memory call = abi.encodeWithSignature("fill(uint256,uint256,uint256)", CAPACITY, LEAK_RATE, amount);
        uint256 before = gasleft();
        (bool ok,) = target.call(call);
        uint256 used = before - gasleft();
        require(ok, "fill reverted");
        return used;
    }

    /// The first fill a brand new minter ever makes, against a zero slot. This
    /// is the one time the 20k zero to non zero `SSTORE` is paid.
    function testGasFirstFillIntoEmptySlot() external {
        PackedBucket fresh = new PackedBucket();
        uint256 gas = measure(address(fresh), 1e18);
        console2.log("packed first fill (zero slot)", gas);
        assertGt(gas, 20_000);
        assertLt(gas, 30_000);
    }

    /// The steady state, and the number that matters: a minter that has minted
    /// before, in a later transaction.
    function testGasSteadyStateFill() external {
        uint256 gas = measure(address(packed), 1e18);
        console2.log("packed steady state fill", gas);
        assertGt(gas, 5_000);
        assertLt(gas, 12_000);
    }

    /// One slot against two, on the extra `SLOAD`.
    ///
    /// This measures one half of what the codec saves. `forge` carries the
    /// dirty slot journal across from `setUp`, so a slot written there is
    /// already dirty here and its `SSTORE` prices at 100 gas rather than 2900
    /// however cold the access list is made. `vm.cool` resets the access list
    /// and not the journal, so it does not recover the other half either. What
    /// is left visible, and asserted, is the extra cold `SLOAD` the two slot
    /// layout pays. The `SSTORE` half is measured separately below, where the
    /// slots are genuinely untouched.
    function testGasPackedBeatsUnpackedOnTheExtraLoad() external {
        uint256 packedGas = measure(address(packed), 1e18);
        uint256 unpackedGas = measure(address(unpacked), 1e18);
        console2.log("packed steady state", packedGas);
        console2.log("unpacked steady state", unpackedGas);
        console2.log("saving (load only)", unpackedGas - packedGas);

        assertGt(unpackedGas, packedGas);
        // One extra cold `SLOAD`, which is 2100 gas, less the two guards the
        // codec runs and the two slot harness does not: the bound on a capacity
        // the packed level field cannot hold, and the comparison that keeps the
        // stored checkpoint from going backwards. Together they are worth ~78
        // gas, and `UnpackedBucket` buys neither, because a level kept in a
        // whole word has no packed width to exceed.
        assertGt(unpackedGas - packedGas, 1_800);
        assertLt(unpackedGas - packedGas, 2_100);
    }

    /// One slot against two, on the extra `SSTORE`.
    ///
    /// Both subjects are freshly deployed, so every slot is zero and untouched
    /// by this transaction and the full `SSTORE` price is charged. The two slot
    /// layout pays it twice. This is the cost a real steady state mint also
    /// carries, at the lower non zero rate, on top of the extra load above.
    function testGasPackedBeatsUnpackedOnTheExtraStore() external {
        uint256 packedGas = measure(address(new PackedBucket()), 1e18);
        uint256 unpackedGas = measure(address(new UnpackedBucket()), 1e18);
        console2.log("packed first fill", packedGas);
        console2.log("unpacked first fill", unpackedGas);
        console2.log("saving (store included)", unpackedGas - packedGas);

        assertGt(unpackedGas, packedGas);
        // A second zero to non zero `SSTORE` is 22100 gas all in.
        assertGt(unpackedGas - packedGas, 20_000);
    }

    /// A rejected fill costs the read and the revert, and writes nothing.
    function testGasRejectedFill() external {
        bytes memory call =
            abi.encodeWithSignature("fill(uint256,uint256,uint256)", CAPACITY, LEAK_RATE, type(uint256).max);
        uint256 before = gasleft();
        (bool ok,) = address(packed).call(call);
        uint256 gas = before - gasleft();
        assertTrue(!ok);
        console2.log("packed rejected fill", gas);
        assertGt(gas, 6_000);
        assertLt(gas, 10_000);
    }
}
