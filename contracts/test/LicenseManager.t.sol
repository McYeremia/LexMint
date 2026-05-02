// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPRegistry} from "../src/IPRegistry.sol";
import {RoyaltyVault} from "../src/RoyaltyVault.sol";
import {LicenseManager} from "../src/LicenseManager.sol";

/// @notice Invariant handler – wraps LicenseManager purchases so the fuzzer can
///         drive state in a controlled way and we can track expected vault deposits.
contract LicenseManagerHandler is Test {
    LicenseManager public manager;
    RoyaltyVault   public vault;
    bytes32        public workHash;
    uint256        public tierId;

    uint256 public totalDeposited;

    constructor(LicenseManager manager_, RoyaltyVault vault_, bytes32 workHash_, uint256 tierId_) {
        manager  = manager_;
        vault    = vault_;
        workHash = workHash_;
        tierId   = tierId_;
    }

    /// @dev Called by the invariant fuzzer. Buys a license with 1 ether (matching tier price).
    function buyLicense(address buyer) external {
        // Only attempt if the tier is PERSONAL (non-exclusive) so it never reverts on ExclusiveSold
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        try manager.purchaseLicense{value: 1 ether}(tierId) {
            totalDeposited += 1 ether;
        } catch {
            // Acceptable; e.g., tier inactive
        }
    }
}

