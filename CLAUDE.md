# CLAUDE.md — LexMint Project Instructions

This file is the single source of truth for Claude Code working on this project.
Read this entire file before doing anything. Never skip sections.

---

## What This Project Is

LexMint is a full-stack Web3 legal tech platform for the Blockchain Legal Institute Hackathon.
It lets creators register intellectual property on-chain (Ethereum Sepolia), issue licenses,
and receive royalties automatically via smart contracts. There is no admin, no middleman —
everything is enforced by code.

The project has three layers that must be built in this order:

1. Smart contracts (Foundry) → 2. Backend (Node.js) → 3. Frontend (Next.js)

---

## Project Structure

```
lexmint/
├── CLAUDE.md                  ← you are here
├── README.md
├── contracts/                 ← Foundry project
│   ├── foundry.toml
│   ├── src/
│   │   ├── IPRegistry.sol
│   │   ├── LicenseManager.sol
│   │   ├── RoyaltyVault.sol
│   │   └── DisputeArbitrator.sol
│   ├── test/
│   │   ├── IPRegistry.t.sol
│   │   ├── LicenseManager.t.sol
│   │   ├── RoyaltyVault.t.sol
│   │   └── DisputeArbitrator.t.sol
│   ├── script/
│   │   └── Deploy.s.sol
│   └── lib/                   ← forge install puts deps here
├── backend/
│   ├── package.json
│   ├── prisma/
│   │   └── schema.prisma
│   ├── src/
│   │   ├── index.ts           ← Fastify server entry
│   │   ├── indexer/
│   │   │   └── events.ts      ← ethers.js event listener
│   │   ├── routes/
│   │   │   ├── works.ts
│   │   │   ├── licenses.ts
│   │   │   └── royalties.ts
│   │   ├── jobs/
│   │   │   └── royaltyCron.ts
│   │   └── lib/
│   │       ├── db.ts          ← Prisma client singleton
│   │       ├── ipfs.ts        ← Pinata SDK wrapper
│   │       └── contracts.ts   ← ethers contract instances
│   └── .env.example
└── frontend/
    ├── package.json
    ├── next.config.ts
    ├── tailwind.config.ts
    ├── tsconfig.json
    └── src/
        ├── app/
        │   ├── layout.tsx         ← root layout, RainbowKit provider
        │   ├── page.tsx           ← landing page
        │   ├── dashboard/
        │   │   └── page.tsx       ← creator dashboard
        │   ├── marketplace/
        │   │   └── page.tsx       ← license marketplace
        │   ├── verify/
        │   │   └── page.tsx       ← public verification portal
        │   └── royalties/
        │       └── page.tsx       ← royalty tracker
        ├── components/
        │   ├── ui/                ← reusable primitives (Button, Card, Badge)
        │   ├── WorkCard.tsx
        │   ├── LicenseCard.tsx
        │   ├── RegisterWorkForm.tsx
        │   ├── VerifyFileDropzone.tsx
        │   └── RoyaltyChart.tsx
        ├── hooks/
        │   ├── useIPRegistry.ts   ← wagmi hooks for IPRegistry.sol
        │   ├── useLicenseManager.ts
        │   └── useRoyaltyVault.ts
        ├── lib/
        │   ├── abis/              ← copy ABI JSONs here after forge build
        │   │   ├── IPRegistry.json
        │   │   ├── LicenseManager.json
        │   │   ├── RoyaltyVault.json
        │   │   └── DisputeArbitrator.json
        │   ├── contracts.ts       ← contract addresses + wagmi config
        │   └── utils.ts           ← shared helpers (formatAddress, etc.)
        └── providers/
            └── Web3Provider.tsx   ← wagmi + RainbowKit setup
```

---

## Build Order — Follow This Exactly

### Phase 1: Smart Contracts

**Step 1.1 — Initialize Foundry**

```bash
mkdir contracts && cd contracts
forge init --no-git
forge install OpenZeppelin/openzeppelin-contracts --no-git
```

Update `foundry.toml`:

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

**Step 1.2 — Write contracts in this order**

Build each contract fully before moving to the next:

1. `IPRegistry.sol` — no dependencies on other LexMint contracts
2. `LicenseManager.sol` — imports IPRegistry interface
3. `RoyaltyVault.sol` — imports IPRegistry interface
4. `DisputeArbitrator.sol` — imports LicenseManager interface

**Step 1.3 — Write tests alongside each contract**

Every contract must have a corresponding `.t.sol` file with:

