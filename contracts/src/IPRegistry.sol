// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice On-chain IP registry. Stores work records keyed by keccak256 file hash.
contract IPRegistry {
    struct WorkRecord {
        bytes32   fileHash;
        address   owner;
        address[] coOwners;
        uint256[] splits;      // basis points per co-owner; owner gets 10000 - sum(splits)
        uint256   registeredAt;
        string    metadataURI;
        bool      exists;
    }

    uint256 private constant MAX_BPS = 10000;

    error AlreadyRegistered();
    error NotOwner();
    error InvalidSplit();
    error InvalidHash();

    event WorkRegistered(bytes32 indexed fileHash, address indexed owner, string metadataURI);
    event OwnershipTransferred(bytes32 indexed fileHash, address indexed from, address indexed to);
    event CoOwnerAdded(bytes32 indexed fileHash, address coOwner, uint256 splitBps);

    mapping(bytes32 => WorkRecord) private _works;
    mapping(address => bytes32[])  private _ownerWorks;

    /// @notice Register a new work. Caller becomes sole owner with 100% royalty share.
    /// @param fileHash keccak256 hash of the original file bytes
    /// @param metadataURI IPFS URI to title, description, and category metadata
    function registerWork(bytes32 fileHash, string calldata metadataURI) external {
        if (fileHash == bytes32(0)) revert InvalidHash();
        if (_works[fileHash].exists) revert AlreadyRegistered();

        WorkRecord storage r = _works[fileHash];
        r.fileHash     = fileHash;
        r.owner        = msg.sender;
        r.registeredAt = block.timestamp;
        r.metadataURI  = metadataURI;
        r.exists       = true;

        _ownerWorks[msg.sender].push(fileHash);
        emit WorkRegistered(fileHash, msg.sender, metadataURI);
    }

    /// @notice Transfer sole ownership to a new address.
    /// @param fileHash The registered work's file hash
    /// @param newOwner Address to transfer ownership to
    function transferOwnership(bytes32 fileHash, address newOwner) external {
        if (newOwner == address(0)) revert NotOwner();
        WorkRecord storage r = _works[fileHash];
        if (!r.exists || r.owner != msg.sender) revert NotOwner();

        address old = r.owner;
        r.owner = newOwner;

        _ownerWorks[newOwner].push(fileHash);
        bytes32[] storage oldList = _ownerWorks[old];
        for (uint256 i = 0; i < oldList.length; i++) {
            if (oldList[i] == fileHash) {
                oldList[i] = oldList[oldList.length - 1];
                oldList.pop();
                break;
            }
        }

        emit OwnershipTransferred(fileHash, old, newOwner);
    }

    /// @notice Add a co-owner with a royalty split in basis points.
    /// @dev Owner's effective share = MAX_BPS - sum(all splits).
    /// @param fileHash The registered work's file hash
    /// @param coOwner Address of the co-owner to add
    /// @param splitBps Royalty share in basis points (1 bps = 0.01%)
    function addCoOwner(bytes32 fileHash, address coOwner, uint256 splitBps) external {
        if (coOwner == address(0)) revert NotOwner();
        WorkRecord storage r = _works[fileHash];
        if (!r.exists || r.owner != msg.sender) revert NotOwner();

        uint256 totalExisting;
        for (uint256 i = 0; i < r.splits.length; i++) totalExisting += r.splits[i];
        if (totalExisting + splitBps > MAX_BPS) revert InvalidSplit();

        r.coOwners.push(coOwner);
        r.splits.push(splitBps);
        emit CoOwnerAdded(fileHash, coOwner, splitBps);
    }

    /// @notice Return the full WorkRecord for a file hash. exists=false if not registered.
    /// @param fileHash The file hash to look up
    /// @return The WorkRecord struct (exists=false if not registered)
    function verifyWork(bytes32 fileHash) external view returns (WorkRecord memory) {
        return _works[fileHash];
    }

    /// @notice Return all file hashes registered by a given owner address.
    /// @param owner The owner address to look up
    /// @return Array of file hashes owned by the address
    function getWorksByOwner(address owner) external view returns (bytes32[] memory) {
        return _ownerWorks[owner];
    }
}
