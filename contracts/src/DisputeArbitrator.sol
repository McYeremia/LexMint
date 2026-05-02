// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ---------------------------------------------------------------------------
// Minimal interface — only the surface DisputeArbitrator needs from LicenseManager
// ---------------------------------------------------------------------------

interface ILicenseManager {
    function revokeLicense(uint256 licenseId) external;
    function isLicenseValid(uint256 licenseId) external view returns (bool);
}

// ---------------------------------------------------------------------------
// DisputeArbitrator
// ---------------------------------------------------------------------------

/// @title  DisputeArbitrator
/// @notice On-chain dispute resolution for LexMint IP licenses. A designated
///         arbiter can resolve disputes after a mandatory evidence period and
///         revoke the contested license after a timelock if the plaintiff wins.
contract DisputeArbitrator {

    // ── Types ────────────────────────────────────────────────────────────────

    /// @notice Lifecycle stages of a dispute.
    enum DisputeStatus { RAISED, EVIDENCE_PERIOD, RESOLVED, EXECUTED }

    /// @notice Full record for a single dispute.
    struct Dispute {
        uint256       licenseId;
        address       plaintiff;
        address       defendant;
        string        plaintiffEvidenceCID;
        string        defendantEvidenceCID;
        DisputeStatus status;
        bool          ruledForPlaintiff;
        uint256       raisedAt;
        uint256       resolvedAt;
    }

    // ── Constants ────────────────────────────────────────────────────────────

    /// @notice Minimum time parties have to submit evidence before arbiter can rule.
    uint256 public constant EVIDENCE_PERIOD = 72 hours;

    /// @notice Cooling-off window between resolution and execution.
    uint256 public constant TIMELOCK = 48 hours;

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotArbiter();
    error EvidencePeriodActive();
    error TimelockNotExpired();
    error AlreadyResolved();
    error NotPartyToDispute();
    error DisputeNotResolved();

    // ── Events ───────────────────────────────────────────────────────────────

    event DisputeRaised(uint256 indexed disputeId, uint256 indexed licenseId, address plaintiff);
    event EvidenceSubmitted(uint256 indexed disputeId, address submitter, string ipfsCID);
    event DisputeResolved(uint256 indexed disputeId, bool ruledForPlaintiff);
    event ResolutionExecuted(uint256 indexed disputeId);
    event ArbiterTransferred(address indexed oldArbiter, address indexed newArbiter);

    // ── State ────────────────────────────────────────────────────────────────

    /// @notice The address authorised to rule on disputes.
    address public arbiter;

    ILicenseManager private immutable _licenseManager;

    /// @dev Array index == disputeId.
    Dispute[] private _disputes;

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert NotArbiter();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    /// @param licenseManager_ Address of the deployed LicenseManager contract
    constructor(address licenseManager_) {
        _licenseManager = ILicenseManager(licenseManager_);
        arbiter = msg.sender;
    }

    // ── External — state-changing ────────────────────────────────────────────

    /// @notice Open a new dispute against a license. Goes straight to the evidence period.
    /// @param  licenseId The ID of the license being contested
    /// @return disputeId The index of the newly created dispute
    function raiseDispute(uint256 licenseId) external returns (uint256 disputeId) {
        // plaintiff = caller; defendant = address(0) (resolved off-chain or via evidence)
        disputeId = _disputes.length;

        _disputes.push(Dispute({
            licenseId:            licenseId,
            plaintiff:            msg.sender,
            defendant:            address(0),
            plaintiffEvidenceCID: "",
            defendantEvidenceCID: "",
            status:               DisputeStatus.EVIDENCE_PERIOD,
            ruledForPlaintiff:    false,
            raisedAt:             block.timestamp,
            resolvedAt:           0
        }));

        emit DisputeRaised(disputeId, licenseId, msg.sender);
    }

    /// @notice Submit evidence for an open dispute.
    /// @dev    Plaintiff's call updates plaintiffEvidenceCID; any other caller
    ///         updates defendantEvidenceCID (overwriting is allowed).
    /// @param  disputeId The ID of the dispute
    /// @param  ipfsCID   IPFS content identifier for the evidence
    function submitEvidence(uint256 disputeId, string calldata ipfsCID) external {
        Dispute storage d = _disputes[disputeId];

        // Evidence can only be added while the dispute is open
        if (d.status != DisputeStatus.EVIDENCE_PERIOD) revert AlreadyResolved();

        if (msg.sender == d.plaintiff) {
            d.plaintiffEvidenceCID = ipfsCID;
        } else {
            // Any non-plaintiff may submit as the defendant side
            d.defendantEvidenceCID = ipfsCID;
        }

        emit EvidenceSubmitted(disputeId, msg.sender, ipfsCID);
    }

    /// @notice Arbiter rules on a dispute once the evidence period has closed.
    /// @param  disputeId        The ID of the dispute to resolve
    /// @param  ruleForPlaintiff True to rule in plaintiff's favour
    function resolveDispute(uint256 disputeId, bool ruleForPlaintiff) external onlyArbiter {
        Dispute storage d = _disputes[disputeId];

        if (d.status == DisputeStatus.RESOLVED || d.status == DisputeStatus.EXECUTED) {
            revert AlreadyResolved();
        }

        if (block.timestamp < d.raisedAt + EVIDENCE_PERIOD) {
            revert EvidencePeriodActive();
        }

        d.ruledForPlaintiff = ruleForPlaintiff;
        d.status            = DisputeStatus.RESOLVED;
        d.resolvedAt        = block.timestamp;

        emit DisputeResolved(disputeId, ruleForPlaintiff);
    }

    /// @notice Execute a resolved dispute after the timelock has expired.
    /// @dev    If ruled for plaintiff, the contested license is revoked.
    /// @param  disputeId The ID of the resolved dispute to execute
    function executeResolution(uint256 disputeId) external {
        Dispute storage d = _disputes[disputeId];

        if (d.status != DisputeStatus.RESOLVED) revert DisputeNotResolved();

        if (block.timestamp < d.resolvedAt + TIMELOCK) revert TimelockNotExpired();

        // ── Effects ──────────────────────────────────────────────────────────
        d.status = DisputeStatus.EXECUTED;

        emit ResolutionExecuted(disputeId);

        // ── Interactions ─────────────────────────────────────────────────────
        if (d.ruledForPlaintiff) {
            _licenseManager.revokeLicense(d.licenseId);
        }
    }

    /// @notice Transfer the arbiter role to a new address.
    /// @param  newArbiter Address of the incoming arbiter
    function transferArbiter(address newArbiter) external onlyArbiter {
        address old = arbiter;
        arbiter = newArbiter;
        emit ArbiterTransferred(old, newArbiter);
    }

    // ── External — view ──────────────────────────────────────────────────────

    /// @notice Return the full Dispute struct for a given dispute ID.
    /// @param  disputeId The dispute ID to query
    /// @return           The Dispute struct
    function getDispute(uint256 disputeId) external view returns (Dispute memory) {
        return _disputes[disputeId];
    }
}
