// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, console2} from "forge-std-1.16.2/src/Test.sol";
import {PackedBucket} from "../../concrete/PackedBucket.sol";
import {UnpackedBucket} from "../../concrete/UnpackedBucket.sol";
import {LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {WORKED_CAPACITY, WORKED_LEAK_RATE, WORKED_DRAIN} from "../../lib/WorkedPolicy.sol";

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
    /// The worked policy the suite examines, from `test/lib/WorkedPolicy.sol`.
    uint256 internal constant CAPACITY = WORKED_CAPACITY;
    uint256 internal constant LEAK_RATE = WORKED_LEAK_RATE;
    uint256 internal constant DRAIN = WORKED_DRAIN;

    PackedBucket internal sPacked;
    UnpackedBucket internal sUnpacked;

    /// `PackedBucket`'s only slot as `setUp` left it, for the rejected fill
    /// below to compare against. Taken here and not in the test body because
    /// reading the slot immediately before the measured call warms both the
    /// account and the slot and measures a different regime entirely: 8,188
    /// gas becomes 1,688. `setUp` is a separate call, the access list resets
    /// between it and a test body, and the measurement is 8,188 either way.
    bytes32 internal sPackedSlotAtSetUp;

    function setUp() external {
        sPacked = new PackedBucket();
        sUnpacked = new UnpackedBucket();
        vm.warp(1_700_000_000);
        // Prime both so the measured fills hit non zero slots, then move the
        // clock on by a sixth of a drain time, which is far more leak than the
        // unit primed above, so every measured fill below starts from an empty
        // bucket with a real leak to apply.
        sPacked.fill(CAPACITY, LEAK_RATE, 1e18);
        sUnpacked.fill(CAPACITY, LEAK_RATE, 1e18);
        vm.warp(block.timestamp + DRAIN / 6);
        sPackedSlotAtSetUp = vm.load(address(sPacked), bytes32(uint256(0)));
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
        uint256 gas = measure(address(sPacked), 1e18);
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
        uint256 packedGas = measure(address(sPacked), 1e18);
        uint256 unpackedGas = measure(address(sUnpacked), 1e18);
        console2.log("packed steady state", packedGas);
        console2.log("unpacked steady state", unpackedGas);
        console2.log("saving (load only)", unpackedGas - packedGas);

        assertGt(unpackedGas, packedGas);
        // One extra cold `SLOAD`, which is 2100 gas, net of what each side
        // computes around it. Measured at 2,054 — up from the 1,947 this
        // asserted before `UnpackedBucket` was corrected to keep its checkpoint
        // monotonic, because that guard is DEARER unpacked than packed.
        //
        // The individual figures, each measured by deleting the line and
        // re-running `testGasSteadyStateFill`:
        //
        // - `checkCapacity`, 55 gas, codec only. A level kept in a whole word
        //   has no packed width to exceed, so the two slot layout has no reason
        //   to bound the capacity and does not.
        // - The monotonic checkpoint comparison, 23 gas in the codec against
        //   137 in `UnpackedBucket`. Both pay it — any correct direct embedding
        //   must — but the codec compares a field of a word it is already
        //   holding, while the two slot layout reloads its checkpoint slot.
        //
        // The remainder is the packing shifts and masks, which the two slot
        // layout does not pay either.
        assertGt(unpackedGas - packedGas, 1_900);
        assertLt(unpackedGas - packedGas, 2_200);
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

    /// A rejected fill costs the read and the revert, and writes nothing. The
    /// band belongs to a capacity rejection specifically, so the rejection is
    /// identified before the gas is banded, and the "writes nothing" half is a
    /// state claim rather than a gas claim so it is asserted as one.
    function testGasRejectedFill() external {
        bytes memory call =
            abi.encodeWithSignature("fill(uint256,uint256,uint256)", CAPACITY, LEAK_RATE, type(uint256).max);
        uint256 before = gasleft();
        (bool ok, bytes memory reason) = address(sPacked).call(call);
        uint256 gas = before - gasleft();

        // Which revert, not just "reverted". `setUp` primed the bucket with
        // 1e18 and moved the clock on `DRAIN / 6` = 600 seconds, and 600e18 of
        // leak against 1e18 of level leaves it empty, so the level the error
        // reports is zero. Copying the reason does land inside the measured
        // window; it moves the measurement by 57 gas, 8,188 to 8,131, which is
        // nothing against a band 4,000 wide.
        assertTrue(!ok);
        assertEq(reason, abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, CAPACITY, 0, type(uint256).max));

        // The other half of the claim. The band is only indirect evidence for
        // it: a figure under 10,000 rules out a fresh `SSTORE` but not a warm
        // rewrite of the same slot at 100 gas, so a codec that wrote before
        // reverting, or a concrete that swallowed the revert after storing,
        // would sit inside the band. `sCheckpoint` is `PackedBucket`'s only
        // state variable, so it is slot 0.
        assertEq(vm.load(address(sPacked), bytes32(uint256(0))), sPackedSlotAtSetUp);

        console2.log("packed rejected fill", gas);
        assertGt(gas, 6_000);
        assertLt(gas, 10_000);
    }
}
