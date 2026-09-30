// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {LeakyBucketMintCap} from "../../concrete/LeakyBucketMintCap.sol";
import {LeakyBucketCapacityExceeded} from "../../../src/lib/LibLeakyBucket.sol";
import {workedCapacity, workedLeakRate, workedDrain} from "../../lib/WorkedPolicy.sol";

/// A whole number as a `Float` at exponent zero, which is how every amount in
/// this file is built.
function float(uint256 value) pure returns (Float) {
    //forge-lint: disable-next-line(unsafe-typecast)
    return LibDecimalFloat.packLossless(int256(value), 0);
}

/// The library under a real storage layout and a real clock, which is where the
/// mistakes that pure function tests cannot see would show up: state written
/// back wrong, buckets bleeding into each other, a policy change landing at the
/// wrong moment.
contract LeakyBucketEmbeddingTest is Test {
    using LibDecimalFloat for Float;

    LeakyBucketMintCap internal sCap;

    address internal constant ALICE = address(uint160(uint256(keccak256("alice"))));
    address internal constant BOB = address(uint160(uint256(keccak256("bob"))));

    /// An exact fraction of the worked capacity, which is the policy the suite
    /// examines, from `test/lib/WorkedPolicy.sol`: a 3600 unit burst at one unit
    /// per second sustained, so a full bucket drains in exactly `workedDrain()`
    /// seconds and every assertion below is exact whole number arithmetic.
    ///
    /// Every divisor this file uses — 2, 4, 10 and 20 — divides 3600 exactly in
    /// decimal, so what comes back is the number the test names rather than a
    /// rounding of it.
    function capacityOver(uint256 divisor) internal pure returns (Float) {
        return workedCapacity().div(float(divisor));
    }

    /// The worked capacity as a plain word, so the fuzzer can draw an amount
    /// bounded by it. Taken from the policy rather than restated beside it.
    function capacityWord() internal pure returns (uint256) {
        return workedCapacity().toFixedDecimalLossless(0);
    }

    /// Floats compare as numbers, not as words.
    ///
    /// `1800e0` and `18e2` are the same number held two ways, and which one an
    /// operation lands on is an artifact of the arithmetic rather than anything
    /// the cap promises.
    function assertFloatEq(Float actual, Float expected) internal pure {
        if (!actual.eq(expected)) {
            (int256 actualCoefficient, int256 actualExponent) = actual.unpack();
            (int256 expectedCoefficient, int256 expectedExponent) = expected.unpack();
            // Asserted rather than just reverted, so the failure prints both
            // numbers.
            assertEq(actualCoefficient, expectedCoefficient, "coefficient");
            assertEq(actualExponent, expectedExponent, "exponent");
            revert("float mismatch");
        }
    }

    /// The revert data of a mint that must not be accepted.
    function mintRefused(LeakyBucketMintCap cap, address minter, Float amount) internal returns (bytes memory) {
        vm.prank(minter);
        try cap.mint(amount) {
            revert("mint was accepted");
        } catch (bytes memory reason) {
            return reason;
        }
    }

    /// The three fields of the `LeakyBucketCapacityExceeded` a call reverted
    /// with, checked one at a time as numbers.
    ///
    /// The old tests matched the whole encoded error as bytes, which they could
    /// because every field was a `uint256` and a `uint256` has one
    /// representation. A `Float` does not, so matching bytes would be asserting
    /// on which representation the arithmetic happened to produce. The claim
    /// made here is the one the old form made: this error, carrying these three
    /// values, rather than a panic, an out of gas, or a rejection of some other
    /// amount.
    function assertCapacityExceeded(bytes memory reason, Float capacity, Float level, Float amount) internal pure {
        assertEq(reason.length, 4 + 3 * 32, "not a three field error");
        // Truncating to the first four bytes is the point: the selector is
        // what says which error this is.
        //forge-lint: disable-next-line(unsafe-typecast)
        assertTrue(bytes4(reason) == LeakyBucketCapacityExceeded.selector, "not LeakyBucketCapacityExceeded");
        bytes memory args = new bytes(reason.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = reason[i + 4];
        }
        (bytes32 errCapacity, bytes32 errLevel, bytes32 errAmount) = abi.decode(args, (bytes32, bytes32, bytes32));
        assertFloatEq(Float.wrap(errCapacity), capacity);
        assertFloatEq(Float.wrap(errLevel), level);
        assertFloatEq(Float.wrap(errAmount), amount);
    }

    function setUp() external {
        sCap = new LeakyBucketMintCap();
        sCap.setPolicy(ALICE, workedCapacity(), workedLeakRate());
        sCap.setPolicy(BOB, workedCapacity(), workedLeakRate());
        vm.warp(1_700_000_000);
    }

    /// An untouched minter starts with a full allowance and no stored state.
    function testUntouchedMinterStartsEmpty() external view {
        assertFloatEq(sCap.level(ALICE), float(0));
        assertFloatEq(sCap.headroom(ALICE), workedCapacity());
    }

    /// A minter with no policy at all can mint nothing.
    function testUnconfiguredMinterCanMintNothing() external {
        address mallory = address(uint160(uint256(keccak256("mallory"))));
        assertFloatEq(sCap.headroom(mallory), float(0));
        assertCapacityExceeded(mintRefused(sCap, mallory, float(1)), float(0), float(0), float(1));
    }

    /// The burst lands, and the next unit does not.
    function testBurstToCapacityThenBlocked() external {
        vm.prank(ALICE);
        sCap.mint(workedCapacity());
        assertFloatEq(sCap.level(ALICE), workedCapacity());
        assertFloatEq(sCap.headroom(ALICE), float(0));

        assertCapacityExceeded(mintRefused(sCap, ALICE, float(1)), workedCapacity(), workedCapacity(), float(1));
    }

    /// Leak is credited once per second through the write path.
    function testLeakIsCreditedOnceNotPerCall() external {
        vm.prank(ALICE);
        sCap.mint(workedCapacity());
        assertFloatEq(sCap.level(ALICE), workedCapacity());

        // Half the drain time, taken in one step.
        vm.warp(block.timestamp + workedDrain() / 2);
        assertFloatEq(sCap.level(ALICE), capacityOver(2));

        // The same half hour a second at a time, minting exactly one second of
        // leak each second: every mint fits, and the bucket stays full.
        LeakyBucketMintCap other = new LeakyBucketMintCap();
        other.setPolicy(BOB, workedCapacity(), workedLeakRate());
        vm.warp(1_700_000_000);
        vm.prank(BOB);
        other.mint(workedCapacity());
        for (uint256 i = 0; i < workedDrain() / 2; i++) {
            vm.warp(block.timestamp + 1);
            vm.prank(BOB);
            other.mint(workedLeakRate());
        }
        assertFloatEq(other.level(BOB), workedCapacity());
        assertFloatEq(other.headroom(BOB), float(0));
    }

    /// Buckets are per minter.
    function testBucketsAreIndependentPerMinter() external {
        vm.prank(ALICE);
        sCap.mint(workedCapacity());

        assertFloatEq(sCap.headroom(ALICE), float(0));
        assertFloatEq(sCap.headroom(BOB), workedCapacity());

        vm.prank(BOB);
        sCap.mint(workedCapacity());
        assertFloatEq(sCap.headroom(BOB), float(0));
    }

    /// Different minters can run different policies at the same time, which is
    /// the case a single shared configuration cannot express.
    ///
    /// A tenth of the worked leak rate is a tenth of one unit per second, which
    /// the old fixed point scale spelled as `1e17` and a `Float` spells as
    /// `1e-1`. The policy carries its own exponent now, so a rate below one
    /// unit is an ordinary number rather than a scaling convention.
    function testMintersCanRunDifferentPolicies() external {
        sCap.setPolicy(BOB, capacityOver(10), workedLeakRate().div(float(10)));

        assertFloatEq(sCap.headroom(ALICE), workedCapacity());
        assertFloatEq(sCap.headroom(BOB), capacityOver(10));

        Float overByOne = capacityOver(10).add(float(1));
        assertCapacityExceeded(mintRefused(sCap, BOB, overByOne), capacityOver(10), float(0), overByOne);

        vm.prank(ALICE);
        sCap.mint(workedCapacity());
        assertFloatEq(sCap.totalMinted(), workedCapacity());
    }

    /// The sustained rate is what it says: an exhausted bucket recovers its
    /// whole capacity over exactly one drain time, and a fraction of it over a
    /// fraction of that time.
    function testDrainsAtTheSustainedRate() external {
        vm.prank(ALICE);
        sCap.mint(workedCapacity());

        vm.warp(block.timestamp + workedDrain() / 4);
        assertFloatEq(sCap.headroom(ALICE), capacityOver(4));

        vm.warp(block.timestamp + workedDrain() / 4);
        assertFloatEq(sCap.headroom(ALICE), capacityOver(2));

        vm.warp(block.timestamp + workedDrain() / 2);
        assertFloatEq(sCap.headroom(ALICE), workedCapacity());

        // And it stops at full rather than accruing credit for idle time.
        vm.warp(block.timestamp + 365 days);
        assertFloatEq(sCap.headroom(ALICE), workedCapacity());
    }

    /// A capacity cut lands the instant governance executes it, with no fill,
    /// no migration and no way for the minter to front run the drain.
    function testCapacityCutBindsImmediately() external {
        vm.prank(ALICE);
        sCap.mint(workedCapacity());
        vm.warp(block.timestamp + workedDrain() / 2);
        assertFloatEq(sCap.headroom(ALICE), capacityOver(2));

        // Timelock executes: burst cut to a tenth.
        sCap.setPolicy(ALICE, capacityOver(10), workedLeakRate());

        // The outstanding level is still half the old capacity, which is five
        // times the new capacity, so nothing fits.
        //
        // Read from `sCap.level` AND off the refusal, because they came apart
        // once: a harness deriving the level as `capacity - headroom` reported
        // the new capacity here, since the headroom saturates at zero whenever the
        // level is above the capacity. A cut is the only state that distinguishes
        // the two, so it is the only place a test can hold `level` to reporting
        // what is owed rather than what fits.
        assertFloatEq(sCap.headroom(ALICE), float(0));
        assertFloatEq(sCap.level(ALICE), capacityOver(2));
        assertCapacityExceeded(mintRefused(sCap, ALICE, float(1)), capacityOver(10), capacityOver(2), float(1));

        // It drains under the new policy without intervention. The wait is the
        // time it takes the outstanding level to fall from half the old
        // capacity to a twentieth of it, which is the new capacity's half.
        vm.warp(block.timestamp + workedDrain() / 2 - workedDrain() / 20);
        assertFloatEq(sCap.level(ALICE), capacityOver(20));
        assertFloatEq(sCap.headroom(ALICE), capacityOver(20));
    }

    /// The second a given amount fits again is exactly the second the leak pays
    /// for it, and not one second earlier.
    function testTheSecondAHalfCapacityFitsAgain() external {
        vm.prank(ALICE);
        sCap.mint(workedCapacity());

        uint256 at = block.timestamp + workedDrain() / 2;

        // One second early the bucket has leaked for one second less than the
        // wait, so it is exactly one second's leak short of fitting. The level
        // and the headroom at that instant are both pinned, and the refusal is
        // checked field by field, so this cannot pass on an arithmetic panic,
        // an out of gas, or a rejection of some other amount — which a bare
        // `vm.expectRevert()` could not tell apart from the cap binding.
        Float levelJustEarly = workedCapacity().sub(float(workedDrain() / 2 - 1).mul(workedLeakRate()));
        vm.warp(at - 1);
        assertFloatEq(sCap.level(ALICE), levelJustEarly);
        assertFloatEq(sCap.headroom(ALICE), capacityOver(2).sub(workedLeakRate()));
        assertCapacityExceeded(
            mintRefused(sCap, ALICE, capacityOver(2)), workedCapacity(), levelJustEarly, capacityOver(2)
        );

        // And nothing was written by the rejected attempt: at `at` the level is
        // what the leak alone makes it, and the amount that was refused a
        // second ago now fits exactly.
        vm.warp(at);
        assertFloatEq(sCap.level(ALICE), capacityOver(2));
        assertFloatEq(sCap.headroom(ALICE), capacityOver(2));
        vm.prank(ALICE);
        sCap.mint(capacityOver(2));
        assertFloatEq(sCap.totalMinted(), workedCapacity().add(capacityOver(2)));
        assertFloatEq(sCap.headroom(ALICE), float(0));
    }

    /// However a minter splits its calls, and however long it waits between
    /// them, the burst available to it is never more than one capacity.
    function testNoMintExceedsCapacityUnderArbitrarySplits(uint8 mints, uint16[16] memory gaps, uint256 amount)
        external
    {
        mints = uint8(bound(mints, 1, 16));
        Float amountFloat = float(bound(amount, 1, capacityWord()));

        uint256 start = block.timestamp;
        Float minted = float(0);
        for (uint256 i = 0; i < mints; i++) {
            vm.warp(block.timestamp + gaps[i]);
            // The burst on offer is never larger than one capacity, no matter
            // what has happened up to here or how long the wait was.
            Float headroomBefore = sCap.headroom(ALICE);
            Float levelBefore = sCap.level(ALICE);
            assertTrue(headroomBefore.lte(workedCapacity()));
            // Two independent reads of the same bucket: `headroomAt` saturates a
            // subtraction from the capacity, `levelAt` leaks the stored level
            // forward. They agree on every bucket at or under capacity, and
            // this pins that they do.
            assertFloatEq(headroomBefore, workedCapacity().sub(levelBefore));

            if (amountFloat.lte(headroomBefore)) {
                // It fits, so it must land, and land exactly.
                vm.prank(ALICE);
                sCap.mint(amountFloat);
                minted = minted.add(amountFloat);
                assertFloatEq(sCap.level(ALICE), levelBefore.add(amountFloat));
                assertFloatEq(sCap.headroom(ALICE), headroomBefore.sub(amountFloat));
            } else {
                // It does not fit, so it must be refused, for this reason, and
                // leave the bucket exactly as it was.
                assertCapacityExceeded(
                    mintRefused(sCap, ALICE, amountFloat), workedCapacity(), levelBefore, amountFloat
                );
                assertFloatEq(sCap.level(ALICE), levelBefore);
                assertFloatEq(sCap.headroom(ALICE), headroomBefore);
            }
        }

        assertFloatEq(minted, sCap.totalMinted());
        assertTrue(minted.lte(workedCapacity().add(float(block.timestamp - start).mul(workedLeakRate()))));
    }

    /// A clock that steps backwards banks no credit, through real storage.
    function testBackwardsClockBanksNoCredit() external {
        vm.prank(ALICE);
        sCap.mint(workedCapacity());
        assertFloatEq(sCap.level(ALICE), workedCapacity());

        uint256 filled = block.timestamp;

        // The clock falls back an hour and the bucket still reads full.
        vm.warp(filled - workedDrain());
        assertCapacityExceeded(mintRefused(sCap, ALICE, float(1)), workedCapacity(), workedCapacity(), float(1));

        // Back at the second of the original mint the bucket is still full.
        // The hour the clock claimed to rewind bought nothing: without the
        // guard the stored checkpoint would have moved back with it and this
        // would read as an empty bucket with a whole capacity on offer.
        vm.warp(filled);
        assertFloatEq(sCap.level(ALICE), workedCapacity());
        assertFloatEq(sCap.headroom(ALICE), float(0));

        // And one real hour later it is one capacity, not two hours of leak.
        vm.warp(filled + workedDrain());
        assertFloatEq(sCap.headroom(ALICE), workedCapacity());
        vm.prank(ALICE);
        sCap.mint(workedCapacity());
        assertFloatEq(sCap.totalMinted(), workedCapacity().mul(float(2)));
    }
}
