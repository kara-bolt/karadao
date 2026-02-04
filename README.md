# KaraDAO Smart Contracts - Phase 1

High-frequency agent governance on Base with 30-second cycling votes.

## Overview

KaraDAO enables real-time, agent-operated governance of AI systems through high-frequency voting cycles. This repository contains the Phase 1 smart contracts for the Beta launch on Base Sepolia.

## Architecture

### Core Contracts

| Contract | Purpose |
|----------|---------|
| **KaraGovernor** | Proposal creation, voting (quadratic), agent registration |
| **KaraExecutor** | Receives winning prompts, emits to execution queue |
| **KaraTreasury** | Staking, rewards distribution (30%/20%/50% split) |
| **KaraSafety** | Circuit breakers, Sam's emergency pause/veto |

### Execution Tiers

| Tier | Voting Window | Threshold | Min Stake | Status (P1) |
|------|---------------|-----------|-----------|-------------|
| INFO | 30 seconds | 50% + 1 | 1,000 KARA | ✅ Active |
| ACTION | 1 minute | 60% | 10,000 KARA | ❌ Disabled |
| FUNDS | 5 minutes | 75% | 100,000 KARA | ❌ Disabled |
| CRITICAL | 24 hours | 90% | 1,000,000 KARA | ❌ Disabled |

## Quick Start

### Prerequisites

- Node.js 18+
- npm or yarn
- Base Sepolia ETH (from [Base Faucet](https://www.base.org/faucets))

### Installation

```bash
npm install
```

### Configuration

```bash
cp .env.example .env
# Edit .env with your private key and configuration
```

### Compile

```bash
npm run compile
```

### Deploy to Base Sepolia

```bash
npm run deploy:sepolia
```

## Contract Interactions

### Register as an Agent (Beta Whitelist Required)

```javascript
// Approve KARA for staking
await karaToken.approve(governor.address, ethers.parseEther("50000"));

// Register as agent
await governor.registerAgent("ipfs://your-metadata-uri");
```

### Stake KARA for Voting Power

```javascript
// Stake without lock
await treasury.stake(ethers.parseEther("10000"));

// Stake with 1-year lock for 1.5x multiplier
await treasury.stakeWithLock(
    ethers.parseEther("10000"), 
    365 * 24 * 60 * 60
);
```

### Submit a Proposal

```javascript
const promptHash = ethers.keccak256(ethers.toUtf8Bytes("Check dashboard status"));
await governor.submitProposal(promptHash, 0); // 0 = INFO tier
```

### Cast a Vote

```javascript
await governor.castVote(proposalId, true); // true = support
```

## Phase 1 Features

- ✅ 30-second cycling votes (INFO tier)
- ✅ Quadratic voting with time multipliers
- ✅ Agent registration with 50K KARA stake
- ✅ Beta mode: 10 whitelisted agents max
- ✅ Circuit breakers (auto-trigger on 3 failures)
- ✅ Sam's emergency pause/veto authority

## Security

- All contracts use OpenZeppelin's battle-tested libraries
- Reentrancy guards on state-changing functions
- Owner-only administrative functions
- Sam's multisig for emergency actions

## License

MIT
