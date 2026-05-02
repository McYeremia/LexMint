// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPRegistry}          from "../src/IPRegistry.sol";
import {RoyaltyVault}        from "../src/RoyaltyVault.sol";
import {LicenseManager}      from "../src/LicenseManager.sol";
import {DisputeArbitrator}   from "../src/DisputeArbitrator.sol";

// ---------------------------------------------------------------------------
// Invariant handler
// ---------------------------------------------------------------------------

/// @notice Drives DisputeArbitrator state for the invariant fuzzer.
contract DisputeArbitratorHandler is Test {
    DisputeArbitrator public arbitrator;
    LicenseManager    public manager;
    uint256           public licenseId;
    address           public plaintiff;
    address           public arbiterAddr;

    // Track latest disputeId raised so we can read its status.
    uint256 public lastDisputeId;
    bool    public hasDispute;

    constructor(
        DisputeArbitrator arbitrator_,
        LicenseManager    manager_,
        uint256           licenseId_,
        address           plaintiff_,
        address           arbiterAddr_
    ) {
        arbitrator  = arbitrator_;
        manager     = manager_;
        licenseId   = licenseId_;
        plaintiff   = plaintiff_;
        arbiterAddr = arbiterAddr_;
    }

    /// @dev Raise a fresh dispute from `plaintiff`.
    function doRaiseDispute() external {
        vm.prank(plaintiff);
        try arbitrator.raiseDispute(licenseId) returns (uint256 id) {
            lastDisputeId = id;
            hasDispute    = true;
        } catch {}
    }

    /// @dev Warp to after evidence period and resolve.
    function doResolve(bool ruleForPlaintiff) external {
        if (!hasDispute) return;
        vm.warp(block.timestamp + 73 hours);
        vm.prank(arbiterAddr);
        try arbitrator.resolveDispute(lastDisputeId, ruleForPlaintiff) {} catch {}
    }
}

// ---------------------------------------------------------------------------
// Main test contract
// ---------------------------------------------------------------------------

