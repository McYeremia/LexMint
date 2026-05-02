# LexMint — On-chain IP Registry & License Protocol

> Submission for the Blockchain Legal Institute Global Legal Hackathon
> Built with Foundry · Next.js 14 · Node.js · Sepolia Testnet

LexMint is a full-stack Web3 platform that allows creators to register intellectual property on-chain, issue licenses to users, and receive royalty payments automatically — with no middlemen, no manual invoices, and cryptographic proof of ownership that can be verified by anyone, including legal institutions.

---

## The Problem

Existing IP and copyright systems rely on slow, expensive, and jurisdiction-limited centralized authorities. Independent creators — musicians, writers, designers — often lack affordable access to legal protection. Licensees pay royalties manually, which is error-prone and untransparent. LexMint replaces this with immutable, self-enforcing smart contracts on Ethereum.

---

## Architecture

```
lexmint/
├── contracts/          # Foundry project (Solidity smart contracts)
├── backend/            # Node.js + Fastify (event indexer, API, IPFS)
└── frontend/           # Next.js 14 App Router (dApp UI)
```

### Smart Contracts (Foundry · Sepolia)

| Contract | Responsibility |
|---|---|
| `IPRegistry.sol` | Register works by hash fingerprint, track ownership, co-owners |
| `LicenseManager.sol` | Create license tiers, purchase licenses, check validity |
| `RoyaltyVault.sol` | Collect royalty payments, split among co-owners, withdraw |
| `DisputeArbitrator.sol` | Raise disputes, submit evidence, timelock resolution |

### Backend (Node.js + Fastify)

- **Event indexer** — listens to all contract events and stores to PostgreSQL
- **Royalty cron job** — checks and triggers recurring royalty pulls
- **IPFS metadata API** — uploads and retrieves work metadata via Pinata
- **REST API** — serves indexed data to frontend for fast queries

### Frontend (Next.js 14)

- **Creator dashboard** — register works, create license tiers, track royalties
- **License marketplace** — browse and purchase licenses for any registered work
- **Verification portal** — upload any file and verify on-chain ownership and license status
- **Royalty tracker** — real-time view of accumulated royalties per work

---

## Tech Stack

**Smart Contracts**
- Solidity `^0.8.24`
- Foundry (forge, cast, anvil)
- OpenZeppelin Contracts v5

**Backend**
- Node.js 20 LTS
- Fastify
- ethers.js v6
- PostgreSQL + Prisma ORM
- Pinata SDK (IPFS)
- node-cron

**Frontend**
- Next.js 14 (App Router)
- TypeScript
- Tailwind CSS
- wagmi v2 + viem
- RainbowKit
- TanStack Query v5

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Node.js 20+ installed
- PostgreSQL running locally
- A Sepolia RPC URL (Alchemy or Infura)
- A Pinata account for IPFS

### 1. Clone and install

```bash
git clone https://github.com/yourusername/lexmint.git
cd lexmint
```

### 2. Smart Contracts

```bash
cd contracts
forge install
forge build
forge test
```

Deploy to Sepolia:

```bash
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

### 3. Backend

```bash
cd backend
cp .env.example .env
# Fill in .env values
npm install
npx prisma migrate dev
npm run dev
```

### 4. Frontend

```bash
cd frontend
cp .env.local.example .env.local
# Fill in contract addresses and RPC URL
npm install
npm run dev
```

Frontend runs on `http://localhost:3000`

---

## Environment Variables

### contracts/.env

```
SEPOLIA_RPC_URL=
PRIVATE_KEY=
ETHERSCAN_API_KEY=
```

### backend/.env

```
DATABASE_URL=postgresql://user:password@localhost:5432/lexmint
SEPOLIA_RPC_URL=
IP_REGISTRY_ADDRESS=
LICENSE_MANAGER_ADDRESS=
ROYALTY_VAULT_ADDRESS=
DISPUTE_ARBITRATOR_ADDRESS=
PINATA_API_KEY=
PINATA_SECRET_KEY=
PORT=4000
```

### frontend/.env.local

```
NEXT_PUBLIC_IP_REGISTRY_ADDRESS=
NEXT_PUBLIC_LICENSE_MANAGER_ADDRESS=
NEXT_PUBLIC_ROYALTY_VAULT_ADDRESS=
NEXT_PUBLIC_DISPUTE_ARBITRATOR_ADDRESS=
NEXT_PUBLIC_SEPOLIA_RPC_URL=
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=
NEXT_PUBLIC_API_URL=http://localhost:4000
```

---

## Smart Contract Design

### IPRegistry.sol

Stores a mapping from `keccak256(fileHash)` → `WorkRecord`. Anyone can verify a file's registration status. Only the registered owner can transfer ownership or add co-owners.

Key events: `WorkRegistered`, `OwnershipTransferred`, `CoOwnerAdded`

### LicenseManager.sol

Reads from `IPRegistry` to verify ownership before license creation. Supports three scopes: `PERSONAL`, `COMMERCIAL`, `EXCLUSIVE`. Exclusive licenses can only be sold once. License validity is time-based using `block.timestamp`.

Key events: `LicenseCreated`, `LicensePurchased`, `LicenseRevoked`

### RoyaltyVault.sol

Uses a pull-payment pattern — royalties accumulate in the contract, owners withdraw on demand. For co-owned works, royalties are split proportionally using basis points (10000 = 100%). Prevents reentrancy with OpenZeppelin's `ReentrancyGuard`.

Key events: `RoyaltyDeposited`, `RoyaltyClaimed`, `SplitConfigured`

### DisputeArbitrator.sol

Either party in a license agreement can raise a dispute. Both parties submit evidence as IPFS CIDs within a 72-hour window. A designated arbiter (initially an EOA, upgradeable to DAO) resolves the dispute, which is subject to a 48-hour timelock before execution.

Key events: `DisputeRaised`, `EvidenceSubmitted`, `DisputeResolved`

---

## Foundry Test Coverage

```bash
cd contracts
forge test -vv               # run all tests
forge coverage               # generate coverage report
forge test --match-contract IPRegistryTest -vvv   # specific contract
```

Test categories:
- **Unit** — happy path and revert conditions for every function
- **Fuzz** — `forge-std` fuzz inputs for royalty amounts, durations, percentages
- **Invariant** — vault solvency, license validity consistency, ownership integrity
- **Fork** — fork Sepolia to test real ERC-20 interactions and `vm.warp` for time-based logic

---

## License

MIT — see [LICENSE](./LICENSE)