- Unit tests for every public function (happy path + revert cases)
- At least 2 fuzz test functions using `forge-std`
- At least 1 invariant test

Run after each contract:

```bash
forge test --match-contract <ContractName>Test -vvv
forge coverage
```

**Step 1.4 — Write deployment script**

`script/Deploy.s.sol` must deploy all four contracts in dependency order
and log all addresses. Use `vm.startBroadcast()` / `vm.stopBroadcast()`.

After deployment, copy ABIs from `contracts/out/<Name>.sol/<Name>.json`
to `frontend/src/lib/abis/` and update addresses in `frontend/src/lib/contracts.ts`.

---

### Phase 2: Backend

**Step 2.1 — Initialize**

```bash
cd ../backend
npm init -y
npm install fastify ethers @prisma/client pinata-web3 node-cron dotenv
npm install -D typescript ts-node @types/node nodemon prisma
npx tsc --init
npx prisma init
```

**Step 2.2 — Prisma schema**

Define these models in `prisma/schema.prisma`:

- `Work` — mirrors on-chain WorkRecord (hash, owner, title, ipfsCid, registeredAt, txHash)
- `License` — (workId, licensee, scope, expiresAt, txHash, isActive)
- `RoyaltyEvent` — (workId, from, amount, txHash, timestamp)
- `Dispute` — (licenseId, plaintiff, defendant, status, resolvedAt)

**Step 2.3 — Event indexer**

`src/indexer/events.ts` must:

- Connect to Sepolia via `ethers.JsonRpcProvider`
- Listen to events from all four contracts
- On `WorkRegistered` → upsert `Work` in DB
- On `LicensePurchased` → upsert `License` in DB
- On `RoyaltyDeposited` → insert `RoyaltyEvent` in DB
- Handle reconnection on provider disconnect
- Store last processed block in DB to resume after restart

**Step 2.4 — REST API routes**

```
GET  /works                    → paginated list of registered works
GET  /works/:hash              → single work by file hash
GET  /works/:hash/licenses     → all licenses for a work
GET  /works/:hash/royalties    → royalty history for a work
GET  /licenses/:address        → all licenses owned by an address
GET  /royalties/:address       → creator royalty summary
POST /metadata                 → upload metadata to IPFS via Pinata
```

**Step 2.5 — Run backend**

```bash
npx prisma migrate dev --name init
npm run dev
```

Backend must run on port 4000.

---

### Phase 3: Frontend

**Step 3.1 — Initialize Next.js**

```bash
cd ../frontend
npx create-next-app@latest . \
  --typescript \
  --eslint \
  --tailwind \
  --app \
  --src-dir \
  --no-import-alias
```

When prompted, answer exactly:

- TypeScript → Yes
- ESLint → Yes
- Tailwind CSS → Yes
- App Router → Yes
- src/ directory → Yes
- import alias → No (keep default @/\*)

**Step 3.2 — Install Web3 dependencies**

```bash
npm install wagmi viem @rainbow-me/rainbowkit @tanstack/react-query
```

**Step 3.3 — Web3Provider setup**

`src/providers/Web3Provider.tsx` must:

- Configure wagmi with Sepolia chain only
- Use RainbowKit for wallet connection UI
- Wrap with TanStack Query's QueryClientProvider
- Export a `Web3Provider` component that wraps all three

`src/app/layout.tsx` must:

- Be a Server Component
- Import and use `Web3Provider`
- Note: `'use client'` goes in Web3Provider, NOT in layout.tsx

**Step 3.4 — Contract hooks**

Each hook in `src/hooks/` must use wagmi's `useReadContract` / `useWriteContract`.
Never call ethers.js directly in frontend — use wagmi + viem only.

Example pattern for `useIPRegistry.ts`:

```typescript
import { useWriteContract, useReadContract } from "wagmi";
import { IP_REGISTRY_ABI, IP_REGISTRY_ADDRESS } from "@/lib/contracts";

export function useRegisterWork() {
  return useWriteContract();
}

export function useVerifyWork(fileHash: `0x${string}`) {
  return useReadContract({
    address: IP_REGISTRY_ADDRESS,
    abi: IP_REGISTRY_ABI,
    functionName: "verifyWork",
    args: [fileHash],
  });
}
```

**Step 3.5 — Pages to build (in order)**

1. `verify/page.tsx` — build this FIRST, it's the best demo piece
   - File dropzone that hashes client-side with `crypto.subtle.digest`
   - Calls `verifyWork()` on-chain via wagmi
   - Shows owner address, registration date, active licenses
   - No wallet connection required to use this page