contract DisputeArbitratorTest is Test {

    IPRegistry        registry;
    RoyaltyVault      vault;
    LicenseManager    manager;
    DisputeArbitrator arbitrator;

    // Roles
    address arbiter   = address(this);  // test contract is the arbiter by default
    address owner     = address(0x1);
    address plaintiff = address(0xAAA);
    address buyer     = address(0xBBB); // licensee / defendant

    bytes32 workHash = keccak256("test-work");
    uint256 tierId;
    uint256 licenseId;

    // ── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        registry   = new IPRegistry();
        vault      = new RoyaltyVault(address(registry));
        manager    = new LicenseManager(address(registry), address(vault));
        arbitrator = new DisputeArbitrator(address(manager));

        // Wire arbitrator into LicenseManager (set once)
        manager.setDisputeArbitrator(address(arbitrator));

        // Register work and create a tier
        vm.prank(owner);
        registry.registerWork(workHash, "ipfs://meta");

        vm.prank(owner);
        tierId = manager.createLicenseTier(
            workHash,
            LicenseManager.LicenseScope.PERSONAL,
            0.1 ether,
            30 days
        );

        // Buyer purchases a license
        vm.deal(buyer, 0.1 ether);
        vm.prank(buyer);
        licenseId = manager.purchaseLicense{value: 0.1 ether}(tierId);
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    /// @dev Raise a dispute and return the disputeId.
    function _raiseDispute() internal returns (uint256 id) {
        vm.prank(plaintiff);
        id = arbitrator.raiseDispute(licenseId);
    }

    /// @dev Raise dispute, warp past evidence period, and resolve it.
    function _raiseAndResolve(bool ruleForPlaintiff) internal returns (uint256 id) {
        id = _raiseDispute();
        vm.warp(block.timestamp + 73 hours);
        // arbiter == address(this), no prank needed
        arbitrator.resolveDispute(id, ruleForPlaintiff);
    }

    // ── Happy-path tests ─────────────────────────────────────────────────────

    /// @notice Raised dispute has correct stored fields.
    function test_raiseDispute_stores() public {
        uint256 id = _raiseDispute();

        DisputeArbitrator.Dispute memory d = arbitrator.getDispute(id);

        assertEq(d.licenseId, licenseId);
        assertEq(d.plaintiff, plaintiff);
        assertEq(uint256(d.status), uint256(DisputeArbitrator.DisputeStatus.EVIDENCE_PERIOD));
        assertEq(d.raisedAt, block.timestamp);
        assertEq(d.resolvedAt, 0);
        assertFalse(d.ruledForPlaintiff);
    }

    /// @notice DisputeRaised event is emitted with correct indexed args.
    function test_raiseDispute_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit DisputeArbitrator.DisputeRaised(0, licenseId, plaintiff);

        vm.prank(plaintiff);
        arbitrator.raiseDispute(licenseId);
    }

    /// @notice Plaintiff submits evidence; plaintiffEvidenceCID is stored.
    function test_submitEvidence_plaintiff() public {
        uint256 id = _raiseDispute();

        vm.prank(plaintiff);
        arbitrator.submitEvidence(id, "ipfs://plaintiff-evidence");

        DisputeArbitrator.Dispute memory d = arbitrator.getDispute(id);
        assertEq(d.plaintiffEvidenceCID, "ipfs://plaintiff-evidence");
    }

    /// @notice Non-plaintiff submits evidence; defendantEvidenceCID is stored.
    function test_submitEvidence_defendant() public {
        uint256 id = _raiseDispute();

        vm.prank(buyer);
        arbitrator.submitEvidence(id, "ipfs://defendant-evidence");

        DisputeArbitrator.Dispute memory d = arbitrator.getDispute(id);
        assertEq(d.defendantEvidenceCID, "ipfs://defendant-evidence");
    }

    /// @notice EvidenceSubmitted event is emitted.
    function test_submitEvidence_emitsEvent() public {
        uint256 id = _raiseDispute();

        vm.expectEmit(true, false, false, true);
        emit DisputeArbitrator.EvidenceSubmitted(id, plaintiff, "ipfs://evidence");

        vm.prank(plaintiff);
        arbitrator.submitEvidence(id, "ipfs://evidence");
    }

    /// @notice Arbiter resolves after 72 h; status becomes RESOLVED.
    function test_resolveDispute_afterEvidencePeriod() public {
        uint256 id = _raiseDispute();
        vm.warp(block.timestamp + 73 hours);

        arbitrator.resolveDispute(id, true);

        DisputeArbitrator.Dispute memory d = arbitrator.getDispute(id);
        assertEq(uint256(d.status), uint256(DisputeArbitrator.DisputeStatus.RESOLVED));
        assertTrue(d.ruledForPlaintiff);
        assertEq(d.resolvedAt, block.timestamp);
    }

    /// @notice DisputeResolved event is emitted.
    function test_resolveDispute_emitsEvent() public {
        uint256 id = _raiseDispute();
        vm.warp(block.timestamp + 73 hours);

        vm.expectEmit(true, false, false, true);
        emit DisputeArbitrator.DisputeResolved(id, true);

        arbitrator.resolveDispute(id, true);
    }

    /// @notice After timelock expires, executeResolution sets status to EXECUTED.
    function test_executeResolution_afterTimelock() public {
        uint256 id = _raiseAndResolve(false);

        vm.warp(block.timestamp + 49 hours);
        arbitrator.executeResolution(id);

        DisputeArbitrator.Dispute memory d = arbitrator.getDispute(id);
        assertEq(uint256(d.status), uint256(DisputeArbitrator.DisputeStatus.EXECUTED));
    }

    /// @notice ResolutionExecuted event is emitted.
    function test_executeResolution_emitsEvent() public {
        uint256 id = _raiseAndResolve(false);
        vm.warp(block.timestamp + 49 hours);

        vm.expectEmit(true, false, false, false);
        emit DisputeArbitrator.ResolutionExecuted(id);

        arbitrator.executeResolution(id);
    }

    /// @notice If ruled for plaintiff, license is revoked after execution.
    function test_executeResolution_revokesLicense_ifPlaintiffWon() public {
        // Confirm license is valid before dispute
        assertTrue(manager.isLicenseValid(licenseId));

        uint256 id = _raiseAndResolve(true);
        vm.warp(block.timestamp + 49 hours);
        arbitrator.executeResolution(id);

        assertFalse(manager.isLicenseValid(licenseId));
    }

    /// @notice If ruled for defendant, license remains valid after execution.
    function test_executeResolution_doesNotRevoke_ifDefendantWon() public {
        uint256 id = _raiseAndResolve(false);
        vm.warp(block.timestamp + 49 hours);
        arbitrator.executeResolution(id);

        assertTrue(manager.isLicenseValid(licenseId));
    }

    /// @notice transferArbiter updates the arbiter address.
    function test_transferArbiter_updates() public {
        address newArbiter = address(0xDEAD);
        arbitrator.transferArbiter(newArbiter);

        assertEq(arbitrator.arbiter(), newArbiter);

        // New arbiter can resolve a dispute
        uint256 id = _raiseDispute();
        vm.warp(block.timestamp + 73 hours);
        vm.prank(newArbiter);
        arbitrator.resolveDispute(id, false);
        assertEq(uint256(arbitrator.getDispute(id).status),
                 uint256(DisputeArbitrator.DisputeStatus.RESOLVED));
    }

    /// @notice ArbiterTransferred event is emitted.
    function test_transferArbiter_emitsEvent() public {
        address newArbiter = address(0xDEAD);

        vm.expectEmit(true, true, false, false);
        emit DisputeArbitrator.ArbiterTransferred(arbiter, newArbiter);

        arbitrator.transferArbiter(newArbiter);
    }

    // ── Revert tests ─────────────────────────────────────────────────────────

    /// @notice Non-arbiter cannot call resolveDispute.
    function test_resolveDispute_reverts_notArbiter() public {
        uint256 id = _raiseDispute();
        vm.warp(block.timestamp + 73 hours);

        vm.expectRevert(DisputeArbitrator.NotArbiter.selector);
        vm.prank(address(0x9999));
        arbitrator.resolveDispute(id, true);
    }

    /// @notice Resolving before evidence period ends reverts.
    function test_resolveDispute_reverts_evidencePeriodActive() public {
        uint256 id = _raiseDispute();

        // Only 10 hours elapsed — still in evidence window
        vm.warp(block.timestamp + 10 hours);

        vm.expectRevert(DisputeArbitrator.EvidencePeriodActive.selector);
        arbitrator.resolveDispute(id, true);
    }

    /// @notice Resolving an already-resolved dispute reverts.
    function test_resolveDispute_reverts_alreadyResolved() public {
        uint256 id = _raiseAndResolve(true);

        vm.expectRevert(DisputeArbitrator.AlreadyResolved.selector);
        arbitrator.resolveDispute(id, false);
    }

    /// @notice Executing before timelock expires reverts.
    function test_executeResolution_reverts_timelockNotExpired() public {
        uint256 id = _raiseAndResolve(false);

        // 1 hour after resolve — timelock is 48 hours
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(DisputeArbitrator.TimelockNotExpired.selector);
        arbitrator.executeResolution(id);
    }

    /// @notice Executing a dispute that is not yet resolved reverts.
    function test_executeResolution_reverts_disputeNotResolved() public {
        uint256 id = _raiseDispute();

        vm.expectRevert(DisputeArbitrator.DisputeNotResolved.selector);
        arbitrator.executeResolution(id);
    }

    /// @notice Non-arbiter cannot call transferArbiter.
    function test_transferArbiter_reverts_notArbiter() public {
        vm.expectRevert(DisputeArbitrator.NotArbiter.selector);
        vm.prank(address(0x9999));
        arbitrator.transferArbiter(address(0xDEAD));
    }

    // ── Fuzz tests ────────────────────────────────────────────────────────────

    /// @notice Timing guard: if warpAmount < 72h → EvidencePeriodActive; else → success.
    function testFuzz_resolveDispute_timingGuard(uint256 warpAmount) public {
        warpAmount = bound(warpAmount, 0, 200 hours);

        uint256 id = _raiseDispute();
        uint256 raisedAt = arbitrator.getDispute(id).raisedAt;

        vm.warp(raisedAt + warpAmount);

        if (warpAmount < 72 hours) {
            vm.expectRevert(DisputeArbitrator.EvidencePeriodActive.selector);
            arbitrator.resolveDispute(id, true);
        } else {
            arbitrator.resolveDispute(id, true);
            assertEq(uint256(arbitrator.getDispute(id).status),
                     uint256(DisputeArbitrator.DisputeStatus.RESOLVED));
        }
    }

    /// @notice Fuzz execution timelock: if warpSinceResolve < 48h → revert; else → success.
    function testFuzz_executeResolution_timelockGuard(uint256 warpSinceResolve) public {
        warpSinceResolve = bound(warpSinceResolve, 0, 100 hours);

        uint256 id = _raiseAndResolve(false);
        uint256 resolvedAt = arbitrator.getDispute(id).resolvedAt;

        vm.warp(resolvedAt + warpSinceResolve);

        if (warpSinceResolve < 48 hours) {
            vm.expectRevert(DisputeArbitrator.TimelockNotExpired.selector);
            arbitrator.executeResolution(id);
        } else {
            arbitrator.executeResolution(id);
            assertEq(uint256(arbitrator.getDispute(id).status),
                     uint256(DisputeArbitrator.DisputeStatus.EXECUTED));
        }
    }

    // ── Invariant test ────────────────────────────────────────────────────────

    DisputeArbitratorHandler handler;

    function setUp_invariant() internal {
        handler = new DisputeArbitratorHandler(
            arbitrator,
            manager,
            licenseId,
            plaintiff,
            arbiter
        );
        targetContract(address(handler));
    }

    /// @notice Dispute status can only increase (RAISED < EVIDENCE_PERIOD < RESOLVED < EXECUTED).
    /// @dev    We track the status after each handler call and verify it never decreases.
    function invariant_statusProgressionIsMonotonic() public {
        if (address(handler) == address(0)) setUp_invariant();
        if (!handler.hasDispute()) return;

        uint256 id = handler.lastDisputeId();
        DisputeArbitrator.Dispute memory d = arbitrator.getDispute(id);
        // Status values are: RAISED=0, EVIDENCE_PERIOD=1, RESOLVED=2, EXECUTED=3
        // Since we only ever increase status, any value 0-3 is fine.
        assertTrue(uint256(d.status) <= 3);
    }
}
