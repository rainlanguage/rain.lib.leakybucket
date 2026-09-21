// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {LeakyBucketMintCap} from "../../lib/LeakyBucketMintCap.sol";
import {LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";

/// The library under a real storage layout and a real clock, which is where the
/// mistakes that pure function tests cannot see would show up: state written
/// back wrong, buckets bleeding into each other, a policy change landing at the
/// wrong moment.
contract LeakyBucketEmbeddingTest is Test {
    LeakyBucketMintCap internal cap;

    address internal constant ALICE = address(uint160(uint256(keccak256("alice"))));
    address internal constant BOB = address(uint160(uint256(keccak256("bob"))));

    /// A 3600 unit burst.
    uint256 internal constant CAPACITY = 3600e18;
    /// One unit per second sustained, so a full bucket drains in exactly an
    /// hour and every assertion below is exact integer arithmetic.
    uint256 internal constant LEAK_RATE = 1e18;

    function setUp() external {
        cap = new LeakyBucketMintCap();
        cap.setPolicy(ALICE, CAPACITY, LEAK_RATE);
        cap.setPolicy(BOB, CAPACITY, LEAK_RATE);
        vm.warp(1_700_000_000);
    }

    /// An untouched minter starts with a full allowance and no stored state.
    function testUntouchedMinterStartsEmpty() external view {
        assertEq(cap.level(ALICE), 0);
        assertEq(cap.headroom(ALICE), CAPACITY);
    }

    /// A minter with no policy at all can mint nothing. Capacity zero is a
    /// closed door, so forgetting to configure a minter fails closed.
    function testUnconfiguredMinterCanMintNothing() external {
        address mallory = address(uint160(uint256(keccak256("mallory"))));
        assertEq(cap.headroom(mallory), 0);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, 0, 0, 1));
        cap.mint(1);
    }

    /// The burst lands, and the next unit does not.
    function testBurstToCapacityThenBlocked() external {
        vm.prank(ALICE);
        cap.mint(CAPACITY);
        assertEq(cap.level(ALICE), CAPACITY);
        assertEq(cap.headroom(ALICE), 0);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, CAPACITY, CAPACITY, 1));
        cap.mint(1);
    }

    /// The state written back is the state read next block. This is the test
    /// that would fail if the level were stored without its timestamp: the leak
    /// from the original checkpoint would be credited again on every call and
    /// the headroom would come back too high.
    function testLeakIsCreditedOnceNotPerCall() external {
        vm.prank(ALICE);
        cap.mint(CAPACITY);

        // Drip a hundred no-op mints across the same second. Each one rewrites
        // the checkpoint, and none of them may move the level.
        for (uint256 i = 0; i < 100; i++) {
            vm.prank(ALICE);
            cap.mint(0);
        }
        assertEq(cap.level(ALICE), CAPACITY);

        // Half the drain time, taken in one step.
        vm.warp(block.timestamp + 1800);
        assertEq(cap.level(ALICE), CAPACITY / 2);

        // The same half hour, taken a second at a time with a checkpoint every
        // second, lands on exactly the same level.
        LeakyBucketMintCap other = new LeakyBucketMintCap();
        other.setPolicy(BOB, CAPACITY, LEAK_RATE);
        vm.warp(1_700_000_000);
        vm.prank(BOB);
        other.mint(CAPACITY);
        for (uint256 i = 0; i < 1800; i++) {
            vm.warp(block.timestamp + 1);
            vm.prank(BOB);
            other.mint(0);
        }
        assertEq(other.level(BOB), CAPACITY / 2);
        assertEq(other.level(BOB), cap.level(ALICE));
    }

    /// Buckets are per minter. Alice exhausting hers leaves Bob untouched.
    function testBucketsAreIndependentPerMinter() external {
        vm.prank(ALICE);
        cap.mint(CAPACITY);

        assertEq(cap.headroom(ALICE), 0);
        assertEq(cap.headroom(BOB), CAPACITY);

        vm.prank(BOB);
        cap.mint(CAPACITY);
        assertEq(cap.headroom(BOB), 0);
    }

    /// Different minters can run different policies at the same time, which is
    /// the case a single shared configuration cannot express.
    function testMintersCanRunDifferentPolicies() external {
        cap.setPolicy(BOB, CAPACITY / 10, LEAK_RATE / 10);

        assertEq(cap.headroom(ALICE), CAPACITY);
        assertEq(cap.headroom(BOB), CAPACITY / 10);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, CAPACITY / 10, 0, CAPACITY / 10 + 1)
        );
        cap.mint(CAPACITY / 10 + 1);

        vm.prank(ALICE);
        cap.mint(CAPACITY);
        assertEq(cap.totalMinted(), CAPACITY);
    }

    /// The sustained rate is what it says: an exhausted bucket recovers its
    /// whole capacity over exactly one drain time, and a fraction of it over a
    /// fraction of that time.
    function testDrainsAtTheSustainedRate() external {
        vm.prank(ALICE);
        cap.mint(CAPACITY);

        vm.warp(block.timestamp + 900);
        assertEq(cap.headroom(ALICE), CAPACITY / 4);

        vm.warp(block.timestamp + 900);
        assertEq(cap.headroom(ALICE), CAPACITY / 2);

        vm.warp(block.timestamp + 1800);
        assertEq(cap.headroom(ALICE), CAPACITY);

        // And it stops at full rather than accruing credit for idle time.
        vm.warp(block.timestamp + 365 days);
        assertEq(cap.headroom(ALICE), CAPACITY);
    }

    /// A capacity cut lands the instant governance executes it, with no fill,
    /// no migration and no way for the minter to front run the drain.
    function testCapacityCutBindsImmediately() external {
        vm.prank(ALICE);
        cap.mint(CAPACITY);
        vm.warp(block.timestamp + 1800);
        assertEq(cap.headroom(ALICE), CAPACITY / 2);

        // Timelock executes: burst cut to a tenth.
        cap.setPolicy(ALICE, CAPACITY / 10, LEAK_RATE);

        // The outstanding level is still half the old capacity, which is five
        // times the new capacity, so nothing fits.
        assertEq(cap.level(ALICE), CAPACITY / 2);
        assertEq(cap.headroom(ALICE), 0);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, CAPACITY / 10, CAPACITY / 2, 1));
        cap.mint(1);

        // It drains under the new policy without intervention.
        vm.warp(block.timestamp + 1620);
        assertEq(cap.level(ALICE), CAPACITY / 20);
        assertEq(cap.headroom(ALICE), CAPACITY / 20);
    }

    /// `fillableAt` tells a caller when to come back, and it is right.
    function testFillableAtPredictsTheNextMint() external {
        vm.prank(ALICE);
        cap.mint(CAPACITY);

        uint256 at = cap.fillableAt(ALICE, CAPACITY / 2);
        assertEq(at, block.timestamp + 1800);

        vm.warp(at - 1);
        vm.prank(ALICE);
        vm.expectRevert();
        cap.mint(CAPACITY / 2);

        vm.warp(at);
        vm.prank(ALICE);
        cap.mint(CAPACITY / 2);
        assertEq(cap.totalMinted(), CAPACITY + CAPACITY / 2);
    }

    /// Across any window the total minted stays inside `capacity + elapsed *
    /// leakRate`, however the minter splits the calls up. The fuzzer picks the
    /// split and the gaps.
    function testBurstPlusRateBoundHoldsUnderArbitrarySplits(uint8 mints, uint16[16] memory gaps, uint256 amount)
        external
    {
        mints = uint8(bound(mints, 1, 16));
        amount = bound(amount, 1, CAPACITY);

        uint256 start = block.timestamp;
        uint256 minted = 0;
        for (uint256 i = 0; i < mints; i++) {
            vm.warp(block.timestamp + gaps[i]);
            vm.prank(ALICE);
            try cap.mint(amount) {
                minted += amount;
            } catch {}
        }

        assertEq(minted, cap.totalMinted());
        assertLe(minted, CAPACITY + (block.timestamp - start) * LEAK_RATE);
    }
}
