# Mini Aave — DeFi Lending Protocol

A simplified Aave-inspired DeFi lending protocol built with Foundry for educational purposes.

> Deposit ETH → Borrow MUSD stablecoin → Get liquidated if you're not careful!

## What is Mini Aave?

Mini Aave is an **overcollateralized lending protocol** where:
- Users **deposit ETH** as collateral
- Users **borrow MUSD** (a stablecoin) against their collateral
- If ETH price drops and your position becomes unhealthy, anyone can **liquidate** you
- Liquidators earn a **5% bonus** for keeping the protocol healthy

## Quick Start

```bash
# Build
forge build

# Test (38 tests)
forge test

# Test with verbose output
forge test -vvv

# Deploy to Anvil (local)
anvil &  # Start local node
forge script script/DeployMiniAave.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# Gas snapshot
forge snapshot
```

## Architecture

```
src/
├── MiniAave.sol           # Core lending engine (deposit, withdraw, borrow, repay, liquidate)
├── MiniUSD.sol            # ERC20 stablecoin (minted on borrow, burned on repay)
├── interfaces/
│   └── IMiniAave.sol      # Interface (events, errors, function signatures)
└── libraries/
    └── OracleLib.sol      # Chainlink price feed wrapper

script/
├── DeployMiniAave.s.sol   # Deployment script
└── HelperConfig.s.sol     # Network config (mock on Anvil, real feed on Sepolia)

test/
├── unit/
│   └── MiniAaveTest.t.sol # 38 comprehensive tests
└── mocks/
    └── MockV3Aggregator.sol # Mock Chainlink price feed
```

## Key Parameters

| Parameter | Value | Meaning |
|---|---|---|
| Collateral Ratio (LTV) | 75% | Max you can borrow relative to collateral |
| Liquidation Threshold | 80% | Point at which liquidation is triggered |
| Liquidation Bonus | 5% | Extra collateral liquidators receive |
| Min Health Factor | 1.0 | Below this = liquidatable |

## Example Flow

1. Alice deposits **10 ETH** (worth $20,000 at $2,000/ETH)
2. Alice borrows **$14,000 MUSD** (within 75% LTV)
3. ETH price crashes to **$1,000**
4. Alice's health factor = ($10,000 × 80%) / $14,000 = **0.57** (unhealthy!)
5. Bob liquidates $7,000 of Alice's debt
6. Bob receives **7.35 ETH** ($7,000 + 5% bonus)

## Technologies

- Solidity ^0.8.20
- Foundry (forge, cast, anvil)
- Chainlink Price Feeds
- OpenZeppelin (ERC20, Ownable, ReentrancyGuard)
