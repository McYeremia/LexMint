# LexMint Phase 1 — Smart Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and test four Solidity smart contracts (IPRegistry, RoyaltyVault, LicenseManager, DisputeArbitrator) forming the fully on-chain backbone of the LexMint IP registry and licensing platform.

**Architecture:** Tight-coupling via direct contract calls. IPRegistry is the source of truth for ownership and royalty splits. RoyaltyVault holds all ETH and distributes it proportionally on deposit. LicenseManager enforces license rules and auto-forwards payment to RoyaltyVault. DisputeArbitrator can revoke licenses after evidence period + timelock.

**Tech Stack:** Solidity ^0.8.24, Foundry (forge), OpenZeppelin (ReentrancyGuard), forge-std (Test)

---

## File Map

| Action | Path |
|--------|------|
| Modify | `contracts/foundry.toml` |
| Delete | `contracts/src/Counter.sol` |
| Delete | `contracts/test/Counter.t.sol` |
| Delete | `contracts/script/Counter.s.sol` |
| Create | `contracts/src/IPRegistry.sol` |
| Create | `contracts/test/IPRegistry.t.sol` |
| Create | `contracts/src/RoyaltyVault.sol` |
| Create | `contracts/test/RoyaltyVault.t.sol` |
| Create | `contracts/src/LicenseManager.sol` |
| Create | `contracts/test/LicenseManager.t.sol` |
| Create | `contracts/src/DisputeArbitrator.sol` |
| Create | `contracts/test/DisputeArbitrator.t.sol` |
| Create | `contracts/test/Integration.t.sol` |
| Create | `contracts/script/Deploy.s.sol` |

**Deploy order:** IPRegistry → RoyaltyVault → LicenseManager → DisputeArbitrator → `LicenseManager.setDisputeArbitrator()`

> Note: RoyaltyVault is deployed before LicenseManager because LicenseManager needs the vault address in its constructor.

---

## Task 0: Configure Foundry

**Files:**
- Modify: `contracts/foundry.toml`
- Delete: `contracts/src/Counter.sol`, `contracts/test/Counter.t.sol`, `contracts/script/Counter.s.sol`

- [ ] **Step 1: Replace foundry.toml**

Replace the entire content of `contracts/foundry.toml` with:

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.24"
optimizer = true
optimizer_runs = 200
remappings = ["@openzeppelin/=lib/openzeppelin-contracts/"]
```

- [ ] **Step 2: Delete default Counter files**

```bash
rm contracts/src/Counter.sol contracts/test/Counter.t.sol contracts/script/Counter.s.sol
```

- [ ] **Step 3: Verify forge is happy**

```bash
cd contracts && forge build
```

Expected: `Nothing to compile` (empty src — no errors).

---

## Task 1: IPRegistry.sol

**Files:**
- Create: `contracts/test/IPRegistry.t.sol`
- Create: `contracts/src/IPRegistry.sol`

- [ ] **Step 1: Write the failing test file**

`contracts/test/IPRegistry.t.sol`:

```solidity
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
```

- [ ] **Step 2: Run — expect compilation error (contract does not exist yet)**

```bash
cd contracts && forge test --match-contract IPRegistryTest 2>&1 | head -10
```

Expected: `Error: ... file not found` or similar.

- [ ] **Step 3: Write IPRegistry.sol**

`contracts/src/IPRegistry.sol`:

```solidity
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

    error AlreadyRegistered();
    error NotOwner();
    error InvalidSplit();

    event WorkRegistered(bytes32 indexed fileHash, address indexed owner, string metadataURI);
    event OwnershipTransferred(bytes32 indexed fileHash, address indexed from, address indexed to);
    event CoOwnerAdded(bytes32 indexed fileHash, address coOwner, uint256 splitBps);

    mapping(bytes32 => WorkRecord) private _works;
    mapping(address => bytes32[])  private _ownerWorks;

    /// @notice Register a new work. Caller becomes sole owner with 100% royalty share.
    function registerWork(bytes32 fileHash, string calldata metadataURI) external {
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
    function transferOwnership(bytes32 fileHash, address newOwner) external {
        WorkRecord storage r = _works[fileHash];
        if (!r.exists || r.owner != msg.sender) revert NotOwner();

        address old = r.owner;
        r.owner = newOwner;
        emit OwnershipTransferred(fileHash, old, newOwner);
    }

    /// @notice Add a co-owner with a royalty split in basis points.
    /// @dev Owner's effective share = 10000 - sum(all splits).
    function addCoOwner(bytes32 fileHash, address coOwner, uint256 splitBps) external {
        WorkRecord storage r = _works[fileHash];
        if (!r.exists || r.owner != msg.sender) revert NotOwner();

        uint256 totalExisting;
        for (uint256 i = 0; i < r.splits.length; i++) totalExisting += r.splits[i];
        if (totalExisting + splitBps > 10000) revert InvalidSplit();

        r.coOwners.push(coOwner);
        r.splits.push(splitBps);
        emit CoOwnerAdded(fileHash, coOwner, splitBps);
    }

    /// @notice Return the full WorkRecord for a file hash. exists=false if not registered.
    function verifyWork(bytes32 fileHash) external view returns (WorkRecord memory) {
        return _works[fileHash];
    }

    /// @notice Return all file hashes registered by a given owner address.
    function getWorksByOwner(address owner) external view returns (bytes32[] memory) {
        return _ownerWorks[owner];
    }
}
```

- [ ] **Step 4: Run tests — all must pass**

```bash
cd contracts && forge test --match-contract IPRegistryTest -vvv
```

Expected:
```
[PASS] test_registerWork_storesRecord()
[PASS] test_registerWork_emitsEvent()
[PASS] test_registerWork_addsToOwnerIndex()
[PASS] test_registerWork_reverts_alreadyRegistered()
[PASS] test_transferOwnership_updatesOwner()
[PASS] test_transferOwnership_reverts_notOwner()
[PASS] test_addCoOwner_appendsEntry()
[PASS] test_addCoOwner_reverts_notOwner()
[PASS] test_addCoOwner_reverts_invalidSplit()
[PASS] testFuzz_registerWork_noDuplicatesForDifferentHashes(...)
[PASS] testFuzz_addCoOwner_totalSplitNeverExceeds10000(...)
[PASS] invariant_unregisteredHashReturnsFalse()
```

---

## Task 2: RoyaltyVault.sol

**Files:**
- Create: `contracts/test/RoyaltyVault.t.sol`
- Create: `contracts/src/RoyaltyVault.sol`

- [ ] **Step 1: Write the failing test file**

`contracts/test/RoyaltyVault.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPRegistry}   from "../src/IPRegistry.sol";
import {RoyaltyVault} from "../src/RoyaltyVault.sol";

