// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ---------------------------------------------------------------------------
// Minimal interface — only the surface LicenseManager needs from IPRegistry
// ---------------------------------------------------------------------------

interface IIPRegistry {
    struct WorkRecord {
        bytes32   fileHash;
        address   owner;
        address[] coOwners;
        uint256[] splits;
        uint256   registeredAt;
        string    metadataURI;
        bool      exists;
    }

    function verifyWork(bytes32 fileHash) external view returns (WorkRecord memory);
}

// ---------------------------------------------------------------------------
// Minimal interface — only the surface LicenseManager needs from RoyaltyVault
// ---------------------------------------------------------------------------

interface IRoyaltyVault {
    function depositRoyalty(bytes32 workHash) external payable;
}

// ---------------------------------------------------------------------------
// LicenseManager
// ---------------------------------------------------------------------------

/// @title  LicenseManager
/// @notice Issues on-chain IP licenses for works registered in IPRegistry and
///         forwards all royalty payments to RoyaltyVault.
contract LicenseManager {

    // ── Types ────────────────────────────────────────────────────────────────

    /// @notice Scope categories available for a license tier.
    enum LicenseScope { PERSONAL, COMMERCIAL, EXCLUSIVE }

    /// @notice A template from which individual licenses are purchased.
    struct LicenseTier {
        bytes32      workHash;
        LicenseScope scope;
        uint256      priceWei;
        uint256      duration;   // seconds; 0 = perpetual
        bool         isActive;
    }

    /// @notice A single purchased license instance.
    struct LicenseRecord {
        uint256 tierId;
        address licensee;
        uint256 purchasedAt;
        uint256 expiresAt;   // 0 = perpetual
        bool    isRevoked;
    }

    // ── Errors ───────────────────────────────────────────────────────────────

    error WorkNotRegistered();
    error NotWorkOwner();
    error InsufficientPayment();
    error ExclusiveLicenseSold();
    error TierNotActive();
    error AlreadyRevoked();
    error NotAuthorized();
    error ArbitratorAlreadySet();

    // ── Events ───────────────────────────────────────────────────────────────

    event LicenseCreated(uint256 indexed tierId, bytes32 indexed workHash, LicenseScope scope);
    event LicensePurchased(uint256 indexed licenseId, uint256 indexed tierId, address indexed licensee);
    event LicenseRevoked(uint256 indexed licenseId);

    // ── State ────────────────────────────────────────────────────────────────

    IIPRegistry   private immutable _registry;
    IRoyaltyVault private immutable _vault;

    LicenseTier[]   private _tiers;    // index == tierId
    LicenseRecord[] private _licenses; // index == licenseId

    mapping(uint256 => bool)        private _exclusiveSold;  // tierId  => sold
    mapping(address => uint256[])   private _licenseeIndex;  // licensee => licenseIds
    address private _disputeArbitrator;                       // set once after deploy

    // ── Constructor ──────────────────────────────────────────────────────────

    /// @param ipRegistry_   Address of the deployed IPRegistry contract
    /// @param royaltyVault_ Address of the deployed RoyaltyVault contract
    constructor(address ipRegistry_, address royaltyVault_) {
        _registry = IIPRegistry(ipRegistry_);
        _vault    = IRoyaltyVault(royaltyVault_);
    }

    // ── External — state-changing ────────────────────────────────────────────

    /// @notice Create a new license tier for a registered work.
    /// @param  workHash  keccak256 file hash of the registered work
    /// @param  scope     License scope (PERSONAL, COMMERCIAL, or EXCLUSIVE)
    /// @param  priceWei  Price in wei to purchase one license
    /// @param  duration  License duration in seconds; 0 means perpetual
    /// @return tierId    The index of the newly created tier
    function createLicenseTier(
        bytes32      workHash,
        LicenseScope scope,
        uint256      priceWei,
        uint256      duration
    ) external returns (uint256 tierId) {
        IIPRegistry.WorkRecord memory record = _registry.verifyWork(workHash);
        if (!record.exists)           revert WorkNotRegistered();
        if (record.owner != msg.sender) revert NotWorkOwner();

        tierId = _tiers.length;
        _tiers.push(LicenseTier({
            workHash: workHash,
            scope:    scope,
            priceWei: priceWei,
            duration: duration,
            isActive: true
        }));

        emit LicenseCreated(tierId, workHash, scope);
    }

    /// @notice Purchase a license for a given tier.
    /// @param  tierId    The ID of the license tier to purchase
    /// @return licenseId The index of the newly issued license
    function purchaseLicense(uint256 tierId) external payable returns (uint256 licenseId) {
        // ── Checks ──────────────────────────────────────────────────────────
        if (tierId >= _tiers.length || !_tiers[tierId].isActive) revert TierNotActive();

        LicenseTier memory tier = _tiers[tierId];

        if (msg.value < tier.priceWei) revert InsufficientPayment();

        if (tier.scope == LicenseScope.EXCLUSIVE && _exclusiveSold[tierId]) {
            revert ExclusiveLicenseSold();
        }

        // ── Effects ─────────────────────────────────────────────────────────
        if (tier.scope == LicenseScope.EXCLUSIVE) {
            _exclusiveSold[tierId] = true;
        }

        uint256 expiresAt = tier.duration == 0 ? 0 : block.timestamp + tier.duration;

        licenseId = _licenses.length;
        _licenses.push(LicenseRecord({
            tierId:      tierId,
            licensee:    msg.sender,
            purchasedAt: block.timestamp,
            expiresAt:   expiresAt,
            isRevoked:   false
        }));

        _licenseeIndex[msg.sender].push(licenseId);

        emit LicensePurchased(licenseId, tierId, msg.sender);

        // ── Interactions ─────────────────────────────────────────────────────
        _vault.depositRoyalty{value: msg.value}(tier.workHash);
    }

    /// @notice Revoke an active license. Caller must be the work owner or the dispute arbitrator.
    /// @param  licenseId The ID of the license to revoke
    function revokeLicense(uint256 licenseId) external {
        LicenseRecord storage lic = _licenses[licenseId];

        if (lic.isRevoked) revert AlreadyRevoked();

        // Determine whether caller is authorised
        LicenseTier memory tier = _tiers[lic.tierId];
        IIPRegistry.WorkRecord memory record = _registry.verifyWork(tier.workHash);

        bool isOwner      = (record.owner == msg.sender);
        bool isArbitrator = (_disputeArbitrator != address(0) && _disputeArbitrator == msg.sender);

        if (!isOwner && !isArbitrator) revert NotAuthorized();

        // Effects
        lic.isRevoked = true;

        emit LicenseRevoked(licenseId);
    }

    /// @notice Set the dispute arbitrator address. Can only be called once.
    /// @param  arbitrator Address of the DisputeArbitrator contract
    function setDisputeArbitrator(address arbitrator) external {
        if (_disputeArbitrator != address(0)) revert ArbitratorAlreadySet();
        _disputeArbitrator = arbitrator;
    }

    // ── External — view ──────────────────────────────────────────────────────

    /// @notice Check whether a license is currently valid (not revoked, not expired).
    /// @param  licenseId The ID of the license to check
    /// @return           True if the license is active and unexpired
    function isLicenseValid(uint256 licenseId) external view returns (bool) {
        LicenseRecord storage lic = _licenses[licenseId];
        if (lic.isRevoked) return false;
        if (lic.expiresAt == 0) return true;
        return block.timestamp < lic.expiresAt;
    }

    /// @notice Return all license IDs held by a given licensee.
    /// @param  licensee The address whose licenses to retrieve
    /// @return          Array of license IDs
    function getLicensesByLicensee(address licensee) external view returns (uint256[] memory) {
        return _licenseeIndex[licensee];
    }

    /// @notice Return the full LicenseTier struct for a given tier ID.
    /// @param  tierId The tier ID to query
    /// @return        The LicenseTier struct
    function getTier(uint256 tierId) external view returns (LicenseTier memory) {
        return _tiers[tierId];
    }

    /// @notice Return the full LicenseRecord struct for a given license ID.
    /// @param  licenseId The license ID to query
    /// @return           The LicenseRecord struct
    function getLicense(uint256 licenseId) external view returns (LicenseRecord memory) {
        return _licenses[licenseId];
    }
}
