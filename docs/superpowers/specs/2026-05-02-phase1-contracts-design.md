# LexMint Phase 1 — Smart Contracts Design

**Date:** 2026-05-02  
**Scope:** IPRegistry.sol, LicenseManager.sol, RoyaltyVault.sol, DisputeArbitrator.sol  
**Framework:** Foundry + OpenZeppelin  
**Target network:** Ethereum Sepolia

---

## Section 1: Arsitektur & Dependency Graph

### Deploy Order

```
1. IPRegistry          — tidak ada dependency
2. LicenseManager      — butuh IPRegistry address
3. RoyaltyVault        — butuh IPRegistry address
4. DisputeArbitrator   — butuh LicenseManager address
```

> RoyaltyVault tidak butuh LicenseManager address karena `depositRoyalty()` bersifat public.

### Call Flow

**Purchase lisensi:**
```
User → LicenseManager.purchaseLicense()
         └→ IPRegistry.verifyWork()         [read: cek work exists]
         └→ RoyaltyVault.depositRoyalty()   [forward ETH, split ke co-owners]
```

**Klaim royalti:**
```
Owner → RoyaltyVault.claimRoyalty()
          └→ transfer accrued[workHash][msg.sender] ke caller
```

**Dispute:**
```
User    → DisputeArbitrator.raiseDispute()
Evidence period (72 jam) → submit evidence oleh plaintiff/defendant
Arbiter → DisputeArbitrator.resolveDispute()
Timelock (48 jam) berlalu
Anyone  → DisputeArbitrator.executeResolution()
            └→ LicenseManager.revokeLicense()  [jika ruled for plaintiff]
```

### foundry.toml

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

---

## Section 2: Keputusan Desain

### Arbiter (DisputeArbitrator)
- Set di konstruktor, default = deployer wallet
- Ada `transferArbiter(address newArbiter)` untuk upgrade ke multi-sig/DAO di masa depan

### Royalty Split (RoyaltyVault)
- Split langsung saat `depositRoyalty()` dipanggil
- `accrued[workHash][coOwner]` di-update untuk tiap co-owner sesuai `splitBps` dari IPRegistry
- Klaim menjadi O(1): co-owner ambil angka yang sudah ada

### ETH Flow saat Purchase Lisensi
- `LicenseManager.purchaseLicense()` otomatis forward 100% ETH ke `RoyaltyVault.depositRoyalty()`
- Satu transaksi, tidak ada langkah manual
- ETH tidak pernah tersimpan di LicenseManager

### depositRoyalty() Access
- **PUBLIC** — tidak ada `onlyLicenseManager` restriction
- Siapapun bisa deposit: LicenseManager, creator sendiri, sponsor, dll
- Aman karena fungsi hanya menerima ETH, tidak mengeluarkan

### Dispute Resolution
- Royalti yang sudah masuk vault **tidak dikembalikan** jika dispute dimenangkan plaintiff
- Hanya lisensi yang di-revoke via `LicenseManager.revokeLicense()`
- Royalti sebelum dispute dianggap terbayar sah

### Arsitektur: Tight Coupling (Direct Calls)
- Setiap contract memanggil contract lain langsung via interface
- Fully on-chain, tidak ada ketergantungan pada backend
- Address contract di-pass saat konstruktor

---

## Section 3: Contract Interfaces

### IPRegistry.sol

```solidity
struct WorkRecord {
    bytes32 fileHash;
    address owner;
    address[] coOwners;
    uint256[] splits;       // basis points, harus sum ke 10000
    uint256 registeredAt;
    string metadataURI;
    bool exists;
}

mapping(bytes32 => WorkRecord) public works;
mapping(address => bytes32[]) public ownerWorks;

function registerWork(bytes32 fileHash, string calldata metadataURI) external;
function transferOwnership(bytes32 fileHash, address newOwner) external;
function addCoOwner(bytes32 fileHash, address coOwner, uint256 splitBps) external;
function verifyWork(bytes32 fileHash) external view returns (WorkRecord memory);
function getWorksByOwner(address owner) external view returns (bytes32[] memory);
```

### LicenseManager.sol

```solidity
enum LicenseScope { PERSONAL, COMMERCIAL, EXCLUSIVE }

struct LicenseTier {
    bytes32 workHash;
    LicenseScope scope;
    uint256 priceWei;
    uint256 duration;       // detik, 0 = perpetual
    bool isActive;
}

struct LicenseRecord {
    uint256 tierId;
    address licensee;
    uint256 purchasedAt;
    uint256 expiresAt;      // 0 = perpetual
    bool isRevoked;
}

function createLicenseTier(bytes32 workHash, LicenseScope scope, uint256 priceWei, uint256 duration) external returns (uint256 tierId);
function purchaseLicense(uint256 tierId) external payable returns (uint256 licenseId);
function revokeLicense(uint256 licenseId) external;  // hanya work owner ATAU DisputeArbitrator contract address
function isLicenseValid(uint256 licenseId) external view returns (bool);
function getLicensesByLicensee(address licensee) external view returns (uint256[] memory);
```

### RoyaltyVault.sol

```solidity
mapping(bytes32 => uint256) public vaultBalance;
mapping(bytes32 => mapping(address => uint256)) public accrued;

function depositRoyalty(bytes32 workHash) external payable;   // public
function claimRoyalty(bytes32 workHash) external nonReentrant;
function getAccrued(bytes32 workHash, address owner) external view returns (uint256);
```