contract RoyaltyVaultTest is Test {
    IPRegistry   registry;
    RoyaltyVault vault;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");

    bytes32 constant FILE_HASH = keccak256("test_file");

    function setUp() public {
        registry = new IPRegistry();
        vault    = new RoyaltyVault(address(registry));

        vm.prank(alice);
        registry.registerWork(FILE_HASH, "ipfs://QmTest");

        deal(alice, 10 ether);
        deal(bob,   10 ether);
        deal(carol, 10 ether);
    }

    // ── depositRoyalty ────────────────────────────────────────────────────────

    function test_deposit_creditsOwner_noCoOwners() public {
        vm.prank(bob);
        vault.depositRoyalty{value: 1 ether}(FILE_HASH);

        assertEq(vault.getAccrued(FILE_HASH, alice), 1 ether);
        assertEq(vault.vaultBalance(FILE_HASH), 1 ether);
    }

    function test_deposit_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit RoyaltyVault.RoyaltyDeposited(FILE_HASH, bob, 1 ether);
        vm.prank(bob);
        vault.depositRoyalty{value: 1 ether}(FILE_HASH);
    }

    function test_deposit_splitsToCoOwner() public {
        vm.prank(alice);
        registry.addCoOwner(FILE_HASH, bob, 3000); // bob: 30%, alice: 70%

        vm.prank(carol);
        vault.depositRoyalty{value: 1 ether}(FILE_HASH);

        assertEq(vault.getAccrued(FILE_HASH, bob),   0.3 ether);
        assertEq(vault.getAccrued(FILE_HASH, alice), 0.7 ether);
    }

    function test_deposit_ownerGetsRemainder_roundingDust() public {
        // 3 wei with 30% split: bob gets 0 (floor), alice gets 3
        vm.prank(alice);
        registry.addCoOwner(FILE_HASH, bob, 3000);

        vm.prank(carol);
        vault.depositRoyalty{value: 3}(FILE_HASH);

        // bob: (3 * 3000) / 10000 = 0 (integer division)
        assertEq(vault.getAccrued(FILE_HASH, bob),   0);
        // alice: 3 - 0 = 3
        assertEq(vault.getAccrued(FILE_HASH, alice), 3);
    }

    function test_deposit_reverts_workNotFound() public {
        vm.expectRevert(RoyaltyVault.WorkNotFound.selector);
        vault.depositRoyalty{value: 1 ether}(keccak256("nonexistent"));
    }

    // ── claimRoyalty ──────────────────────────────────────────────────────────

    function test_claim_transfersEthAndZeroesAccrued() public {
        vm.prank(bob);
        vault.depositRoyalty{value: 1 ether}(FILE_HASH);

        uint256 before = alice.balance;
        vm.prank(alice);
        vault.claimRoyalty(FILE_HASH);

        assertEq(alice.balance, before + 1 ether);
        assertEq(vault.getAccrued(FILE_HASH, alice), 0);
        assertEq(vault.vaultBalance(FILE_HASH), 0);
    }

    function test_claim_emitsEvent() public {
        vm.prank(bob);
        vault.depositRoyalty{value: 1 ether}(FILE_HASH);

        vm.expectEmit(true, true, false, true);
        emit RoyaltyVault.RoyaltyClaimed(FILE_HASH, alice, 1 ether);
        vm.prank(alice);
        vault.claimRoyalty(FILE_HASH);
    }

    function test_claim_reverts_nothingToClaim() public {
        vm.expectRevert(RoyaltyVault.NothingToClaim.selector);
        vm.prank(alice);
        vault.claimRoyalty(FILE_HASH);
    }

    // ── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_deposit_ownerReceivesAll_noCoOwners(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        deal(bob, amount);

        vm.prank(bob);
        vault.depositRoyalty{value: amount}(FILE_HASH);

        assertEq(vault.getAccrued(FILE_HASH, alice), amount);
    }

    function testFuzz_deposit_totalAccruedEqualsMsgValue(uint256 split, uint256 amount) public {
        split  = bound(split, 1, 9999);
        amount = bound(amount, 1, 100 ether);

        vm.prank(alice);
        registry.addCoOwner(FILE_HASH, bob, split);

        deal(carol, amount);
        vm.prank(carol);
        vault.depositRoyalty{value: amount}(FILE_HASH);

        uint256 total = vault.getAccrued(FILE_HASH, bob) + vault.getAccrued(FILE_HASH, alice);
        assertEq(total, amount);
    }

    // ── Invariant ─────────────────────────────────────────────────────────────

    function invariant_contractBalanceAlwaysNonNegative() public view {
        assertGe(address(vault).balance, 0);
    }
}
```

- [ ] **Step 2: Run — expect compilation error**

```bash
cd contracts && forge test --match-contract RoyaltyVaultTest 2>&1 | head -10
```

- [ ] **Step 3: Write RoyaltyVault.sol**

`contracts/src/RoyaltyVault.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPRegistry}      from "./IPRegistry.sol";

