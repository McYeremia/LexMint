// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ---------------------------------------------------------------------------
// Minimal interface — only the surface RoyaltyVault needs from IPRegistry
// ---------------------------------------------------------------------------

interface IIPRegistry {
    struct WorkRecord {
        bytes32   fileHash;
        address   owner;
        address[] coOwners;
        uint256[] splits;      // basis points per co-owner; owner gets 10000 - sum(splits)
        uint256   registeredAt;
        string    metadataURI;
        bool      exists;
    }

    function verifyWork(bytes32 fileHash) external view returns (WorkRecord memory);
}

// ---------------------------------------------------------------------------
// RoyaltyVault
// ---------------------------------------------------------------------------

/// @notice Receives royalty payments for registered works and distributes them
///         among owners and co-owners according to their on-chain split records.
contract RoyaltyVault is ReentrancyGuard {

    uint256 private constant MAX_BPS = 10000;

    IIPRegistry private immutable _registry;

    mapping(bytes32 => uint256) public vaultBalance;
    mapping(bytes32 => mapping(address => uint256)) public accrued;

    error WorkNotFound();
    error NothingToClaim();

    event RoyaltyDeposited(bytes32 indexed workHash, address indexed from, uint256 amount);
    event RoyaltyClaimed(bytes32 indexed workHash, address indexed owner, uint256 amount);

    /// @param ipRegistry_ Address of the deployed IPRegistry contract
    constructor(address ipRegistry_) {
        _registry = IIPRegistry(ipRegistry_);
    }

    // -----------------------------------------------------------------------
    // External — state-changing
    // -----------------------------------------------------------------------

    /// @notice Deposit ETH royalties for a registered work. Anyone may call this.
    /// @dev    Splits msg.value proportionally among co-owners; owner receives the remainder.
    /// @param  workHash keccak256 file hash identifying the registered work
    function depositRoyalty(bytes32 workHash) external payable {
        IIPRegistry.WorkRecord memory record = _registry.verifyWork(workHash);
        if (!record.exists) revert WorkNotFound();

        uint256 total = msg.value;
        uint256 coOwnerTotal;

        for (uint256 i = 0; i < record.coOwners.length; i++) {
            uint256 share = total * record.splits[i] / MAX_BPS;
            accrued[workHash][record.coOwners[i]] += share;
            coOwnerTotal += share;
        }

        // Owner gets the remainder — this absorbs rounding dust correctly
        accrued[workHash][record.owner] += total - coOwnerTotal;

        vaultBalance[workHash] += total;

        emit RoyaltyDeposited(workHash, msg.sender, total);
    }

    /// @notice Claim all accrued royalties for the caller on a given work.
    /// @param  workHash keccak256 file hash identifying the work
    function claimRoyalty(bytes32 workHash) external nonReentrant {
        uint256 amount = accrued[workHash][msg.sender];
        if (amount == 0) revert NothingToClaim();

        // Checks-effects-interactions: zero state before transfer
        accrued[workHash][msg.sender] = 0;
        vaultBalance[workHash] -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);

        emit RoyaltyClaimed(workHash, msg.sender, amount);
    }

    // -----------------------------------------------------------------------
    // External — view
    // -----------------------------------------------------------------------

    /// @notice Return the claimable ETH balance for an owner on a given work.
    /// @param  workHash keccak256 file hash identifying the work
    /// @param  owner    Address whose accrued balance to query
    /// @return          Claimable ETH amount in wei
    function getAccrued(bytes32 workHash, address owner) external view returns (uint256) {
        return accrued[workHash][owner];
    }
}