### DisputeArbitrator.sol

```solidity
enum DisputeStatus { RAISED, EVIDENCE_PERIOD, RESOLVED, EXECUTED }

struct Dispute {
    uint256 licenseId;
    address plaintiff;
    address defendant;
    string plaintiffEvidenceCID;
    string defendantEvidenceCID;
    DisputeStatus status;
    bool ruledForPlaintiff;
    uint256 raisedAt;
    uint256 resolvedAt;
}

uint256 public constant EVIDENCE_PERIOD = 72 hours;
uint256 public constant TIMELOCK = 48 hours;
address public arbiter;

function raiseDispute(uint256 licenseId) external returns (uint256 disputeId);
function submitEvidence(uint256 disputeId, string calldata ipfsCID) external;
function resolveDispute(uint256 disputeId, bool ruleForPlaintiff) external;  // onlyArbiter
function executeResolution(uint256 disputeId) external;
function transferArbiter(address newArbiter) external;  // onlyArbiter
```

---

## Section 4: Testing Strategy

### Unit Tests (per contract `.t.sol`)

| Contract | Happy path | Revert cases | Fuzz | Invariant |
|----------|-----------|--------------|------|-----------|
| IPRegistry | registerWork, transfer, addCoOwner, verify | AlreadyRegistered, NotOwner, InvalidSplit | ✓ (2) | ✓ (1) |
| LicenseManager | createTier, purchase, revoke, isValid | WorkNotRegistered, InsufficientPayment, ExclusiveLicenseSold | ✓ (2) | ✓ (1) |
| RoyaltyVault | deposit, claim, getAccrued | NothingToClaim, WorkNotFound | ✓ (2) | ✓ (1) |
| DisputeArbitrator | raise, evidence, resolve, execute, transferArbiter | NotArbiter, TimelockNotExpired, AlreadyResolved | ✓ (2) | ✓ (1) |

### Integration Tests (`test/Integration.t.sol`)

1. **Full purchase flow** — register work → buat tier → beli lisensi → verifikasi royalti masuk vault → klaim royalti
2. **Co-owner split flow** — register dengan 2 co-owner (split 70/30) → deposit → verifikasi proporsi → klaim dari 2 address
3. **Dispute flow** — beli lisensi → raise dispute → submit evidence → resolve → execute → verifikasi lisensi direvoke
4. **Exclusive license guard** — beli EXCLUSIVE → coba beli lagi → revert `ExclusiveLicenseSold`

---

## Section 5: Error Handling & Events

### Custom Errors

```solidity
// IPRegistry
error AlreadyRegistered();
error NotOwner();
error InvalidSplit();

// LicenseManager
error WorkNotRegistered();
error NotWorkOwner();
error InsufficientPayment();
error ExclusiveLicenseSold();
error TierNotActive();
error LicenseRevoked();

// RoyaltyVault
error NothingToClaim();
error WorkNotFound();

// DisputeArbitrator
error NotArbiter();
error EvidencePeriodActive();
error TimelockNotExpired();
error AlreadyResolved();
error NotPartyToDispute();
```

### Events

```solidity
// IPRegistry
event WorkRegistered(bytes32 indexed fileHash, address indexed owner, string metadataURI);
event OwnershipTransferred(bytes32 indexed fileHash, address indexed from, address indexed to);
event CoOwnerAdded(bytes32 indexed fileHash, address coOwner, uint256 splitBps);

// LicenseManager
event LicenseCreated(uint256 indexed tierId, bytes32 indexed workHash, LicenseScope scope);
event LicensePurchased(uint256 indexed licenseId, uint256 indexed tierId, address indexed licensee);
event LicenseRevoked(uint256 indexed licenseId);

// RoyaltyVault
event RoyaltyDeposited(bytes32 indexed workHash, address indexed from, uint256 amount);
event RoyaltyClaimed(bytes32 indexed workHash, address indexed owner, uint256 amount);

// DisputeArbitrator
event DisputeRaised(uint256 indexed disputeId, uint256 indexed licenseId, address plaintiff);
event EvidenceSubmitted(uint256 indexed disputeId, address submitter, string ipfsCID);
event DisputeResolved(uint256 indexed disputeId, bool ruledForPlaintiff);
event ResolutionExecuted(uint256 indexed disputeId);
event ArbiterTransferred(address indexed oldArbiter, address indexed newArbiter);
```

---

## Checklist Implementation

- [ ] Update `foundry.toml` dengan solc, optimizer, remappings
- [ ] Tulis `IPRegistry.sol` + `IPRegistry.t.sol`
- [ ] Tulis `LicenseManager.sol` + `LicenseManager.t.sol`
- [ ] Tulis `RoyaltyVault.sol` + `RoyaltyVault.t.sol`
- [ ] Tulis `DisputeArbitrator.sol` + `DisputeArbitrator.t.sol`
- [ ] Tulis `Integration.t.sol`
- [ ] Tulis `Deploy.s.sol`
- [ ] `forge build` — zero warnings
- [ ] `forge test --gas-report` — semua pass
- [ ] `forge coverage` — target >80%
- [ ] Copy ABI ke `frontend/src/lib/abis/`
