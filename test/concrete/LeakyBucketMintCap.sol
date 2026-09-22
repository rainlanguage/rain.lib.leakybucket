// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {LibLeakyBucket, LeakyBucketCapacityOverflow} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketMintCap
/// @notice A test harness, not a deliverable. It exists to hold the embedding
/// pattern still so the integration and invariant tests can point at something
/// real, and to demonstrate that the library constrains none of the
/// surrounding design. It deliberately ships nowhere: `src` is the whole
/// package.
///
/// The shape it demonstrates:
///
/// - One packed word of bucket state per minter, in a mapping the concrete
///   owns. The library never sees the mapping and does not know there is one.
/// - A policy pair per minter, so different minters run different caps. The
///   library takes `capacity` and `leakRate` as arguments on every call, so
///   where they come from is entirely the concrete's business.
/// - `setPolicy` stands in for governance. A real deployment puts a timelock,
///   a staged upgrade, a role check or a governor behind this function. The
///   library imposes no ordering, no delay and no authority model, which is
///   exactly why it can sit under any of them.
contract LeakyBucketMintCap {
    /// Packed `(level, checkpoint)` per minter. A zero word, which is what an
    /// untouched mapping entry reads as, is an empty bucket checkpointed at the
    /// epoch. No initialization step is needed or wanted.
    mapping(address minter => uint256 checkpoint) internal sBuckets;

    /// Per minter burst allowance.
    mapping(address minter => uint256 capacity) internal sCapacity;

    /// Per minter sustained rate, in units per second.
    mapping(address minter => uint256 leakRate) internal sLeakRate;

    /// Total minted, standing in for an ERC20 balance.
    uint256 public totalMinted;

    /// Where governance goes. Left open here because the library has no opinion
    /// about it and the tests need to move the policy around freely.
    ///
    /// The bound on `capacity` is the one thing a setter owes the library, and
    /// it is written out here rather than called, because the library exports
    /// the bound and not a checker for it. A capacity wider than the packed
    /// level field is a cap that cannot be enforced, `fill` refuses it too, and
    /// this is the only place it can be refused rather than merely detected:
    /// refusing it here is what turns "the mint reverted" into "the policy was
    /// never settable". Raising the library's own error keeps one identity for
    /// the condition, whichever end of the system catches it.
    function setPolicy(address minter, uint256 capacity, uint256 leakRate) external {
        if (capacity > LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX) {
            revert LeakyBucketCapacityOverflow(capacity);
        }
        sCapacity[minter] = capacity;
        sLeakRate[minter] = leakRate;
    }

    /// The whole enforcement path: one `SLOAD`, the library call, one `SSTORE`.
    /// The returned word carries the new level and `block.timestamp` together,
    /// so there is no second write to forget.
    function mint(uint256 amount) external {
        sBuckets[msg.sender] = LibLeakyBucket.fill(
            sBuckets[msg.sender], block.timestamp, sCapacity[msg.sender], sLeakRate[msg.sender], amount
        );
        totalMinted += amount;
    }

    /// What a minter could mint right now.
    function headroom(address minter) external view returns (uint256) {
        return LibLeakyBucket.headroomAt(sBuckets[minter], block.timestamp, sCapacity[minter], sLeakRate[minter]);
    }

    /// The outstanding level against a minter's cap right now.
    ///
    /// Derived rather than read, because the library exports no `levelAt` and
    /// does not need to. Asking for the headroom against the widest capacity
    /// the library can enforce gives `LEAKY_BUCKET_LEVEL_MAX - level`, exactly:
    /// a stored level can never exceed that bound, so the saturation never
    /// bites and the subtraction below inverts it. It is the whole of why
    /// `levelAt` is not surface — a caller that wants the level already holds
    /// everything needed to compute it.
    ///
    /// Note that `headroom` above is NOT this quantity subtracted from the
    /// capacity: after a capacity cut the level can stand above the capacity,
    /// where the headroom saturates at zero and the level does not.
    function level(address minter) external view returns (uint256) {
        return LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX
            - LibLeakyBucket.headroomAt(
            sBuckets[minter], block.timestamp, LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX, sLeakRate[minter]
        );
    }
}