/// @notice Holds and distributes ETH royalty payments for registered works.
contract RoyaltyVault is ReentrancyGuard {
    IPRegistry public immutable ipRegistry;

    error WorkNotFound();
    error NothingToClaim();

    event RoyaltyDeposited(bytes32 indexed workHash, address indexed from, uint256 amount);
    event RoyaltyClaimed(bytes32 indexed workHash, address indexed owner, uint256 amount);

    mapping(bytes32 => uint256) public vaultBalance;
    mapping(bytes32 => mapping(address => uint256)) private _accrued;

    constructor(address ipRegistry_) {
        ipRegistry = IPRegistry(ipRegistry_);
    }

    /// @notice Deposit ETH for a work. Splits proportionally to co-owners; remainder to owner.
    function depositRoyalty(bytes32 workHash) external payable {
        IPRegistry.WorkRecord memory work = ipRegistry.verifyWork(workHash);
        if (!work.exists) revert WorkNotFound();

        vaultBalance[workHash] += msg.value;

        uint256 remaining = msg.value;
        for (uint256 i = 0; i < work.coOwners.length; i++) {
            uint256 share = (msg.value * work.splits[i]) / 10000;
            _accrued[workHash][work.coOwners[i]] += share;
            remaining -= share;
        }
        _accrued[workHash][work.owner] += remaining;

        emit RoyaltyDeposited(workHash, msg.sender, msg.value);
    }

    /// @notice Claim all accrued ETH for msg.sender on a given work.
    function claimRoyalty(bytes32 workHash) external nonReentrant {
        uint256 amount = _accrued[workHash][msg.sender];
        if (amount == 0) revert NothingToClaim();

        _accrued[workHash][msg.sender] = 0;
        vaultBalance[workHash] -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");

        emit RoyaltyClaimed(workHash, msg.sender, amount);
    }

    /// @notice Return unclaimed royalties for an owner on a given work.
    function getAccrued(bytes32 workHash, address owner) external view returns (uint256) {
        return _accrued[workHash][owner];
    }
}
```

- [ ] **Step 4: Run tests — all must pass**

```bash
cd contracts && forge test --match-contract RoyaltyVaultTest -vvv
```

Expected: all tests pass including fuzz and invariant.

---

## Task 3: LicenseManager.sol

**Files:**
- Create: `contracts/test/LicenseManager.t.sol`
- Create: `contracts/src/LicenseManager.sol`

- [ ] **Step 1: Write the failing test file**

`contracts/test/LicenseManager.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPRegistry}     from "../src/IPRegistry.sol";
import {RoyaltyVault}   from "../src/RoyaltyVault.sol";
import {LicenseManager} from "../src/LicenseManager.sol";

contract LicenseManagerTest is Test {
    IPRegistry     registry;
    RoyaltyVault   vault;
    LicenseManager manager;

    address alice = makeAddr("alice");  // work owner
    address bob   = makeAddr("bob");    // licensee
    address carol = makeAddr("carol");

    bytes32 constant FILE_HASH = keccak256("test_file");

    function setUp() public {
        registry = new IPRegistry();
        vault    = new RoyaltyVault(address(registry));
        manager  = new LicenseManager(address(registry), address(vault));

        vm.prank(alice);
        registry.registerWork(FILE_HASH, "ipfs://QmTest");

        deal(bob,   10 ether);
        deal(carol, 10 ether);
    }

    // ── createLicenseTier ─────────────────────────────────────────────────────

    function test_createTier_storesTier() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.COMMERCIAL, 0.1 ether, 30 days
        );

        assertEq(tierId, 0);
        (bytes32 wh, LicenseManager.LicenseScope scope, uint256 price, uint256 dur, bool active)
            = manager.tiers(tierId);
        assertEq(wh, FILE_HASH);
        assertEq(uint8(scope), uint8(LicenseManager.LicenseScope.COMMERCIAL));
        assertEq(price, 0.1 ether);
        assertEq(dur, 30 days);
        assertTrue(active);
    }

    function test_createTier_emitsEvent() public {
        vm.expectEmit(false, true, false, true);
        emit LicenseManager.LicenseCreated(0, FILE_HASH, LicenseManager.LicenseScope.PERSONAL);
        vm.prank(alice);
        manager.createLicenseTier(FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 0);
    }

    function test_createTier_reverts_workNotRegistered() public {
        vm.expectRevert(LicenseManager.WorkNotRegistered.selector);
        vm.prank(alice);
        manager.createLicenseTier(keccak256("nope"), LicenseManager.LicenseScope.PERSONAL, 0, 0);
    }

    function test_createTier_reverts_notWorkOwner() public {
        vm.expectRevert(LicenseManager.NotWorkOwner.selector);
        vm.prank(bob);
        manager.createLicenseTier(FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 0);
    }

    // ── purchaseLicense ───────────────────────────────────────────────────────

    function test_purchase_createsLicenseRecord() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0.1 ether, 30 days
        );

        vm.prank(bob);
        uint256 licenseId = manager.purchaseLicense{value: 0.1 ether}(tierId);

        (uint256 tid, address licensee, uint256 purchasedAt, uint256 expiresAt, bool revoked)
            = manager.licenses(licenseId);
        assertEq(tid, tierId);
        assertEq(licensee, bob);
        assertEq(purchasedAt, block.timestamp);
        assertEq(expiresAt, block.timestamp + 30 days);
        assertFalse(revoked);
    }

    function test_purchase_forwardsEthToVault() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0.5 ether, 0
        );

        vm.prank(bob);
        manager.purchaseLicense{value: 0.5 ether}(tierId);

        assertEq(vault.getAccrued(FILE_HASH, alice), 0.5 ether);
        assertEq(address(manager).balance, 0);
    }

    function test_purchase_emitsEvent() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 0
        );

        vm.expectEmit(false, true, true, false);
        emit LicenseManager.LicensePurchased(0, tierId, bob);
        vm.prank(bob);
        manager.purchaseLicense{value: 0}(tierId);
    }

    function test_purchase_reverts_insufficientPayment() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 1 ether, 0
        );

        vm.expectRevert(LicenseManager.InsufficientPayment.selector);
        vm.prank(bob);
        manager.purchaseLicense{value: 0.5 ether}(tierId);
    }

    function test_purchase_reverts_exclusiveAlreadySold() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.EXCLUSIVE, 0.1 ether, 0
        );

        vm.prank(bob);
        manager.purchaseLicense{value: 0.1 ether}(tierId);

        vm.expectRevert(LicenseManager.ExclusiveLicenseSold.selector);
        vm.prank(carol);
        manager.purchaseLicense{value: 0.1 ether}(tierId);
    }

    // ── isLicenseValid ────────────────────────────────────────────────────────

    function test_isLicenseValid_trueBeforeExpiry() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 30 days
        );
        vm.prank(bob);
        uint256 licenseId = manager.purchaseLicense{value: 0}(tierId);

        assertTrue(manager.isLicenseValid(licenseId));
    }

    function test_isLicenseValid_falseAfterExpiry() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 30 days
        );
        vm.prank(bob);
        uint256 licenseId = manager.purchaseLicense{value: 0}(tierId);

        vm.warp(block.timestamp + 31 days);
        assertFalse(manager.isLicenseValid(licenseId));
    }

    function test_isLicenseValid_trueForPerpetualAfter100Years() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 0
        );
        vm.prank(bob);
        uint256 licenseId = manager.purchaseLicense{value: 0}(tierId);

        vm.warp(block.timestamp + 365 days * 100);
        assertTrue(manager.isLicenseValid(licenseId));
    }

    // ── revokeLicense ─────────────────────────────────────────────────────────

    function test_revoke_byOwner() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 0);
        vm.prank(bob);
        uint256 licenseId = manager.purchaseLicense{value: 0}(tierId);

        vm.expectEmit(true, false, false, false);
        emit LicenseManager.LicenseRevoked(licenseId);

        vm.prank(alice);
        manager.revokeLicense(licenseId);

        assertFalse(manager.isLicenseValid(licenseId));
    }

    function test_revoke_reverts_notOwnerOrArbitrator() public {
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 0);
        vm.prank(bob);
        uint256 licenseId = manager.purchaseLicense{value: 0}(tierId);

        vm.expectRevert(LicenseManager.NotWorkOwner.selector);
        vm.prank(bob);
        manager.revokeLicense(licenseId);
    }

    // ── getLicensesByLicensee ─────────────────────────────────────────────────

    function test_getLicenses_returnsBobLicenses() public {
        vm.prank(alice);
        uint256 t1 = manager.createLicenseTier(FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 0);
        vm.prank(alice);
        uint256 t2 = manager.createLicenseTier(FILE_HASH, LicenseManager.LicenseScope.COMMERCIAL, 0, 0);

        vm.prank(bob);
        manager.purchaseLicense{value: 0}(t1);
        vm.prank(bob);
        manager.purchaseLicense{value: 0}(t2);

        uint256[] memory ids = manager.getLicensesByLicensee(bob);
        assertEq(ids.length, 2);
    }

    // ── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_purchase_expiresAtMatchesDuration(uint256 duration) public {
        duration = bound(duration, 1, 365 days * 10);

        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, duration
        );
        vm.prank(bob);
        uint256 licenseId = manager.purchaseLicense{value: 0}(tierId);

        (, , uint256 purchasedAt, uint256 expiresAt,) = manager.licenses(licenseId);
        assertEq(expiresAt, purchasedAt + duration);
    }

    function testFuzz_purchase_ethForwardedExactly(uint256 price) public {
        price = bound(price, 0, 5 ether);
        deal(bob, price);

        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, price, 0
        );
        vm.prank(bob);
        manager.purchaseLicense{value: price}(tierId);

        assertEq(vault.getAccrued(FILE_HASH, alice), price);
        assertEq(address(manager).balance, 0);
    }

    // ── Invariant ─────────────────────────────────────────────────────────────

    function invariant_managerNeverHoldsEth() public view {
        assertEq(address(manager).balance, 0);
    }
}
```

- [ ] **Step 2: Run — expect compilation error**

```bash
cd contracts && forge test --match-contract LicenseManagerTest 2>&1 | head -10
```

- [ ] **Step 3: Write LicenseManager.sol**

`contracts/src/LicenseManager.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPRegistry}   from "./IPRegistry.sol";
import {RoyaltyVault} from "./RoyaltyVault.sol";

