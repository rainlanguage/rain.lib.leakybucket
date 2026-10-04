// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {Test} from "forge-std-1.17.0/src/Test.sol";
import {Float, LibDecimalFloat} from "rain-math-float-0.2.5/src/lib/LibDecimalFloat.sol";
import {LeakyBucketCapacityExceeded} from "../../src/lib/LibLeakyBucket.sol";
import {LeakyBucketScratch} from "./LeakyBucketScratch.sol";

/// @title LeakyBucketAsserts
/// @notice The bounds and assertions every bucket test works through.
///
/// These lived as a copy per test file until the copies started to differ from
/// each other while claiming to say the same thing. One definition means a
/// precision bound moves in one place.
abstract contract LeakyBucketAsserts is Test, LeakyBucketScratch {
    using LibDecimalFloat for Float;

    /// Every fuzzed number in the suite is a whole number at exponent zero,
    /// drawn from these bounds.
    ///
    /// The bounds are what keeps the assertions exact. A `Float` carries 224
    /// bits of coefficient, about 67 decimal digits, and a sum or a product
    /// needing more digits than that keeps its magnitude and drops its tail.
    /// Levels and capacities of at most `2**128`, times of at most `2**64` and
    /// leak rates of at most `2**128` put the widest product the suite can
    /// build — an elapsed time times a leak rate — at about 58 digits, so
    /// nothing rounds.
    ///
    /// The old bounds were the packed fields: `uint192` for a level, `uint64`
    /// for a timestamp, and the whole word for a leak rate, which took no part
    /// in the packing. Nothing is packed now, so these are precision bounds
    /// rather than layout ones, and a leak rate is bounded like everything
    /// else.
    uint256 internal constant MAX_LEVEL = type(uint128).max;
    uint256 internal constant MAX_TIME = type(uint64).max;
    uint256 internal constant MAX_LEAK_RATE = type(uint128).max;

    /// The same bound as `MAX_LEVEL`, for the fuzzed inputs that carry a sign.
    int256 internal constant MAX_SIGNED = int256(uint256(type(uint128).max));

    /// A capacity above every level the bounds above can reach.
    ///
    /// The reads that take it are probing the leak rather than the capacity, so
    /// it is named high enough that no bucket built with it is ever over it.
    /// The old suite had `LEAKY_BUCKET_LEVEL_MAX` to hand for this; a `Float`
    /// has no such ceiling to borrow, so the bound is named here.
    function probeCapacity() internal pure returns (Float) {
        return LibDecimalFloat.packLossless(1, 40);
    }

    /// Floats compare as numbers, not as words.
    ///
    /// `1800e0` and `18e2` are the same number held two ways, and which one an
    /// operation lands on is an artifact of the arithmetic rather than anything
    /// the bucket promises.
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

    /// `actual <= expected` as numbers.
    function assertFloatLe(Float actual, Float expected) internal pure {
        assertTrue(actual.lte(expected), "not <=");
    }

    /// `actual >= expected` as numbers.
    function assertFloatGe(Float actual, Float expected) internal pure {
        assertTrue(actual.gte(expected), "not >=");
    }

    /// The revert data of a fill that must not be accepted.
    function fillRefused(Float level, Float checkpoint, Float timestamp, Float capacity, Float leakRate, Float amount)
        internal
        view
        returns (bytes memory)
    {
        try this.externalFill(level, checkpoint, timestamp, capacity, leakRate, amount) returns (Float, Float) {
            revert("fill was accepted");
        } catch (bytes memory reason) {
            return reason;
        }
    }

    /// A revert reason without its four byte selector, so the arguments decode.
    ///
    /// An empty revert and an out of gas revert both carry fewer than four
    /// bytes. Asserting the length rather than subtracting through it keeps the
    /// real failure visible, instead of replacing it with an arithmetic panic
    /// from the underflow.
    function sliceReason(bytes memory reason) internal pure returns (bytes memory) {
        assertGe(reason.length, 4, "revert data too short to carry a selector");
        bytes memory args = new bytes(reason.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = reason[i + 4];
        }
        return args;
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
        // Truncating to `bytes4` is the point: the selector IS the first four
        // bytes of the revert data, and the length was asserted on the line
        // above, so there is nothing here that could be shorter than the cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertTrue(bytes4(reason) == LeakyBucketCapacityExceeded.selector, "not LeakyBucketCapacityExceeded");
        (bytes32 errCapacity, bytes32 errLevel, bytes32 errAmount) =
            abi.decode(sliceReason(reason), (bytes32, bytes32, bytes32));
        assertFloatEq(Float.wrap(errCapacity), capacity);
        assertFloatEq(Float.wrap(errLevel), level);
        assertFloatEq(Float.wrap(errAmount), amount);
    }
}
