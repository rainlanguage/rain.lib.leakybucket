// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {LeakyBucketMintCap} from "../../concrete/LeakyBucketMintCap.sol";
import {LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {LeakyBucketCapacityOverflow, LEAKY_BUCKET_LEVEL_MAX} from "../../../src/lib/LibLeakyBucketCheckpoint.sol";
import {WORKED_CAPACITY, WORKED_LEAK_RATE, WORKED_DRAIN} from "../../lib/WorkedPolicy.sol";
import {UnpackedBucket} from "../../concrete/UnpackedBucket.sol";

/// The library under a real storage layout and a real clock, which is where the
/// mistakes that pure function tests cannot see would show up: state written
/// back wrong, buckets bleeding into each other, a policy change landing at the
/// wrong moment.
contract LeakyBucketEmbeddingTest is Test {
    LeakyBucketMintCap internal cap;

    address internal constant ALICE = address(uint160(uint256(keccak256("alice"))));
    address internal constant BOB = address(uint160(uint256(keccak256("bob"))));

    /// The worked policy the suite examines, from `test/lib/WorkedPolicy.sol`:
    /// a 3600 unit burst at one unit per second sustained, so a full bucket
    /// drains in exactly `DRAIN` seconds and every assertion below is exact
    /// integer arithmetic. `DRAIN` is the quotient of the other two rather than
    /// a restated literal, and the waits below are written over it so each one
    /// says what fraction of a drain it is.
    uint256 internal constant CAPACITY = WORKED_CAPACITY;
    uint256 internal constant LEAK_RATE = WORKED_LEAK_RATE;
    uint256 internal constant DRAIN = WORKED_DRAIN;

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
        vm.warp(block.timestamp + DRAIN / 2);
        assertEq(cap.level(ALICE), CAPACITY / 2);

        // The same half hour, taken a second at a time with a checkpoint every
        // second, lands on exactly the same level.
        LeakyBucketMintCap other = new LeakyBucketMintCap();
        other.setPolicy(BOB, CAPACITY, LEAK_RATE);
        vm.warp(1_700_000_000);
        vm.prank(BOB);
        other.mint(CAPACITY);
        for (uint256 i = 0; i < DRAIN / 2; i++) {
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

        vm.warp(block.timestamp + DRAIN / 4);
        assertEq(cap.headroom(ALICE), CAPACITY / 4);

        vm.warp(block.timestamp + DRAIN / 4);
        assertEq(cap.headroom(ALICE), CAPACITY / 2);

        vm.warp(block.timestamp + DRAIN / 2);
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
        vm.warp(block.timestamp + DRAIN / 2);
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

        // It drains under the new policy without intervention. The wait is the
        // time it takes the outstanding level to fall from half the old
        // capacity to a twentieth of it, which is the new capacity's half.
        vm.warp(block.timestamp + DRAIN / 2 - DRAIN / 20);
        assertEq(cap.level(ALICE), CAPACITY / 20);
        assertEq(cap.headroom(ALICE), CAPACITY / 20);
    }

    /// `fillableAt` tells a caller when to come back, and it is right.
    function testFillableAtPredictsTheNextMint() external {
        vm.prank(ALICE);
        cap.mint(CAPACITY);

        uint256 at = cap.fillableAt(ALICE, CAPACITY / 2);
        assertEq(at, block.timestamp + DRAIN / 2);

        // One second early the bucket has leaked for one second less than the
        // wait, so it is exactly one second's leak short of fitting. The level
        // and the headroom at that instant are both pinned, and the revert is
        // matched on its full data, so this cannot pass on an arithmetic panic,
        // an out of gas, or a rejection of some other amount — which a bare
        // `vm.expectRevert()` could not tell apart from the cap binding.
        uint256 levelJustEarly = CAPACITY - (DRAIN / 2 - 1) * LEAK_RATE;
        vm.warp(at - 1);
        assertEq(cap.level(ALICE), levelJustEarly);
        assertEq(cap.headroom(ALICE), CAPACITY / 2 - LEAK_RATE);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(LeakyBucketCapacityExceeded.selector, CAPACITY, levelJustEarly, CAPACITY / 2)
        );
        cap.mint(CAPACITY / 2);

        // And nothing was written by the rejected attempt: at `at` the level is
        // what the leak alone makes it, and the amount that was refused a
        // second ago now fits exactly.
        vm.warp(at);
        assertEq(cap.level(ALICE), CAPACITY / 2);
        assertEq(cap.headroom(ALICE), CAPACITY / 2);
        vm.prank(ALICE);
        cap.mint(CAPACITY / 2);
        assertEq(cap.totalMinted(), CAPACITY + CAPACITY / 2);
        assertEq(cap.headroom(ALICE), 0);
    }

    /// However a minter splits its calls, and however long it waits between
    /// them, the burst available to it is never more than one capacity. The
    /// fuzzer picks the split and the gaps; the assertion inside the loop is
    /// the security property, checked at every point of an arbitrary history.
    function testNoMintExceedsCapacityUnderArbitrarySplits(uint8 mints, uint16[16] memory gaps, uint256 amount)
        external
    {
        mints = uint8(bound(mints, 1, 16));
        amount = bound(amount, 1, CAPACITY);

        uint256 start = block.timestamp;
        uint256 minted = 0;
        for (uint256 i = 0; i < mints; i++) {
            vm.warp(block.timestamp + gaps[i]);
            // The burst on offer is never larger than one capacity, no matter
            // what has happened up to here or how long the wait was.
            assertLe(cap.headroom(ALICE), CAPACITY);
            vm.prank(ALICE);
            try cap.mint(amount) {
                minted += amount;
            } catch {}
        }

        assertEq(minted, cap.totalMinted());
        assertLe(minted, CAPACITY + (block.timestamp - start) * LEAK_RATE);
    }

    /// A clock that steps backwards banks no credit, through real storage.
    ///
    /// `block.timestamp` is monotonic within a chain, so this is not reachable
    /// from the embedding above; it is reachable the moment a concrete feeds
    /// the library a time from anywhere else, which the API permits and this
    /// library is chain agnostic enough to have to survive. The mint at the
    /// stale second is a checkpoint and nothing else, and the bucket must read
    /// at every later second exactly as it would have if that call had never
    /// happened.
    function testBackwardsClockBanksNoCredit() external {
        vm.prank(ALICE);
        cap.mint(CAPACITY);
        assertEq(cap.level(ALICE), CAPACITY);

        uint256 filled = block.timestamp;

        // The clock falls back an hour and ALICE mints nothing at all.
        vm.warp(filled - DRAIN);
        vm.prank(ALICE);
        cap.mint(0);

        // Back at the second of the original mint the bucket is still full.
        // The hour the clock claimed to rewind bought nothing: without the
        // guard the stored checkpoint would have moved back with it and this
        // would read as an empty bucket with a whole capacity on offer.
        vm.warp(filled);
        assertEq(cap.level(ALICE), CAPACITY);
        assertEq(cap.headroom(ALICE), 0);

        // And one real hour later it is one capacity, not two hours of leak.
        vm.warp(filled + DRAIN);
        assertEq(cap.headroom(ALICE), CAPACITY);
        vm.prank(ALICE);
        cap.mint(CAPACITY);
        assertEq(cap.totalMinted(), CAPACITY * 2);
    }

    /// A capacity wider than the packed level field is refused where governance
    /// sets it, rather than discovered at mint time by whoever is unlucky
    /// enough to be minting when it first binds.
    function testGovernanceCannotSetAnUnenforceableCapacity() external {
        uint256 capacity = LEAKY_BUCKET_LEVEL_MAX + 1;

        vm.expectRevert(abi.encodeWithSelector(LeakyBucketCapacityOverflow.selector, capacity));
        cap.setPolicy(ALICE, capacity, LEAK_RATE);

        // ALICE keeps the policy she had, so a refused change is inert rather
        // than half applied.
        assertEq(cap.headroom(ALICE), CAPACITY);

        // The widest capacity the codec can store is settable and binds.
        cap.setPolicy(BOB, LEAKY_BUCKET_LEVEL_MAX, LEAK_RATE);
        assertEq(cap.headroom(BOB), LEAKY_BUCKET_LEVEL_MAX);
    }

    /// The same backwards-clock property as `testBackwardsClockBanksNoCredit`,
    /// but for state held OUTSIDE the codec.
    ///
    /// `LibLeakyBucket` cannot enforce this: it is pure and owns no slot, so
    /// the obligation falls on whoever keeps the checkpoint. The README states
    /// it in prose and `levelAt`'s NatSpec states it again, and `UnpackedBucket`
    /// is the only place in the repo where a reader can see the unpacked
    /// embedding written out — which makes it the artifact that gets copied.
    /// Enforcing it here means the example cannot quietly regress to the
    /// unguarded three-line `fill` that reintroduces the bug.
    function testUnpackedEmbeddingKeepsItsCheckpointMonotonic() external {
        UnpackedBucket bucket = new UnpackedBucket();
        bucket.fill(CAPACITY, LEAK_RATE, CAPACITY);
        assertEq(bucket.headroom(CAPACITY, LEAK_RATE), 0);

        uint256 filled = block.timestamp;

        // The clock falls back a whole drain time and the bucket is touched
        // with a zero fill, which is a checkpoint and nothing else.
        vm.warp(filled - DRAIN);
        bucket.fill(CAPACITY, LEAK_RATE, 0);

        // Back at the second of the original fill it is still full. Without the
        // comparison in `fill` the stored checkpoint would have gone back with
        // the clock and this would read as a whole capacity of headroom.
        vm.warp(filled);
        assertEq(bucket.headroom(CAPACITY, LEAK_RATE), 0);

        // And one real drain time later it is one capacity, not two.
        vm.warp(filled + DRAIN);
        assertEq(bucket.headroom(CAPACITY, LEAK_RATE), CAPACITY);
    }
}