/// @notice Creates license tiers and processes purchases, forwarding ETH directly to RoyaltyVault.
contract LicenseManager {
    enum LicenseScope { PERSONAL, COMMERCIAL, EXCLUSIVE }

    struct LicenseTier {
        bytes32      workHash;
        LicenseScope scope;
        uint256      priceWei;
        uint256      duration;    // seconds; 0 = perpetual
        bool         isActive;
    }

    struct LicenseRecord {
        uint256      tierId;
        address      licensee;
        uint256      purchasedAt;
        uint256      expiresAt;   // 0 = perpetual
        bool         isRevoked;
    }

    error WorkNotRegistered();
    error NotWorkOwner();
    error InsufficientPayment();
    error ExclusiveLicenseSold();
    error TierNotActive();
    error LicenseRevoked();

    event LicenseCreated(uint256 indexed tierId, bytes32 indexed workHash, LicenseScope scope);
    event LicensePurchased(uint256 indexed licenseId, uint256 indexed tierId, address indexed licensee);
    event LicenseRevoked(uint256 indexed licenseId);

    IPRegistry   public immutable ipRegistry;
    RoyaltyVault public immutable royaltyVault;

    address public disputeArbitrator;

    LicenseTier[]   public tiers;
    LicenseRecord[] public licenses;

    mapping(address => uint256[]) private _licensesByLicensee;
    mapping(uint256 => bool)      private _exclusiveSold;

    constructor(address ipRegistry_, address royaltyVault_) {
        ipRegistry   = IPRegistry(ipRegistry_);
        royaltyVault = RoyaltyVault(royaltyVault_);
    }

    /// @notice Called once after DisputeArbitrator is deployed to authorize it as a revoker.
    function setDisputeArbitrator(address arbitrator) external {
        require(disputeArbitrator == address(0), "already set");
        disputeArbitrator = arbitrator;
    }

    /// @notice Create a new license tier for a registered work.
    function createLicenseTier(
        bytes32      workHash,
        LicenseScope scope,
        uint256      priceWei,
        uint256      duration
    ) external returns (uint256 tierId) {
        IPRegistry.WorkRecord memory work = ipRegistry.verifyWork(workHash);
        if (!work.exists)             revert WorkNotRegistered();
        if (work.owner != msg.sender) revert NotWorkOwner();

        tierId = tiers.length;
        tiers.push(LicenseTier({
            workHash: workHash,
            scope:    scope,
            priceWei: priceWei,
            duration: duration,
            isActive: true
        }));

        emit LicenseCreated(tierId, workHash, scope);
    }

    /// @notice Purchase a license. ETH is forwarded to RoyaltyVault immediately.
    function purchaseLicense(uint256 tierId) external payable returns (uint256 licenseId) {
        LicenseTier storage tier = tiers[tierId];
        if (!tier.isActive)            revert TierNotActive();
        if (msg.value < tier.priceWei) revert InsufficientPayment();

        if (tier.scope == LicenseScope.EXCLUSIVE) {
            if (_exclusiveSold[tierId]) revert ExclusiveLicenseSold();
            _exclusiveSold[tierId] = true;
        }

        uint256 expiresAt = (tier.duration == 0) ? 0 : block.timestamp + tier.duration;

        licenseId = licenses.length;
        licenses.push(LicenseRecord({
            tierId:      tierId,
            licensee:    msg.sender,
            purchasedAt: block.timestamp,
            expiresAt:   expiresAt,
            isRevoked:   false
        }));
        _licensesByLicensee[msg.sender].push(licenseId);

        if (msg.value > 0) {
            royaltyVault.depositRoyalty{value: msg.value}(tier.workHash);
        }

        emit LicensePurchased(licenseId, tierId, msg.sender);
    }

    /// @notice Revoke a license. Caller must be the work owner or the DisputeArbitrator contract.
    function revokeLicense(uint256 licenseId) external {
        LicenseRecord storage lic = licenses[licenseId];
        bytes32 workHash = tiers[lic.tierId].workHash;
        IPRegistry.WorkRecord memory work = ipRegistry.verifyWork(workHash);

        if (msg.sender != work.owner && msg.sender != disputeArbitrator) {
            revert NotWorkOwner();
        }

        lic.isRevoked = true;
        emit LicenseRevoked(licenseId);
    }

    /// @notice Returns true if the license is not revoked and has not expired.
    function isLicenseValid(uint256 licenseId) external view returns (bool) {
        if (licenseId >= licenses.length) return false;
        LicenseRecord storage lic = licenses[licenseId];
        if (lic.isRevoked) return false;
        if (lic.expiresAt != 0 && block.timestamp > lic.expiresAt) return false;
        return true;
    }

    /// @notice Return all license IDs held by a given licensee.
    function getLicensesByLicensee(address licensee) external view returns (uint256[] memory) {
        return _licensesByLicensee[licensee];
    }
}
```

- [ ] **Step 4: Run tests — all must pass**

```bash
cd contracts && forge test --match-contract LicenseManagerTest -vvv
```

Expected: all tests pass including `invariant_managerNeverHoldsEth`.

---

## Task 4: DisputeArbitrator.sol

**Files:**
- Create: `contracts/test/DisputeArbitrator.t.sol`
- Create: `contracts/src/DisputeArbitrator.sol`

- [ ] **Step 1: Write the failing test file**

`contracts/test/DisputeArbitrator.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPRegistry}        from "../src/IPRegistry.sol";
import {RoyaltyVault}      from "../src/RoyaltyVault.sol";
import {LicenseManager}    from "../src/LicenseManager.sol";
import {DisputeArbitrator} from "../src/DisputeArbitrator.sol";

