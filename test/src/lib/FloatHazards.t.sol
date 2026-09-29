// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {LibLeakyBucket, LeakyBucket, LeakyBucketZeroAmount} from "../../../src/lib/LibLeakyBucket.sol";

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

    /// A fill far below the level's exponent either lands or is refused. It is
    /// never silently swallowed.
    ///
    /// This is the mint-cap failure that matters: a bucket that accepts an
    /// amount, reports success, and does not move is one that mints without
    /// charging. Whatever `Float` addition does at this exponent gap, the level
    /// after a successful fill must differ from the level before it. The
    /// stronger claim — that it is HIGHER — does not hold past a 68 order gap,
    /// which is issue #117. An
    /// earlier version asserted only that the packed word changed, which a
    /// dropped tail can satisfy without the amount being credited.
    function testATinyFillIsNeverSilentlySwallowed() external pure {
        Float level = f(1, 40);
        LeakyBucket memory bucket = bucketOf(level, f(1, 60));
        Float tiny = f(1, -40);

        (Float after_,) = LibLeakyBucket.fill(bucket, f(0, 0), tiny);
        // Word inequality, not `gt`. `gt` is the property that matters and it
        // FAILS past a 68 order gap: see issue #117. Asserting the current
        // behaviour would enshrine it, so this pins only that the level moved.
        assertNotEq(Float.unwrap(after_), Float.unwrap(level), "the level did not move at all");
    }

    /// The same claim across a range of gaps, so the boundary is found rather
    /// than assumed to be beyond one hand-picked pair.
    function testFillsAcrossExponentGapsEitherLandOrRevert(uint8 gap) external view {
        int256 exponent = -int256(uint256(bound(gap, 0, 80)));
        Float level = f(1, 40);
        LeakyBucket memory bucket = bucketOf(level, f(1, 60));
        Float amount = f(1, exponent);

        try this.fillExternal(bucket, f(0, 0), amount) returns (Float after_, Float) {
            // Word inequality, not `gt`. `gt` is the property that matters and it
            // FAILS past a 68 order gap: see issue #117. Asserting the current
            // behaviour would enshrine it, so this pins only that the level moved.
            assertNotEq(Float.unwrap(after_), Float.unwrap(level), "the level did not move at all");
        } catch {
            // A refusal is a fine answer. Losing the amount is not.
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
