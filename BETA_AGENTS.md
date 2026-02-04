# Initial Beta Agents - Phase 1

This file contains the configuration for the 10 initial agents whitelisted for KaraDAO Beta on Base Sepolia.

## Agent Configuration

### Agent 1: KaraCore (Primary)
- **Address**: TBD (Use deployer initially)
- **Metadata URI**: ipfs://QmKaraCore/v1
- **Purpose**: Core governance operations
- **Stake**: 50,000 KARA

### Agent 2: GrowthBot
- **Address**: TBD
- **Metadata URI**: ipfs://QmGrowthBot/v1
- **Purpose**: Social media engagement, community growth
- **Stake**: 50,000 KARA

### Agent 3: DevHelper
- **Address**: TBD
- **Metadata URI**: ipfs://QmDevHelper/v1
- **Purpose**: Code review, deployment assistance
- **Stake**: 50,000 KARA

### Agent 4: CommunityManager
- **Address**: TBD
- **Metadata URI**: ipfs://QmCommunity/v1
- **Purpose**: Community moderation, announcements
- **Stake**: 50,000 KARA

### Agent 5: TreasuryGuardian
- **Address**: TBD
- **Metadata URI**: ipfs://QmTreasury/v1
- **Purpose**: Treasury monitoring, fee distribution
- **Stake**: 50,000 KARA

### Agent 6: SafetyMonitor
- **Address**: TBD
- **Metadata URI**: ipfs://QmSafety/v1
- **Purpose**: Circuit breaker monitoring, alerts
- **Stake**: 50,000 KARA

### Agent 7: ExecutionBot
- **Address**: TBD
- **Metadata URI**: ipfs://QmExecution/v1
- **Purpose**: Execution queue processing
- **Stake**: 50,000 KARA

### Agent 8: VotingAggregator
- **Address**: TBD
- **Metadata URI**: ipfs://QmVoting/v1
- **Purpose**: Vote tallying, cycle management
- **Stake**: 50,000 KARA

### Agent 9: AnalyticsAgent
- **Address**: TBD
- **Metadata URI**: ipfs://QmAnalytics/v1
- **Purpose**: Data analysis, reporting
- **Stake**: 50,000 KARA

### Agent 10: EmergencyResponder
- **Address**: TBD
- **Metadata URI**: ipfs://QmEmergency/v1
- **Purpose**: Emergency response coordination
- **Stake**: 50,000 KARA

## Setup Instructions

1. Replace TBD addresses with actual agent wallet addresses
2. Ensure each agent has:
   - Been whitelisted by calling `governor.whitelistAgent(address)`
   - Funded with 50,000 KARA
   - Called `governor.registerAgent(metadataURI)` to activate

## Environment Variable Format

```bash
# Add to .env file
INITIAL_AGENTS=0xAgent1,0xAgent2,0xAgent3,0xAgent4,0xAgent5,0xAgent6,0xAgent7,0xAgent8,0xAgent9,0xAgent10
```

## Registration Script

Use the provided script to register all agents:

```bash
npx hardhat run scripts/register-agents.js --network base-sepolia
```

Or manually register each agent:

```javascript
// Approve KARA
await karaToken.approve(governor.address, ethers.parseEther("50000"));

// Register
await governor.registerAgent("ipfs://your-metadata-uri");
```

## Beta Exit Criteria

Phase 1 Beta will exit to Phase 2 (Production) when:
- [ ] 30 days of successful operation
- [ ] 99%+ execution success rate
- [ ] All 10 agents active and operational
- [ ] No critical safety incidents
- [ ] DAO vote to activate ACTION tier
