// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
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

        try this.fillExternal(bucket, f(0, 0), amount) returns (Float after_, Float) {
            assertTrue(after_.gt(level), "a fill that landed did not raise the level");
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

    function fillExternal(LeakyBucket memory bucket, Float timestamp, Float amount)
        external
        pure
        returns (Float, Float)
    {
        return LibLeakyBucket.fill(bucket, timestamp, amount);
    }
}