contract DisputeArbitratorTest is Test {
    IPRegistry        registry;
    RoyaltyVault      vault;
    LicenseManager    manager;
    DisputeArbitrator arbitrator;

    address arbiter = makeAddr("arbiter");
    address alice   = makeAddr("alice");   // work owner / defendant
    address bob     = makeAddr("bob");     // licensee / plaintiff

    bytes32 constant FILE_HASH = keccak256("test_file");
    uint256 tierId;
    uint256 licenseId;

    function setUp() public {
        registry   = new IPRegistry();
        vault      = new RoyaltyVault(address(registry));
        manager    = new LicenseManager(address(registry), address(vault));
        arbitrator = new DisputeArbitrator(address(manager), arbiter);
        manager.setDisputeArbitrator(address(arbitrator));

        vm.prank(alice);
        registry.registerWork(FILE_HASH, "ipfs://QmTest");

        vm.prank(alice);
        tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 30 days
        );

        deal(bob, 10 ether);
        vm.prank(bob);
        licenseId = manager.purchaseLicense{value: 0}(tierId);
    }

    // ── raiseDispute ──────────────────────────────────────────────────────────

    function test_raiseDispute_createsDispute() public {
        vm.expectEmit(false, true, true, false);
        emit DisputeArbitrator.DisputeRaised(0, licenseId, bob);

        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        assertEq(disputeId, 0);
        (
            uint256 lid, address plaintiff, address defendant,
            string memory pCID, string memory dCID,
            DisputeArbitrator.DisputeStatus status,
            bool ruled, uint256 raisedAt, uint256 resolvedAt
        ) = arbitrator.disputes(disputeId);

        assertEq(lid, licenseId);
        assertEq(plaintiff, bob);
        assertEq(defendant, alice);
        assertEq(uint8(status), uint8(DisputeArbitrator.DisputeStatus.RAISED));
        assertEq(raisedAt, block.timestamp);
        assertEq(resolvedAt, 0);
        assertFalse(ruled);
    }

    // ── submitEvidence ────────────────────────────────────────────────────────

    function test_submitEvidence_byPlaintiff() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.expectEmit(true, false, false, true);
        emit DisputeArbitrator.EvidenceSubmitted(disputeId, bob, "ipfs://QmEvidence");

        vm.prank(bob);
        arbitrator.submitEvidence(disputeId, "ipfs://QmEvidence");

        (,,, string memory pCID,,,,, ) = arbitrator.disputes(disputeId);
        assertEq(pCID, "ipfs://QmEvidence");
    }

    function test_submitEvidence_byDefendant() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.prank(alice);
        arbitrator.submitEvidence(disputeId, "ipfs://QmDefense");

        (,,,, string memory dCID,,,, ) = arbitrator.disputes(disputeId);
        assertEq(dCID, "ipfs://QmDefense");
    }

    function test_submitEvidence_reverts_notParty() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        address stranger = makeAddr("stranger");
        vm.expectRevert(DisputeArbitrator.NotPartyToDispute.selector);
        vm.prank(stranger);
        arbitrator.submitEvidence(disputeId, "ipfs://QmFake");
    }

    // ── resolveDispute ────────────────────────────────────────────────────────

    function test_resolve_byArbiterAfterEvidencePeriod() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.warp(block.timestamp + 73 hours);

        vm.expectEmit(true, false, false, true);
        emit DisputeArbitrator.DisputeResolved(disputeId, true);

        vm.prank(arbiter);
        arbitrator.resolveDispute(disputeId, true);

        (,,,,,DisputeArbitrator.DisputeStatus status, bool ruled,,) = arbitrator.disputes(disputeId);
        assertEq(uint8(status), uint8(DisputeArbitrator.DisputeStatus.RESOLVED));
        assertTrue(ruled);
    }

    function test_resolve_reverts_duringEvidencePeriod() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.expectRevert(DisputeArbitrator.EvidencePeriodActive.selector);
        vm.prank(arbiter);
        arbitrator.resolveDispute(disputeId, true);
    }

    function test_resolve_reverts_notArbiter() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.warp(block.timestamp + 73 hours);
        vm.expectRevert(DisputeArbitrator.NotArbiter.selector);
        vm.prank(alice);
        arbitrator.resolveDispute(disputeId, true);
    }

    function test_resolve_reverts_alreadyResolved() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.warp(block.timestamp + 73 hours);
        vm.prank(arbiter);
        arbitrator.resolveDispute(disputeId, true);

        vm.expectRevert(DisputeArbitrator.AlreadyResolved.selector);
        vm.prank(arbiter);
        arbitrator.resolveDispute(disputeId, false);
    }

    // ── executeResolution ─────────────────────────────────────────────────────

    function test_execute_revokesLicenseIfPlaintiffWins() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.warp(block.timestamp + 73 hours);
        vm.prank(arbiter);
        arbitrator.resolveDispute(disputeId, true);

        vm.warp(block.timestamp + 49 hours);

        vm.expectEmit(true, false, false, false);
        emit DisputeArbitrator.ResolutionExecuted(disputeId);

        arbitrator.executeResolution(disputeId);
        assertFalse(manager.isLicenseValid(licenseId));
    }

    function test_execute_keepsLicenseIfDefendantWins() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.warp(block.timestamp + 73 hours);
        vm.prank(arbiter);
        arbitrator.resolveDispute(disputeId, false);

        vm.warp(block.timestamp + 49 hours);
        arbitrator.executeResolution(disputeId);

        assertTrue(manager.isLicenseValid(licenseId));
    }

    function test_execute_reverts_timelockNotExpired() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.warp(block.timestamp + 73 hours);
        vm.prank(arbiter);
        arbitrator.resolveDispute(disputeId, true);

        // TIMELOCK = 48h; only 1h has passed
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(DisputeArbitrator.TimelockNotExpired.selector);
        arbitrator.executeResolution(disputeId);
    }

    function test_execute_reverts_notResolved() public {
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.expectRevert(DisputeArbitrator.AlreadyResolved.selector);
        arbitrator.executeResolution(disputeId);
    }

    // ── transferArbiter ───────────────────────────────────────────────────────

    function test_transferArbiter_updatesArbiter() public {
        address newArbiter = makeAddr("newArbiter");

        vm.expectEmit(true, true, false, false);
        emit DisputeArbitrator.ArbiterTransferred(arbiter, newArbiter);

        vm.prank(arbiter);
        arbitrator.transferArbiter(newArbiter);

        assertEq(arbitrator.arbiter(), newArbiter);
    }

    function test_transferArbiter_reverts_notArbiter() public {
        vm.expectRevert(DisputeArbitrator.NotArbiter.selector);
        vm.prank(alice);
        arbitrator.transferArbiter(alice);
    }

    // ── Fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_raiseDispute_plaintiffIsAlwaysCaller(address caller) public {
        vm.assume(caller != address(0) && caller != alice);

        vm.prank(alice);
        uint256 t = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 30 days
        );
        vm.prank(caller);
        uint256 lid = manager.purchaseLicense{value: 0}(t);

        vm.prank(caller);
        uint256 dId = arbitrator.raiseDispute(lid);

        (, address plaintiff, , , , , , , ) = arbitrator.disputes(dId);
        assertEq(plaintiff, caller);
    }

    function testFuzz_execute_revertsBeforeTimelock(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 47 hours);

        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        vm.warp(block.timestamp + 73 hours);
        vm.prank(arbiter);
        arbitrator.resolveDispute(disputeId, true);

        vm.warp(block.timestamp + elapsed);
        vm.expectRevert(DisputeArbitrator.TimelockNotExpired.selector);
        arbitrator.executeResolution(disputeId);
    }

    // ── Invariant ─────────────────────────────────────────────────────────────

    function invariant_arbiterIsNeverZeroAddress() public view {
        assertTrue(arbitrator.arbiter() != address(0));
    }
}
```

- [ ] **Step 2: Run — expect compilation error**

```bash
cd contracts && forge test --match-contract DisputeArbitratorTest 2>&1 | head -10
```

- [ ] **Step 3: Write DisputeArbitrator.sol**

`contracts/src/DisputeArbitrator.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LicenseManager} from "./LicenseManager.sol";
import {IPRegistry}     from "./IPRegistry.sol";

