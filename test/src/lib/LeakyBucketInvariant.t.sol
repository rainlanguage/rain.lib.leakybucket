// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.2/src/Test.sol";
import {LeakyBucketMintCap} from "../../concrete/LeakyBucketMintCap.sol";
import {LeakyBucketHandler} from "../../concrete/LeakyBucketHandler.sol";
import {WORKED_CAPACITY, WORKED_LEAK_RATE} from "../../lib/WorkedPolicy.sol";

/// The one stateful invariant run in the suite.
///
/// Everything else here is a fuzz over a pure function, or a fuzz over a loop
/// of a fixed shape. Multi-call histories are the region a mutation ledger
/// structurally cannot reach — a mutant is killed or not by a single call's
/// result — and both adversarial findings this repo has already fixed were
/// write-path state-sequence bugs, so it is the region with the worst prior and
/// the least coverage. A handler composes mints, waits and policy changes in
/// orders the fixed loop in `LeakyBucketEmbedding.t.sol` cannot produce.
///
/// `fail-on-revert` is `true`, set inline so it is visible from the file it
/// governs and scoped to it. The issue this closes proposed `false`, which is
/// the Foundry default and is wrong here: forge-std 1.16.2 `assertEq`/`assertLe`
/// delegate to `vm.assertEq`, which REVERTS, so with `false` a failed assertion
/// inside the handler is discarded as "that call reverted, discard it and carry
/// on" and the run goes green. `true` is safe because `LeakyBucketHandler`
/// never reverts for any reason of its own; see the note on that contract.
contract LeakyBucketInvariantTest is Test {
    /// The worked policy the suite examines, from `test/lib/WorkedPolicy.sol`.
    uint256 internal constant CAPACITY = WORKED_CAPACITY;
    uint256 internal constant LEAK_RATE = WORKED_LEAK_RATE;

    address internal constant ALICE = address(uint160(uint256(keccak256("alice"))));

    LeakyBucketMintCap internal cap;
    LeakyBucketHandler internal handler;

    function setUp() external {
        vm.warp(1_700_000_000);
        cap = new LeakyBucketMintCap();
        cap.setPolicy(ALICE, CAPACITY, LEAK_RATE);
        handler = new LeakyBucketHandler(cap, ALICE, CAPACITY, LEAK_RATE);

        // The three selectors are named rather than left to the default, which
        // would be every external function on the target INCLUDING the ones
        // `Test` brings in by inheritance. Under `fail-on-revert = true` a
        // fuzzer call into one of those that reverted would fail the run for a
        // reason that has nothing to do with the bucket.
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = LeakyBucketHandler.mint.selector;
        selectors[1] = LeakyBucketHandler.wait.selector;
        selectors[2] = LeakyBucketHandler.setCapacity.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// No instant of any history offers more than the burst in force, and the
    /// burst in force is never more than the one the run started with.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_headroomNeverExceedsCapacity() external view {
        assertLe(cap.headroom(ALICE), handler.capacity());
        assertLe(cap.headroom(ALICE), CAPACITY);
    }

    /// Cumulative throughput is bounded by one burst plus the sustained rate
    /// over the elapsed window, however the calls are interleaved. The cap's
    /// own total and the handler's independently accumulated one must also
    /// agree, so a mint that landed without the handler seeing it, or the
    /// reverse, fails here.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_throughputIsBoundedByBurstPlusLeak() external view {
        assertEq(handler.minted(), cap.totalMinted());
        assertLe(handler.minted(), CAPACITY + (block.timestamp - handler.START()) * LEAK_RATE);
    }
}
