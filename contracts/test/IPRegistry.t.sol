// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPRegistry} from "../src/IPRegistry.sol";

contract IPRegistryTest is Test {
    IPRegistry registry;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");

    bytes32 constant FILE_HASH = keccak256("test_file");
    string  constant METADATA  = "ipfs://QmTest";

    function setUp() public {
        registry = new IPRegistry();
    }

    // ── registerWork ──────────────────────────────────────────────────────────

    function test_registerWork_storesRecord() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, METADATA);

        IPRegistry.WorkRecord memory r = registry.verifyWork(FILE_HASH);
        assertEq(r.owner, alice);
        assertEq(r.fileHash, FILE_HASH);
        assertEq(r.metadataURI, METADATA);
        assertEq(r.registeredAt, block.timestamp);
        assertTrue(r.exists);
        assertEq(r.coOwners.length, 0);
        assertEq(r.splits.length, 0);
    }

    function test_registerWork_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IPRegistry.WorkRegistered(FILE_HASH, alice, METADATA);
        vm.prank(alice);
        registry.registerWork(FILE_HASH, METADATA);
    }

    function test_registerWork_addsToOwnerIndex() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, METADATA);

        bytes32[] memory works = registry.getWorksByOwner(alice);
        assertEq(works.length, 1);
        assertEq(works[0], FILE_HASH);
    }

    function test_registerWork_reverts_alreadyRegistered() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, METADATA);

        vm.expectRevert(IPRegistry.AlreadyRegistered.selector);
        vm.prank(bob);
        registry.registerWork(FILE_HASH, METADATA);
    }

    // ── transferOwnership ─────────────────────────────────────────────────────

    function test_transferOwnership_updatesOwner() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, METADATA);

        vm.expectEmit(true, true, true, false);
        emit IPRegistry.OwnershipTransferred(FILE_HASH, alice, bob);

        vm.prank(alice);
        registry.transferOwnership(FILE_HASH, bob);

        assertEq(registry.verifyWork(FILE_HASH).owner, bob);
    }

    function test_transferOwnership_reverts_notOwner() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, METADATA);

        vm.expectRevert(IPRegistry.NotOwner.selector);
        vm.prank(bob);
        registry.transferOwnership(FILE_HASH, bob);
    }

    // ── addCoOwner ────────────────────────────────────────────────────────────

    function test_addCoOwner_appendsEntry() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, METADATA);

        vm.expectEmit(true, false, false, true);
        emit IPRegistry.CoOwnerAdded(FILE_HASH, bob, 3000);

        vm.prank(alice);
        registry.addCoOwner(FILE_HASH, bob, 3000);

        IPRegistry.WorkRecord memory r = registry.verifyWork(FILE_HASH);
        assertEq(r.coOwners.length, 1);
        assertEq(r.coOwners[0], bob);
        assertEq(r.splits[0], 3000);
    }

    function test_addCoOwner_reverts_notOwner() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, METADATA);

        vm.expectRevert(IPRegistry.NotOwner.selector);
        vm.prank(bob);
        registry.addCoOwner(FILE_HASH, bob, 3000);
    }

    function test_addCoOwner_reverts_invalidSplit() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, METADATA);

        vm.prank(alice);
        registry.addCoOwner(FILE_HASH, bob, 6000);

        // 6000 + 5000 = 11000 > 10000
        vm.expectRevert(IPRegistry.InvalidSplit.selector);
        vm.prank(alice);
        registry.addCoOwner(FILE_HASH, carol, 5000);
    }

    // ── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_registerWork_noDuplicatesForDifferentHashes(bytes32 h1, bytes32 h2) public {
        vm.assume(h1 != h2);
        vm.assume(h1 != bytes32(0) && h2 != bytes32(0));

        vm.startPrank(alice);
        registry.registerWork(h1, METADATA);
        registry.registerWork(h2, METADATA);
        vm.stopPrank();

        assertTrue(registry.verifyWork(h1).exists);
        assertTrue(registry.verifyWork(h2).exists);
        assertEq(registry.getWorksByOwner(alice).length, 2);
    }

    function testFuzz_addCoOwner_totalSplitNeverExceeds10000(uint256 s1, uint256 s2) public {
        s1 = bound(s1, 1, 5000);
        s2 = bound(s2, 1, 10000 - s1);

        vm.prank(alice);
        registry.registerWork(FILE_HASH, METADATA);

        vm.startPrank(alice);
        registry.addCoOwner(FILE_HASH, bob,   s1);
        registry.addCoOwner(FILE_HASH, carol, s2);
        vm.stopPrank();

        IPRegistry.WorkRecord memory r = registry.verifyWork(FILE_HASH);
        uint256 total;
        for (uint256 i = 0; i < r.splits.length; i++) total += r.splits[i];
        assertLe(total, 10000);
    }

    // ── Invariant ─────────────────────────────────────────────────────────────

    function invariant_unregisteredHashReturnsFalse() public view {
        assertFalse(registry.verifyWork(bytes32(0)).exists);
    }
}