/// @notice Arbitrates IP licensing disputes with an evidence period and execution timelock.
contract DisputeArbitrator {
    enum DisputeStatus { RAISED, EVIDENCE_PERIOD, RESOLVED, EXECUTED }

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

    uint256 public constant EVIDENCE_PERIOD = 72 hours;
    uint256 public constant TIMELOCK        = 48 hours;

    address        public arbiter;
    LicenseManager public immutable licenseManager;

    error NotArbiter();
    error EvidencePeriodActive();
    error TimelockNotExpired();
    error AlreadyResolved();
    error NotPartyToDispute();

    event DisputeRaised(uint256 indexed disputeId, uint256 indexed licenseId, address plaintiff);
    event EvidenceSubmitted(uint256 indexed disputeId, address submitter, string ipfsCID);
    event DisputeResolved(uint256 indexed disputeId, bool ruledForPlaintiff);
    event ResolutionExecuted(uint256 indexed disputeId);
    event ArbiterTransferred(address indexed oldArbiter, address indexed newArbiter);

    Dispute[] public disputes;

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert NotArbiter();
        _;
    }

    constructor(address licenseManager_, address arbiter_) {
        licenseManager = LicenseManager(licenseManager_);
        arbiter        = arbiter_;
    }

    /// @notice Raise a dispute over a license. Caller is plaintiff; other party is defendant.
    function raiseDispute(uint256 licenseId) external returns (uint256 disputeId) {
        (, address licensee, , , ) = licenseManager.licenses(licenseId);
        (bytes32 workHash, , , , ) = licenseManager.tiers(
            _getTierId(licenseId)
        );

        IPRegistry ipRegistry = licenseManager.ipRegistry();
        IPRegistry.WorkRecord memory work = ipRegistry.verifyWork(workHash);

        address defendant = (msg.sender == licensee) ? work.owner : licensee;

        disputeId = disputes.length;
        disputes.push(Dispute({
            licenseId:            licenseId,
            plaintiff:            msg.sender,
            defendant:            defendant,
            plaintiffEvidenceCID: "",
            defendantEvidenceCID: "",
            status:               DisputeStatus.RAISED,
            ruledForPlaintiff:    false,
            raisedAt:             block.timestamp,
            resolvedAt:           0
        }));

        emit DisputeRaised(disputeId, licenseId, msg.sender);
    }

    /// @notice Submit evidence. Only plaintiff or defendant may call; no time restriction.
    function submitEvidence(uint256 disputeId, string calldata ipfsCID) external {
        Dispute storage d = disputes[disputeId];

        if (msg.sender != d.plaintiff && msg.sender != d.defendant) {
            revert NotPartyToDispute();
        }

        if (msg.sender == d.plaintiff) {
            d.plaintiffEvidenceCID = ipfsCID;
        } else {
            d.defendantEvidenceCID = ipfsCID;
        }

        emit EvidenceSubmitted(disputeId, msg.sender, ipfsCID);
    }

    /// @notice Resolve a dispute. Arbiter only. Must be called after EVIDENCE_PERIOD.
    function resolveDispute(uint256 disputeId, bool ruleForPlaintiff) external onlyArbiter {
        Dispute storage d = disputes[disputeId];

        if (d.status == DisputeStatus.RESOLVED || d.status == DisputeStatus.EXECUTED) {
            revert AlreadyResolved();
        }
        if (block.timestamp <= d.raisedAt + EVIDENCE_PERIOD) {
            revert EvidencePeriodActive();
        }

        d.status            = DisputeStatus.RESOLVED;
        d.ruledForPlaintiff = ruleForPlaintiff;
        d.resolvedAt        = block.timestamp;

        emit DisputeResolved(disputeId, ruleForPlaintiff);
    }

    /// @notice Execute a resolved dispute after TIMELOCK. Revokes license if plaintiff won.
    function executeResolution(uint256 disputeId) external {
        Dispute storage d = disputes[disputeId];

        if (d.status != DisputeStatus.RESOLVED) revert AlreadyResolved();
        if (block.timestamp < d.resolvedAt + TIMELOCK) revert TimelockNotExpired();

        d.status = DisputeStatus.EXECUTED;

        if (d.ruledForPlaintiff) {
            licenseManager.revokeLicense(d.licenseId);
        }

        emit ResolutionExecuted(disputeId);
    }

    /// @notice Transfer arbiter role to a new address.
    function transferArbiter(address newArbiter) external onlyArbiter {
        emit ArbiterTransferred(arbiter, newArbiter);
        arbiter = newArbiter;
    }

    /// @dev Helper to read tierId from LicenseRecord without re-decoding the full tuple.
    function _getTierId(uint256 licenseId) private view returns (uint256) {
        (uint256 tierId, , , , ) = licenseManager.licenses(licenseId);
        return tierId;
    }
}
```

- [ ] **Step 4: Run tests — all must pass**

```bash
cd contracts && forge test --match-contract DisputeArbitratorTest -vvv
```

Expected: all tests pass including fuzz and invariant.

---

## Task 5: Integration Tests

**Files:**
- Create: `contracts/test/Integration.t.sol`

- [ ] **Step 1: Write Integration.t.sol**

`contracts/test/Integration.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPRegistry}        from "../src/IPRegistry.sol";
import {RoyaltyVault}      from "../src/RoyaltyVault.sol";
import {LicenseManager}    from "../src/LicenseManager.sol";
import {DisputeArbitrator} from "../src/DisputeArbitrator.sol";

