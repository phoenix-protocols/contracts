# Phoenix Protocol Smart Contracts

A comprehensive DeFi ecosystem built on Ethereum/Arbitrum, featuring stablecoin operations, yield farming, cross-chain bridging, and referral rewards.

## Overview

Phoenix Protocol provides a suite of smart contracts for:
- **PUSD Stablecoin** - A collateral-backed stablecoin
- **Vault** - Secure asset storage with yield generation
- **Farm & FarmLend** - Yield farming and lending operations
- **Cross-Chain Bridge** - Seamless asset transfers between chains
- **Referral System** - Multi-tier reward distribution
- **NFT Manager** - NFT-based user identity and privileges

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Frontend (dApp)                       │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                   Smart Contracts                        │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────┐ │
│  │  PUSD   │  │  Vault  │  │  Farm   │  │   Bridge    │ │
│  │ (ERC20) │  │         │  │         │  │ (LayerZero) │ │
│  └─────────┘  └─────────┘  └─────────┘  └─────────────┘ │
│  ┌─────────┐  ┌─────────┐  ┌───────────────────────────┐│
│  │  yPUSD  │  │ Oracle  │  │  ReferralRewardManager   ││
│  │(ERC4626)│  │         │  │                          ││
│  └─────────┘  └─────────┘  └───────────────────────────┘│
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│              Blockchain (BSC / Arbitrum)                 │
└─────────────────────────────────────────────────────────┘
```

## Contracts

| Contract | Description |
|----------|-------------|
| `PUSD` | ERC20 stablecoin with minting/burning capabilities |
| `yPUSD` | ERC4626 yield-bearing vault token |
| `Vault` | Collateral management and liquidation |
| `Farm` | Yield farming with staking rewards |
| `FarmLend` | Lending protocol integration |
| `PUSDOracle` | Price feed oracle |
| `MessageManager` | Cross-chain message handling |
| `NFTManager` | User NFT identity management |
| `ReferralRewardManager` | Multi-tier referral rewards with idempotency |

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js >= 18

### Installation

```bash
# Clone the repository
git clone https://github.com/phoenix-protocols/contracts.git
cd contracts

# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test
```

### Environment Setup

```bash
cp .env.example .env
# Edit .env with your configuration
```

Required environment variables:
- `PRIVATE_KEY` - Deployer wallet private key
- `RPC_URL` - Network RPC endpoint
- `ETHERSCAN_API_KEY` - For contract verification

## Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/Vault/Vault.t.sol

# Generate gas report
forge test --gas-report
```

## Deployment

```bash
# Deploy to testnet
./deploy.sh testnet

# Deploy to mainnet
./deploy.sh mainnet

# Post-deployment configuration
./post-config.sh
```

## Security Features

- **Upgradeable Contracts**: UUPS proxy pattern for safe upgrades
- **Access Control**: Role-based permissions (DEFAULT_ADMIN_ROLE, MINTER_ROLE, etc.)
- **Idempotency**: Record-based deduplication for batch operations
- **Reentrancy Guards**: Protection against reentrancy attacks
- **Pause Mechanism**: Emergency circuit breaker functionality

## License

MIT