2. `marketplace/page.tsx` — browse all works from backend API
   - Grid of WorkCards fetched from `GET /works`
   - Each card shows title, owner (truncated), available license tiers
   - Clicking a license tier triggers `purchaseLicense()` via wagmi

3. `dashboard/page.tsx` — protected, wallet connection required
   - Show all works registered by connected wallet
   - RegisterWorkForm: file upload → client hash → `registerWork()`
   - CreateLicenseForm: set tier name, price, duration, scope
   - Royalty summary fetched from `GET /royalties/:address`

4. `royalties/page.tsx` — royalty history and withdraw
   - Chart of royalty income over time (use Recharts or a simple SVG)
   - Per-work breakdown
   - Withdraw button calls `claimRoyalty()` via wagmi

---

## Smart Contract Specifications

### IPRegistry.sol

```solidity
struct WorkRecord {
    bytes32 fileHash;       // keccak256 of the original file bytes
    address owner;
    address[] coOwners;
    uint256[] splits;       // basis points, must sum to 10000
    uint256 registeredAt;
    string metadataURI;     // IPFS URI to title, description, category
    bool exists;
}

mapping(bytes32 => WorkRecord) public works;
mapping(address => bytes32[]) public ownerWorks;

event WorkRegistered(bytes32 indexed fileHash, address indexed owner, string metadataURI);
event OwnershipTransferred(bytes32 indexed fileHash, address indexed from, address indexed to);
event CoOwnerAdded(bytes32 indexed fileHash, address coOwner, uint256 splitBps);

function registerWork(bytes32 fileHash, string calldata metadataURI) external;
function transferOwnership(bytes32 fileHash, address newOwner) external;
function addCoOwner(bytes32 fileHash, address coOwner, uint256 splitBps) external;
function verifyWork(bytes32 fileHash) external view returns (WorkRecord memory);
function getWorksByOwner(address owner) external view returns (bytes32[] memory);
```

Reverts:

- `AlreadyRegistered()` — if `works[fileHash].exists == true`
- `NotOwner()` — if caller is not `works[fileHash].owner`
- `InvalidSplit()` — if splits don't sum to 10000

### LicenseManager.sol

```solidity
enum LicenseScope { PERSONAL, COMMERCIAL, EXCLUSIVE }

struct LicenseTier {
    bytes32 workHash;
    LicenseScope scope;
    uint256 priceWei;
    uint256 duration;       // in seconds, 0 = perpetual
    bool isActive;
}

struct LicenseRecord {
    uint256 tierId;
    address licensee;
    uint256 purchasedAt;
    uint256 expiresAt;      // 0 = perpetual
    bool isRevoked;
}

event LicenseCreated(uint256 indexed tierId, bytes32 indexed workHash, LicenseScope scope);
event LicensePurchased(uint256 indexed licenseId, uint256 indexed tierId, address indexed licensee);
event LicenseRevoked(uint256 indexed licenseId);

function createLicenseTier(bytes32 workHash, LicenseScope scope, uint256 priceWei, uint256 duration) external returns (uint256 tierId);
function purchaseLicense(uint256 tierId) external payable returns (uint256 licenseId);
function revokeLicense(uint256 licenseId) external;
function isLicenseValid(uint256 licenseId) external view returns (bool);
function getLicensesByLicensee(address licensee) external view returns (uint256[] memory);
```

Reverts:

- `WorkNotRegistered()` — if IPRegistry.verifyWork returns empty
- `NotWorkOwner()` — if caller doesn't own the work
- `InsufficientPayment()` — if `msg.value < tier.priceWei`
- `ExclusiveLicenseSold()` — if EXCLUSIVE tier already purchased

### RoyaltyVault.sol

```solidity
mapping(bytes32 => uint256) public vaultBalance;          // workHash → total ETH
mapping(bytes32 => mapping(address => uint256)) public accrued;  // workHash → owner → claimable ETH

event RoyaltyDeposited(bytes32 indexed workHash, address indexed from, uint256 amount);
event RoyaltyClaimed(bytes32 indexed workHash, address indexed owner, uint256 amount);

function depositRoyalty(bytes32 workHash) external payable;
function claimRoyalty(bytes32 workHash) external nonReentrant;
function getAccrued(bytes32 workHash, address owner) external view returns (uint256);
```

Notes:

