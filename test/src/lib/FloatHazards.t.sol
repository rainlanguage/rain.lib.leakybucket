// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.17.0/src/Test.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.5/src/lib/LibDecimalFloat.sol";
import {
    LibLeakyBucket,
    LeakyBucket,
    LeakyBucketZeroAmount,
    LeakyBucketAmountNotCredited
} from "../../../src/lib/LibLeakyBucket.sol";

/// Hazards that only exist because the bucket is `Float`, and that the fixed
/// point suite had no way to express.
///
/// The rest of the suite fuzzes whole numbers at exponent zero, which is what
/// makes its exactness assertions exact. These tests go where it deliberately
/// does not: across exponents, and at the representations `Float` admits for one
/// number.
contract FloatHazardsTest is Test {
    using LibDecimalFloat for Float;

    function f(int256 coefficient, int256 exponent) internal pure returns (Float) {
        return LibDecimalFloat.packLossless(coefficient, exponent);
    }

    function bucketOf(Float level, Float capacity) internal pure returns (LeakyBucket memory) {
        return LeakyBucket({level: level, timestamp: f(0, 0), capacity: capacity, leakRate: f(0, 0)});
    }

    /// An amount too far below the level to be recorded is refused BY NAME.
    ///
    /// This is the mint-cap failure that matters: a bucket that accepts an
    /// amount, reports success, and does not move is one that mints without
    /// charging. `Float` carries about 67 exact digits, so past a gap of 68
    /// decimal orders the amount falls off the tail of the sum. The boundary is
    /// exact — at a level of 1e40 the last credited amount is 1e-27 and 1e-28 is
    /// refused.
    function testAnAmountTooSmallToRecordIsRefused() external {
        Float level = f(1, 40);
        LeakyBucket memory bucket = bucketOf(level, f(1, 60));

        // One order inside the boundary: credited, and it raises the level.
        (Float credited,) = LibLeakyBucket.fill(bucket, f(0, 0), f(1, -27));
        assertTrue(credited.gt(level), "an amount inside the boundary was not credited");

        // One order past it: refused rather than swallowed.
        vm.expectRevert(abi.encodeWithSelector(LeakyBucketAmountNotCredited.selector, level, f(1, -28)));
        this.fillExternal(bucket, f(0, 0), f(1, -28));
    }

    /// Across a range of gaps: a fill either raises the level or reverts. It is
    /// never accepted for nothing.
    function testFillsAcrossExponentGapsEitherRaiseOrRevert(uint8 gap) external view {
        int256 exponent = -int256(uint256(bound(gap, 0, 80)));
        Float level = f(1, 40);
        LeakyBucket memory bucket = bucketOf(level, f(1, 60));
        Float amount = f(1, exponent);

        try this.fillExternal(bucket, f(0, 0), amount) returns (Float filled, Float) {
            assertTrue(filled.gt(level), "a fill that landed did not raise the level");
        } catch {
            // A refusal is a fine answer. Charging nothing is not.
        }
    }

    /// A zero written at a non-zero exponent is still zero, and still refused.
    ///
    /// `packLossless` canonicalises a zero, so the rest of the suite cannot
    /// reach this: it takes a `Float.wrap` to build a zero coefficient carrying
    /// an exponent. A caller decoding a `Float` off the wire can hand one over,
    /// and if `isZero` missed it the bucket would accept an amount of nothing.
    function testANonCanonicalZeroAmountIsStillRefused() external {
        Float weirdZero = Float.wrap(bytes32(uint256(5) << 224));
        assertTrue(weirdZero.isZero(), "a zero coefficient at exponent five is zero");

        LeakyBucket memory bucket = bucketOf(f(0, 0), f(100, 0));
        vm.expectRevert(LeakyBucketZeroAmount.selector);
        this.fillExternal(bucket, f(0, 0), weirdZero);
    }

    /// And the same for the capacity and the leak rate: a non-canonical zero
    /// capacity is a capacity of zero, which admits nothing rather than
    /// everything.
    function testANonCanonicalZeroCapacityAdmitsNothing() external pure {
        Float weirdZero = Float.wrap(bytes32(uint256(5) << 224));
        LeakyBucket memory bucket = bucketOf(f(0, 0), weirdZero);
        assertTrue(LibLeakyBucket.headroomAt(bucket, f(0, 0)).isZero());
    }

    /// `bucket` settled once a second for `count` seconds, each settle stored.
    function settledEachSecond(LeakyBucket memory bucket, int256 count) internal pure returns (LeakyBucket memory) {
        for (int256 i = 1; i <= count; i++) {
            (bucket.level, bucket.timestamp) = LibLeakyBucket.settle(bucket, bucket.timestamp.add(f(1, 0)));
        }
        return bucket;
    }

    /// A leak below the last digit the level holds is not subtracted as it is,
    /// and a settle advances the checkpoint over it, so settling is visible to
    /// a later read there, in both directions. A level of 1e40 holds digits
    /// down to 1e-27.
    function testASettleBelowTheLastDigitOfTheLevelShowsInLaterReads() external pure {
        Float level = f(1, 40);
        Float oneDigitDown = f(9999999999999999999999999999999999999999999999999999999999999999999, -27);
        Float tenDigitsDown = f(9999999999999999999999999999999999999999999999999999999999999999990, -27);

        // 1e-29 a second: each settle takes a whole 1e-27, so ten of them leak
        // ten times what the unsettled bucket does over the same ten seconds.
        LeakyBucket memory rounded =
            LeakyBucket({level: level, timestamp: f(0, 0), capacity: f(1, 60), leakRate: f(1, -29)});
        assertTrue(LibLeakyBucket.levelAt(rounded, f(1, 0)).eq(oneDigitDown), "one second, read");
        assertTrue(LibLeakyBucket.levelAt(rounded, f(10, 0)).eq(oneDigitDown), "ten seconds, read");
        LeakyBucket memory roundedSettled = settledEachSecond(rounded, 10);
        assertTrue(roundedSettled.timestamp.eq(f(10, 0)), "checkpoint");
        assertTrue(roundedSettled.level.eq(tenDigitsDown), "ten seconds, settled each second");

        // 1e-37 a second: each settle takes nothing and still advances the
        // checkpoint, so ten of them leak nothing where the unsettled bucket
        // reads a digit down.
        LeakyBucket memory dropped =
            LeakyBucket({level: level, timestamp: f(0, 0), capacity: f(1, 60), leakRate: f(1, -37)});
        (Float settled, Float settledAt) = LibLeakyBucket.settle(dropped, f(1, 0));
        assertTrue(settled.eq(level), "one second, settled");
        assertTrue(settledAt.eq(f(1, 0)), "one second, checkpoint");
        assertTrue(LibLeakyBucket.levelAt(dropped, f(10, 0)).eq(oneDigitDown), "ten seconds, read");
        LeakyBucket memory droppedSettled = settledEachSecond(dropped, 10);
        assertTrue(droppedSettled.timestamp.eq(f(10, 0)), "checkpoint");
        assertTrue(droppedSettled.level.eq(level), "ten seconds, settled each second");
    }

    function fillExternal(LeakyBucket memory bucket, Float timestamp, Float amount)
        external
        pure
        returns (Float, Float)
    {
        return LibLeakyBucket.fill(bucket, timestamp, amount);
    }
}