contract IntegrationTest is Test {
    IPRegistry        registry;
    RoyaltyVault      vault;
    LicenseManager    manager;
    DisputeArbitrator arbitrator;

    address arbiter = makeAddr("arbiter");
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address carol   = makeAddr("carol");

    bytes32 constant FILE_HASH = keccak256("integration_test_file");

    function setUp() public {
        registry   = new IPRegistry();
        vault      = new RoyaltyVault(address(registry));
        manager    = new LicenseManager(address(registry), address(vault));
        arbitrator = new DisputeArbitrator(address(manager), arbiter);
        manager.setDisputeArbitrator(address(arbitrator));

        deal(alice, 100 ether);
        deal(bob,   100 ether);
        deal(carol, 100 ether);
    }

    // ── 1. Full purchase flow ─────────────────────────────────────────────────

    function test_integration_fullPurchaseFlow() public {
        // Register work
        vm.prank(alice);
        registry.registerWork(FILE_HASH, "ipfs://QmTest");

        // Create tier: 0.5 ETH, 1 year
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0.5 ether, 365 days
        );

        // Bob purchases
        vm.prank(bob);
        uint256 licenseId = manager.purchaseLicense{value: 0.5 ether}(tierId);

        // License is valid
        assertTrue(manager.isLicenseValid(licenseId));

        // ETH landed in vault, manager holds nothing
        assertEq(vault.getAccrued(FILE_HASH, alice), 0.5 ether);
        assertEq(address(manager).balance, 0);

        // Alice claims
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.claimRoyalty(FILE_HASH);

        assertEq(alice.balance, before + 0.5 ether);
        assertEq(vault.getAccrued(FILE_HASH, alice), 0);
    }

    // ── 2. Co-owner split flow ────────────────────────────────────────────────

    function test_integration_coOwnerSplitFlow() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, "ipfs://QmTest");

        // Carol is 30% co-owner; alice keeps 70%
        vm.prank(alice);
        registry.addCoOwner(FILE_HASH, carol, 3000);

        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.COMMERCIAL, 1 ether, 0
        );

        vm.prank(bob);
        manager.purchaseLicense{value: 1 ether}(tierId);

        assertEq(vault.getAccrued(FILE_HASH, carol), 0.3 ether);
        assertEq(vault.getAccrued(FILE_HASH, alice), 0.7 ether);

        uint256 carolBefore = carol.balance;
        uint256 aliceBefore = alice.balance;

        vm.prank(carol);
        vault.claimRoyalty(FILE_HASH);
        vm.prank(alice);
        vault.claimRoyalty(FILE_HASH);

        assertEq(carol.balance, carolBefore + 0.3 ether);
        assertEq(alice.balance, aliceBefore + 0.7 ether);
    }

    // ── 3. Full dispute flow ──────────────────────────────────────────────────

    function test_integration_disputeFlow() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, "ipfs://QmTest");
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.PERSONAL, 0, 365 days
        );
        vm.prank(bob);
        uint256 licenseId = manager.purchaseLicense{value: 0}(tierId);
        assertTrue(manager.isLicenseValid(licenseId));

        // Bob raises dispute
        vm.prank(bob);
        uint256 disputeId = arbitrator.raiseDispute(licenseId);

        // Both submit evidence within 72h
        vm.prank(bob);
        arbitrator.submitEvidence(disputeId, "ipfs://QmPlaintiff");
        vm.prank(alice);
        arbitrator.submitEvidence(disputeId, "ipfs://QmDefendant");

        // Evidence period ends
        vm.warp(block.timestamp + 73 hours);

        // Arbiter rules for plaintiff (bob)
        vm.prank(arbiter);
        arbitrator.resolveDispute(disputeId, true);

        // Timelock passes
        vm.warp(block.timestamp + 49 hours);

        // Anyone can execute
        arbitrator.executeResolution(disputeId);

        // License is revoked
        assertFalse(manager.isLicenseValid(licenseId));
    }

    // ── 4. Exclusive license guard ────────────────────────────────────────────

    function test_integration_exclusiveLicenseCannotBeSoldTwice() public {
        vm.prank(alice);
        registry.registerWork(FILE_HASH, "ipfs://QmTest");
        vm.prank(alice);
        uint256 tierId = manager.createLicenseTier(
            FILE_HASH, LicenseManager.LicenseScope.EXCLUSIVE, 0.1 ether, 0
        );

        // Bob buys the exclusive license
        vm.prank(bob);
        manager.purchaseLicense{value: 0.1 ether}(tierId);

        // Carol tries to buy the same exclusive tier — must revert
        vm.expectRevert(LicenseManager.ExclusiveLicenseSold.selector);
        vm.prank(carol);
        manager.purchaseLicense{value: 0.1 ether}(tierId);

        // Bob's license is still valid
        uint256[] memory bobLicenses = manager.getLicensesByLicensee(bob);
        assertTrue(manager.isLicenseValid(bobLicenses[0]));
    }
}
```

- [ ] **Step 2: Run integration tests**

```bash
cd contracts && forge test --match-contract IntegrationTest -vvv
```

Expected: all 4 tests pass.

---

## Task 6: Deploy Script

**Files:**
- Create: `contracts/script/Deploy.s.sol`

- [ ] **Step 1: Write Deploy.s.sol**

`contracts/script/Deploy.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPRegistry}        from "../src/IPRegistry.sol";
import {RoyaltyVault}      from "../src/RoyaltyVault.sol";
import {LicenseManager}    from "../src/LicenseManager.sol";
import {DisputeArbitrator} from "../src/DisputeArbitrator.sol";