- `depositRoyalty` reads co-owner splits from `IPRegistry` and splits `msg.value` proportionally
- `claimRoyalty` sends `accrued[workHash][msg.sender]` to caller and zeroes the balance
- Must import `ReentrancyGuard` from OpenZeppelin

### DisputeArbitrator.sol

```solidity
enum DisputeStatus { RAISED, EVIDENCE_PERIOD, RESOLVED, EXECUTED }

struct Dispute {
    uint256 licenseId;
    address plaintiff;
    address defendant;
    string plaintiffEvidenceCID;   // IPFS CID
    string defendantEvidenceCID;   // IPFS CID
    DisputeStatus status;
    bool ruledForPlaintiff;
    uint256 raisedAt;
    uint256 resolvedAt;
}

uint256 public constant EVIDENCE_PERIOD = 72 hours;
uint256 public constant TIMELOCK = 48 hours;
address public arbiter;

event DisputeRaised(uint256 indexed disputeId, uint256 indexed licenseId, address plaintiff);
event EvidenceSubmitted(uint256 indexed disputeId, address submitter, string ipfsCID);
event DisputeResolved(uint256 indexed disputeId, bool ruledForPlaintiff);
event ResolutionExecuted(uint256 indexed disputeId);

function raiseDispute(uint256 licenseId) external returns (uint256 disputeId);
function submitEvidence(uint256 disputeId, string calldata ipfsCID) external;
function resolveDispute(uint256 disputeId, bool ruleForPlaintiff) external onlyArbiter;
function executeResolution(uint256 disputeId) external;
```

---

## Coding Standards

### Solidity

- Solidity version: `^0.8.24` on all files
- All errors use custom errors, not `require(condition, "string")`
- All state-changing functions emit events
- NatSpec comments on all public functions (`@notice`, `@param`, `@return`)
- No magic numbers — use named constants
- Follow checks-effects-interactions pattern strictly

### TypeScript (backend + frontend)

- No `any` types — ever
- Use `zod` for runtime validation on all API inputs
- All async functions must have try/catch or proper error propagation
- Prefer named exports over default exports (except Next.js pages/layouts)

### Git commits (for GitHub portfolio)

- One commit per major feature: "feat: add IPRegistry.sol with unit tests"
- Always commit passing tests, never broken code
- Keep `forge coverage` output in a `coverage/` folder and link from README

---

## Common Mistakes to Avoid

1. Do NOT use `ethers.js` in the frontend — use `wagmi` + `viem` only
2. Do NOT put `'use client'` in `app/layout.tsx` — only in client components
3. Do NOT hardcode contract addresses — always use environment variables
4. Do NOT skip writing tests before marking a contract as done
5. Do NOT forget to copy ABI files to `frontend/src/lib/abis/` after `forge build`
6. Do NOT call `claimRoyalty` without `nonReentrant` modifier
7. Do NOT allow EXCLUSIVE licenses to be sold more than once — check in `purchaseLicense`

---

## Verification Portal — Priority Demo Feature

This is the most impressive feature for hackathon judges. Build it first.
It requires NO wallet connection and demonstrates the core value proposition:
"Upload any file and instantly know if it is registered on-chain."

Flow:

1. User drops a file onto the dropzone
2. Frontend hashes file bytes using `window.crypto.subtle.digest('SHA-256', fileBuffer)`
3. Convert hash to `bytes32` hex string
4. Call `verifyWork(bytes32)` via wagmi `useReadContract`
5. If result exists: display owner address, registration date, metadata, active licenses
6. If not found: display "This work has not been registered on LexMint"

This must work on mobile, work without MetaMask, and respond in under 3 seconds.

---

## Current Status

- [ ] Phase 1: Smart Contracts
  - [ ] IPRegistry.sol + tests
  - [ ] LicenseManager.sol + tests
  - [ ] RoyaltyVault.sol + tests
  - [ ] DisputeArbitrator.sol + tests
  - [ ] Deploy.s.sol
  - [ ] Deployed to Sepolia
- [ ] Phase 2: Backend
  - [ ] Prisma schema + migration
  - [ ] Event indexer
  - [ ] REST API routes
  - [ ] IPFS integration
- [ ] Phase 3: Frontend
  - [ ] Web3Provider setup
  - [ ] Verification portal
  - [ ] License marketplace
  - [ ] Creator dashboard
  - [ ] Royalty tracker

Update this checklist as tasks are completed.

Either Claude Code or Gemini CLI has done a tasks, please update the checklist. So Claude Code or Gemini CLI should update the checklist on CLAUDE.md and GEMINI.md.
