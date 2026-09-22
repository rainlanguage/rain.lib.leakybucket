// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {LibLeakyBucket, LeakyBucket, LeakyBucketCapacityOverflow} from "../../src/lib/LibLeakyBucket.sol";

/// @title LeakyBucketMintCap
/// @notice A test harness, not a deliverable. It exists to hold the embedding
/// pattern still so the integration and invariant tests can point at something
/// real, and to demonstrate that the library constrains none of the
/// surrounding design. It deliberately ships nowhere: `src` is the whole
/// package.
///
/// The shape it demonstrates:
///
/// - One `LeakyBucket` per minter, in a mapping the concrete owns. The library
///   never sees the mapping and does not know there is one; it is handed one
///   bucket at a time.
/// - The policy pair lives in the bucket, so different minters run different
///   caps. Where the pair is written from is entirely the concrete's business.
/// - `setPolicy` stands in for governance. A real deployment puts a timelock,
///   a staged upgrade, a role check or a governor behind this function. The
///   library imposes no ordering, no delay and no authority model, which is
///   exactly why it can sit under any of them.
contract LeakyBucketMintCap {
    /// One bucket per minter. An untouched mapping entry is a zero struct: an
    /// empty bucket checkpointed at the epoch with a zero capacity, so an
    /// unconfigured minter can mint nothing. No initialization step is needed
    /// or wanted.
    mapping(address minter => LeakyBucket bucket) internal sBuckets;

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
    ///
    /// The checkpoint is left alone. The policy is what changed; the bucket's
    /// history did not, and rewriting the checkpoint here would be the full
    /// refund the library warns about.
    function setPolicy(address minter, uint256 capacity, uint256 leakRate) external {
        if (capacity > LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX) {
            revert LeakyBucketCapacityOverflow(capacity);
        }
        LeakyBucket storage bucket = sBuckets[minter];
        bucket.capacity = capacity;
        bucket.leakRate = leakRate;
    }

    /// The whole enforcement path: load the minter's bucket, hand it to `fill`,
    /// store the checkpoint it returns. That word carries the new level and
    /// `block.timestamp` together, so there is no second write to forget.
    function mint(uint256 amount) external {
        sBuckets[msg.sender].checkpoint = LibLeakyBucket.fill(sBuckets[msg.sender], block.timestamp, amount);
        totalMinted += amount;
    }

    /// What a minter could mint right now.
    function headroom(address minter) external view returns (uint256) {
        return LibLeakyBucket.headroomAt(sBuckets[minter], block.timestamp);
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
    /// `headroomAt` reads the capacity from the bucket it is given, so asking
    /// at a different capacity is asking of a different bucket: the minter's
    /// checkpoint and rate, in memory, with that capacity.
    ///
    /// Note that `headroom` above is NOT this quantity subtracted from the
    /// capacity: after a capacity cut the level can stand above the capacity,
    /// where the headroom saturates at zero and the level does not.
    function level(address minter) external view returns (uint256) {
        LeakyBucket memory bucket = sBuckets[minter];
        bucket.capacity = LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX;
        return LibLeakyBucket.LEAKY_BUCKET_LEVEL_MAX - LibLeakyBucket.headroomAt(bucket, block.timestamp);
    }
}