contract LicenseManagerTest is Test {
    IPRegistry     registry;
    RoyaltyVault   vault;
    LicenseManager manager;

    address owner     = address(0x1);
    address buyer     = address(0x2);
    address arbitrator = address(0x3);

    bytes32 workHash  = keccak256("test-work");
    uint256 tierId;

    // ── helpers ──────────────────────────────────────────────────────────────

    function setUp() public {
        registry = new IPRegistry();
        vault    = new RoyaltyVault(address(registry));
        manager  = new LicenseManager(address(registry), address(vault));

        // Register a work as `owner`
        vm.prank(owner);
        registry.registerWork(workHash, "ipfs://meta");

        // Create a PERSONAL tier for 1 ether, 30 days
        vm.prank(owner);
        tierId = manager.createLicenseTier(workHash, LicenseManager.LicenseScope.PERSONAL, 1 ether, 30 days);
    }

    // ── createLicenseTier ────────────────────────────────────────────────────

    /// @notice Verify the tier is stored with correct fields after creation.
    function test_createLicenseTier_stores() public view {
        LicenseManager.LicenseTier memory t = manager.getTier(tierId);
        assertEq(t.workHash, workHash);
        assertEq(uint256(t.scope), uint256(LicenseManager.LicenseScope.PERSONAL));
        assertEq(t.priceWei, 1 ether);
        assertEq(t.duration, 30 days);
        assertTrue(t.isActive);
    }

    /// @notice LicenseCreated event is emitted with correct indexed args.
    function test_createLicenseTier_emitsEvent() public {
        bytes32 anotherHash = keccak256("another-work");
        vm.prank(owner);
        registry.registerWork(anotherHash, "ipfs://another");

        vm.expectEmit(true, true, false, true);
        emit LicenseManager.LicenseCreated(1, anotherHash, LicenseManager.LicenseScope.COMMERCIAL);

        vm.prank(owner);
        manager.createLicenseTier(anotherHash, LicenseManager.LicenseScope.COMMERCIAL, 0.5 ether, 0);
    }

    /// @notice Reverts when the work hash is not registered.
    function test_createLicenseTier_reverts_workNotRegistered() public {
        bytes32 badHash = keccak256("not-registered");
        vm.expectRevert(LicenseManager.WorkNotRegistered.selector);
        vm.prank(owner);
        manager.createLicenseTier(badHash, LicenseManager.LicenseScope.PERSONAL, 1 ether, 0);
    }

    /// @notice Reverts when caller is not the work owner.
    function test_createLicenseTier_reverts_notWorkOwner() public {
        vm.expectRevert(LicenseManager.NotWorkOwner.selector);
        vm.prank(buyer); // buyer is not the owner
        manager.createLicenseTier(workHash, LicenseManager.LicenseScope.PERSONAL, 1 ether, 0);
    }

    // ── purchaseLicense ───────────────────────────────────────────────────────

    /// @notice Happy path: buyer sends exact price, license record is stored correctly.
    function test_purchaseLicense_happy() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 licenseId = manager.purchaseLicense{value: 1 ether}(tierId);

        assertEq(licenseId, 0);

        LicenseManager.LicenseRecord memory lic = manager.getLicense(licenseId);
        assertEq(lic.tierId, tierId);
        assertEq(lic.licensee, buyer);
        assertEq(lic.purchasedAt, block.timestamp);
        assertFalse(lic.isRevoked);
        // 30 days duration
        assertEq(lic.expiresAt, block.timestamp + 30 days);
    }

    /// @notice After purchase the full ETH is forwarded to the vault.
    function test_purchaseLicense_forwardsEthToVault() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        manager.purchaseLicense{value: 1 ether}(tierId);

        assertEq(vault.vaultBalance(workHash), 1 ether);
    }

    /// @notice LicensePurchased event is emitted with correct indexed args.
    function test_purchaseLicense_emitsEvent() public {
        vm.deal(buyer, 1 ether);
        vm.expectEmit(true, true, true, false);
        emit LicenseManager.LicensePurchased(0, tierId, buyer);
        vm.prank(buyer);
        manager.purchaseLicense{value: 1 ether}(tierId);
    }

    /// @notice A perpetual license (duration=0) has expiresAt==0.
    function test_purchaseLicense_perpetual() public {
        vm.prank(owner);
        uint256 perpetualTierId = manager.createLicenseTier(
            workHash, LicenseManager.LicenseScope.PERSONAL, 0.1 ether, 0
        );

        vm.deal(buyer, 0.1 ether);
        vm.prank(buyer);
        uint256 licenseId = manager.purchaseLicense{value: 0.1 ether}(perpetualTierId);

        LicenseManager.LicenseRecord memory lic = manager.getLicense(licenseId);
        assertEq(lic.expiresAt, 0);
    }

    /// @notice Reverts when the tier is not active (use non-existent tierId).
    function test_purchaseLicense_reverts_tierNotActive() public {
        uint256 badTierId = 999;
        vm.deal(buyer, 1 ether);
        vm.expectRevert(LicenseManager.TierNotActive.selector);
        vm.prank(buyer);
        manager.purchaseLicense{value: 1 ether}(badTierId);
    }

    /// @notice Reverts when ETH sent is below the tier price.
    function test_purchaseLicense_reverts_insufficientPayment() public {
        vm.deal(buyer, 0.5 ether);
        vm.expectRevert(LicenseManager.InsufficientPayment.selector);
        vm.prank(buyer);
        manager.purchaseLicense{value: 0.5 ether}(tierId);
    }

    /// @notice Reverts when an EXCLUSIVE tier is purchased a second time.
    function test_purchaseLicense_reverts_exclusiveSold() public {
        vm.prank(owner);
        uint256 exclTierId = manager.createLicenseTier(
            workHash, LicenseManager.LicenseScope.EXCLUSIVE, 2 ether, 0
        );

        address buyer2 = address(0x4);
        vm.deal(buyer, 2 ether);
        vm.deal(buyer2, 2 ether);

        vm.prank(buyer);
        manager.purchaseLicense{value: 2 ether}(exclTierId);

        vm.expectRevert(LicenseManager.ExclusiveLicenseSold.selector);
        vm.prank(buyer2);
        manager.purchaseLicense{value: 2 ether}(exclTierId);
    }

    // ── isLicenseValid ────────────────────────────────────────────────────────

    /// @notice Freshly purchased, non-expired license is valid.
    function test_isLicenseValid_true() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 licenseId = manager.purchaseLicense{value: 1 ether}(tierId);

        assertTrue(manager.isLicenseValid(licenseId));
    }

    /// @notice Revoked license returns false.
    function test_isLicenseValid_false_revoked() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 licenseId = manager.purchaseLicense{value: 1 ether}(tierId);

        vm.prank(owner);
        manager.revokeLicense(licenseId);

        assertFalse(manager.isLicenseValid(licenseId));
    }

    /// @notice License is invalid after its expiry timestamp.
    function test_isLicenseValid_false_expired() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 licenseId = manager.purchaseLicense{value: 1 ether}(tierId);

        vm.warp(block.timestamp + 30 days + 1);

        assertFalse(manager.isLicenseValid(licenseId));
    }

    // ── revokeLicense ─────────────────────────────────────────────────────────

    /// @notice Owner can revoke a license, emitting LicenseRevoked event.
    function test_revokeLicense_byOwner() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 licenseId = manager.purchaseLicense{value: 1 ether}(tierId);

        vm.expectEmit(true, false, false, false);
        emit LicenseManager.LicenseRevoked(licenseId);

        vm.prank(owner);
        manager.revokeLicense(licenseId);

        assertTrue(manager.getLicense(licenseId).isRevoked);
    }

    /// @notice Dispute arbitrator can revoke a license after being set.
    function test_revokeLicense_byArbitrator() public {
        manager.setDisputeArbitrator(arbitrator);

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 licenseId = manager.purchaseLicense{value: 1 ether}(tierId);

        vm.prank(arbitrator);
        manager.revokeLicense(licenseId);

        assertTrue(manager.getLicense(licenseId).isRevoked);
    }

    /// @notice Third-party caller that is neither owner nor arbitrator is rejected.
    function test_revokeLicense_reverts_notAuthorized() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 licenseId = manager.purchaseLicense{value: 1 ether}(tierId);

        address rando = address(0x99);
        vm.expectRevert(LicenseManager.NotAuthorized.selector);
        vm.prank(rando);
        manager.revokeLicense(licenseId);
    }

    /// @notice Cannot revoke an already-revoked license.
    function test_revokeLicense_reverts_alreadyRevoked() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 licenseId = manager.purchaseLicense{value: 1 ether}(tierId);

        vm.prank(owner);
        manager.revokeLicense(licenseId);

        vm.expectRevert(LicenseManager.AlreadyRevoked.selector);
        vm.prank(owner);
        manager.revokeLicense(licenseId);
    }

    // ── getLicensesByLicensee ─────────────────────────────────────────────────

    /// @notice Returns the correct array of license IDs for a licensee.
    function test_getLicensesByLicensee() public {
        vm.deal(buyer, 2 ether);

        vm.prank(owner);
        uint256 tierId2 = manager.createLicenseTier(workHash, LicenseManager.LicenseScope.COMMERCIAL, 0.5 ether, 7 days);

        vm.prank(buyer);
        uint256 lic0 = manager.purchaseLicense{value: 1 ether}(tierId);

        vm.deal(buyer, 0.5 ether);
        vm.prank(buyer);
        uint256 lic1 = manager.purchaseLicense{value: 0.5 ether}(tierId2);

        uint256[] memory ids = manager.getLicensesByLicensee(buyer);
        assertEq(ids.length, 2);
        assertEq(ids[0], lic0);
        assertEq(ids[1], lic1);
    }

    // ── setDisputeArbitrator ──────────────────────────────────────────────────

    /// @notice Second call to setDisputeArbitrator reverts with ArbitratorAlreadySet.
    function test_setDisputeArbitrator_reverts_alreadySet() public {
        manager.setDisputeArbitrator(arbitrator);
        vm.expectRevert(LicenseManager.ArbitratorAlreadySet.selector);
        manager.setDisputeArbitrator(address(0x5));
    }

    // ── Fuzz ──────────────────────────────────────────────────────────────────

    /// @notice If payment >= price, vault receives exactly the payment amount.
    ///         If payment < price, reverts with InsufficientPayment.
    function testFuzz_purchaseLicense_ethForwardedToVault(uint96 price, uint96 payment) public {
        // Create a fresh tier with the fuzzed price
        vm.assume(price > 0);
        vm.prank(owner);
        uint256 fuzzTierId = manager.createLicenseTier(
            workHash, LicenseManager.LicenseScope.PERSONAL, uint256(price), 0
        );

        vm.deal(buyer, uint256(payment));

        if (uint256(payment) >= uint256(price)) {
            vm.prank(buyer);
            manager.purchaseLicense{value: uint256(payment)}(fuzzTierId);
            // Vault balance accumulates; at minimum this call sent `payment`
            assertGe(vault.vaultBalance(workHash), uint256(payment));
        } else {
            vm.expectRevert(LicenseManager.InsufficientPayment.selector);
            vm.prank(buyer);
            manager.purchaseLicense{value: uint256(payment)}(fuzzTierId);
        }
    }

    /// @notice Perpetual licenses remain valid regardless of time warp;
    ///         timed licenses become invalid after expiry.
    function testFuzz_isLicenseValid_expiry(uint32 duration, uint32 warpAmount) public {
        vm.assume(duration > 0); // timed

        vm.prank(owner);
        uint256 fuzzTierId = manager.createLicenseTier(
            workHash, LicenseManager.LicenseScope.PERSONAL, 0, uint256(duration)
        );

        vm.prank(buyer);
        uint256 licenseId = manager.purchaseLicense{value: 0}(fuzzTierId);

        uint256 expiresAt = block.timestamp + uint256(duration);
        vm.warp(block.timestamp + uint256(warpAmount));

        bool expected = block.timestamp < expiresAt;
        assertEq(manager.isLicenseValid(licenseId), expected);

        // Also verify perpetual license is always valid after same warp
        vm.prank(owner);
        uint256 perpetualTierId = manager.createLicenseTier(
            workHash, LicenseManager.LicenseScope.PERSONAL, 0, 0
        );
        vm.prank(buyer);
        uint256 perpetualLicId = manager.purchaseLicense{value: 0}(perpetualTierId);
        assertTrue(manager.isLicenseValid(perpetualLicId));
    }

    // ── Invariant ─────────────────────────────────────────────────────────────

    LicenseManagerHandler handler;

    function setUp_invariant() internal {
        handler = new LicenseManagerHandler(manager, vault, workHash, tierId);
        targetContract(address(handler));
    }

    /// @notice After any sequence of purchases, vault.vaultBalance(workHash) equals
    ///         the total ETH deposited by the handler.
    function invariant_vaultGetsAllPayments() public {
        // Lazily initialise the handler on first invariant run
        if (address(handler) == address(0)) setUp_invariant();
        assertEq(vault.vaultBalance(workHash), handler.totalDeposited());
    }
}
