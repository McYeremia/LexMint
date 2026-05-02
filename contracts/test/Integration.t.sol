// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPRegistry} from "../src/IPRegistry.sol";
import {RoyaltyVault} from "../src/RoyaltyVault.sol";
import {LicenseManager} from "../src/LicenseManager.sol";
import {DisputeArbitrator} from "../src/DisputeArbitrator.sol";

contract IntegrationTest is Test {
    IPRegistry        registry;
    RoyaltyVault      vault;
    LicenseManager    manager;
    DisputeArbitrator arbitrator;

    address alice = makeAddr("alice"); // creator / work owner
    address bob   = makeAddr("bob");   // buyer / licensee
    address carol = makeAddr("carol"); // co-owner / second buyer

    // Shared work hash used across tests
    bytes32 constant WORK_HASH = keccak256("my-original-work");

    function setUp() public {
        registry   = new IPRegistry();
        vault      = new RoyaltyVault(address(registry));
        manager    = new LicenseManager(address(registry), address(vault));
        // address(this) becomes the arbiter of DisputeArbitrator
        arbitrator = new DisputeArbitrator(address(manager));
        manager.setDisputeArbitrator(address(arbitrator));

        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(carol, 10 ether);
    }

    // -------------------------------------------------------------------------
    // Scenario 1: Full Purchase Flow
    // alice registers → creates PERSONAL tier → bob buys →
    // vault credited → alice claims → balances correct
    // -------------------------------------------------------------------------
    function test_fullPurchaseFlow() public {
        // Alice registers work
        vm.prank(alice);
        registry.registerWork(WORK_HASH, "ipfs://metadata");

        // Alice creates a PERSONAL tier: 1 ether, 30 days
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            WORK_HASH,
            LicenseManager.LicenseScope.PERSONAL,
            1 ether,
            30 days
        );

        // Bob purchases the license
        vm.prank(bob);
        manager.purchaseLicense{value: 1 ether}(tierId);

        // Vault balance for work must equal 1 ether
        assertEq(vault.vaultBalance(WORK_HASH), 1 ether, "vault balance should be 1 ether");

        // Alice's accrued share (sole owner, 100%) must be 1 ether
        assertEq(vault.getAccrued(WORK_HASH, alice), 1 ether, "alice accrued should be 1 ether");

        // Alice claims royalty
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.claimRoyalty(WORK_HASH);

        // Accrued balance zeroed
        assertEq(vault.getAccrued(WORK_HASH, alice), 0, "alice accrued should be 0 after claim");

        // Alice's ETH balance increased by exactly 1 ether
        assertEq(alice.balance - aliceBefore, 1 ether, "alice should receive 1 ether");
    }

    // -------------------------------------------------------------------------
    // Scenario 2: Co-Owner Split Flow
    // alice registers → adds carol (30%) → creates tier → bob buys →
    // splits verified → carol claims 0.3 ether, alice claims 0.7 ether
    // -------------------------------------------------------------------------
    function test_coOwnerSplitFlow() public {
        // Alice registers work
        vm.prank(alice);
        registry.registerWork(WORK_HASH, "ipfs://metadata");

        // Alice adds carol as co-owner with 3000 bps (30%)
        vm.prank(alice);
        registry.addCoOwner(WORK_HASH, carol, 3000);

        // Alice creates a PERSONAL tier: 1 ether, perpetual
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            WORK_HASH,
            LicenseManager.LicenseScope.PERSONAL,
            1 ether,
            0 // perpetual
        );

        // Bob purchases the license
        vm.prank(bob);
        manager.purchaseLicense{value: 1 ether}(tierId);

        // Carol should have 30% = 0.3 ether
        assertEq(vault.getAccrued(WORK_HASH, carol), 0.3 ether, "carol accrued should be 0.3 ether");

        // Alice should have 70% = 0.7 ether (remainder after co-owner share)
        assertEq(vault.getAccrued(WORK_HASH, alice), 0.7 ether, "alice accrued should be 0.7 ether");

        // Carol claims her share
        uint256 carolBefore = carol.balance;
        vm.prank(carol);
        vault.claimRoyalty(WORK_HASH);
        assertEq(carol.balance - carolBefore, 0.3 ether, "carol should receive 0.3 ether");

        // Alice claims her share
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vault.claimRoyalty(WORK_HASH);
        assertEq(alice.balance - aliceBefore, 0.7 ether, "alice should receive 0.7 ether");
    }

    // -------------------------------------------------------------------------
    // Scenario 3: Full Dispute Flow
    // alice registers → creates tier → bob buys → bob raises dispute →
    // evidence submitted → warp past evidence period → arbiter resolves →
    // warp past timelock → execute → license revoked
    // -------------------------------------------------------------------------
    function test_fullDisputeFlow() public {
        // Alice registers work
        vm.prank(alice);
        registry.registerWork(WORK_HASH, "ipfs://metadata");

        // Alice creates a PERSONAL tier: 1 ether
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            WORK_HASH,
            LicenseManager.LicenseScope.PERSONAL,
            1 ether,
            0 // perpetual
        );

        // Bob purchases license
        vm.prank(bob);
        uint256 licenseId = manager.purchaseLicense{value: 1 ether}(tierId);

        // License is valid at this point
        assertTrue(manager.isLicenseValid(licenseId), "license should be valid before dispute");

        // Bob raises dispute
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        // Bob submits plaintiff evidence
        vm.prank(bob);
        arbitrator.submitEvidence(disputeId, "ipfs://plaintiff");

        // Alice submits defendant evidence (any non-plaintiff caller is treated as defendant)
        vm.prank(alice);
        arbitrator.submitEvidence(disputeId, "ipfs://defendant");

        // Warp past the 72-hour evidence period
        vm.warp(block.timestamp + 73 hours);

        // Arbiter (address(this)) resolves dispute ruling for plaintiff
        arbitrator.resolveDispute(disputeId, true);

        // Warp past the 48-hour timelock
        vm.warp(block.timestamp + 49 hours);

        // Anyone executes the resolution
        arbitrator.executeResolution(disputeId);

        // License must now be revoked / invalid
        assertFalse(manager.isLicenseValid(licenseId), "license should be invalid after resolution executed");
    }

    // -------------------------------------------------------------------------
    // Scenario 4: Exclusive License Guard
    // alice registers → creates EXCLUSIVE tier → bob buys successfully →
    // carol tries to buy same tier → revert ExclusiveLicenseSold
    // -------------------------------------------------------------------------
    function test_exclusiveLicenseGuard() public {
        // Alice registers work
        vm.prank(alice);
        registry.registerWork(WORK_HASH, "ipfs://metadata");

        // Alice creates an EXCLUSIVE tier: 1 ether, perpetual
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            WORK_HASH,
            LicenseManager.LicenseScope.EXCLUSIVE,
            1 ether,
            0 // perpetual
        );

        // Bob purchases the exclusive license successfully
        vm.prank(bob);
        manager.purchaseLicense{value: 1 ether}(tierId);

        // Carol attempts to purchase the same exclusive tier — must revert
        vm.expectRevert(LicenseManager.ExclusiveLicenseSold.selector);
        vm.prank(carol);
        manager.purchaseLicense{value: 1 ether}(tierId);
    }
}