contract Deploy is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        // Defaults to deployer; override ARBITER_ADDRESS for production multi-sig
        address arbiter  = vm.envOr("ARBITER_ADDRESS", deployer);

        vm.startBroadcast(deployer);

        IPRegistry        registry   = new IPRegistry();
        RoyaltyVault      vault      = new RoyaltyVault(address(registry));
        LicenseManager    manager    = new LicenseManager(address(registry), address(vault));
        DisputeArbitrator arbitrator = new DisputeArbitrator(address(manager), arbiter);

        manager.setDisputeArbitrator(address(arbitrator));

        vm.stopBroadcast();

        console2.log("=== LexMint Deployment ===");
        console2.log("Network:           Sepolia");
        console2.log("IPRegistry:        ", address(registry));
        console2.log("RoyaltyVault:      ", address(vault));
        console2.log("LicenseManager:    ", address(manager));
        console2.log("DisputeArbitrator: ", address(arbitrator));
        console2.log("Arbiter:           ", arbiter);
    }
}
```

- [ ] **Step 2: Verify build is clean**

```bash
cd contracts && forge build
```

Expected: `Compiler run successful` with zero errors and zero warnings.

- [ ] **Step 3: Run full test suite with gas report**

```bash
cd contracts && forge test --gas-report
```

Expected: all tests pass. Note down any functions with high gas usage for README.

- [ ] **Step 4: Run coverage**

```bash
cd contracts && forge coverage 2>/dev/null | tail -20
```

Expected: line coverage >80% across all four contracts.

---

## Post-Implementation Steps

After all tasks complete and tests pass:

- [ ] Copy ABIs to frontend:

```bash
cp contracts/out/IPRegistry.sol/IPRegistry.json              frontend/src/lib/abis/
cp contracts/out/RoyaltyVault.sol/RoyaltyVault.json          frontend/src/lib/abis/
cp contracts/out/LicenseManager.sol/LicenseManager.json      frontend/src/lib/abis/
cp contracts/out/DisputeArbitrator.sol/DisputeArbitrator.json frontend/src/lib/abis/
```

- [ ] Update `CLAUDE.md` checklist — mark Phase 1 items complete.

- [ ] To deploy to Sepolia, run:

```bash
cd contracts && forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

Set env: `DEPLOYER_ADDRESS`, `SEPOLIA_RPC_URL`, `PRIVATE_KEY`, optionally `ARBITER_ADDRESS`.
