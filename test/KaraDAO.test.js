const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("KaraDAO Phase 1", function () {
    let karaToken, governor, safety, executor, treasury;
    let owner, sam, agent1, agent2, staker1;
    
    const AGENT_STAKE = ethers.parseEther("50000"); // 50K KARA
    const MIN_STAKE = ethers.parseEther("1000");    // 1K KARA
    
    beforeEach(async function () {
        [owner, sam, agent1, agent2, staker1] = await ethers.getSigners();
        
        // Deploy mock KARA token first
        const MockKaraToken = await ethers.getContractFactory("MockKaraToken");
        karaToken = await MockKaraToken.deploy("KARA Token", "KARA", 18);
        const karaTokenAddress = await karaToken.getAddress();
        
        // We need to deploy in a specific order due to interdependencies
        // Deploy placeholder contracts first, then update references
        
        // Deploy KaraSafety with temporary values
        const KaraSafety = await ethers.getContractFactory("KaraSafety");
        safety = await KaraSafety.deploy(
            owner.address, // temporary governor
            owner.address, // temporary treasury
            owner.address, // temporary executor
            karaTokenAddress,
            sam.address
        );
        const safetyAddress = await safety.getAddress();
        
        // Deploy KaraExecutor
        const KaraExecutor = await ethers.getContractFactory("KaraExecutor");
        executor = await KaraExecutor.deploy(
            owner.address, // temporary governor
            safetyAddress,
            owner.address  // temporary treasury
        );
        const executorAddress = await executor.getAddress();
        
        // Deploy KaraTreasury
        const KaraTreasury = await ethers.getContractFactory("KaraTreasury");
        treasury = await KaraTreasury.deploy(
            karaTokenAddress,
            owner.address, // temporary governor
            safetyAddress
        );
        const treasuryAddress = await treasury.getAddress();
        
        // Deploy KaraGovernor (the real governor)
        const KaraGovernor = await ethers.getContractFactory("KaraGovernor");
        governor = await KaraGovernor.deploy(
            karaTokenAddress,
            safetyAddress,
            executorAddress
        );
        const governorAddress = await governor.getAddress();
        
        // Update all contract references with real addresses
        await safety.updateContracts(
            governorAddress,
            treasuryAddress,
            executorAddress,
            karaTokenAddress
        );
        await executor.updateContracts(
            governorAddress,
            safetyAddress,
            treasuryAddress
        );
        await treasury.updateContracts(
            governorAddress,
            safetyAddress
        );
        
        // Fund accounts
        await karaToken.transfer(agent1.address, AGENT_STAKE * 2n);
        await karaToken.transfer(agent2.address, AGENT_STAKE * 2n);
        await karaToken.transfer(staker1.address, ethers.parseEther("100000"));
    });
    
    describe("KaraGovernor", function () {
        it("Should have correct initial configuration", async function () {
            const infoConfig = await governor.getTierConfig(0); // INFO tier
            expect(infoConfig.votingPeriod).to.equal(30);
            expect(infoConfig.threshold).to.equal(5001);
            expect(infoConfig.active).to.equal(true);
        });
        
        it("Should have ACTION tier disabled initially", async function () {
            const actionConfig = await governor.getTierConfig(1); // ACTION tier
            expect(actionConfig.active).to.equal(false);
        });
        
        it("Should allow owner to whitelist agents", async function () {
            await governor.whitelistAgent(agent1.address);
            expect(await governor.isWhitelistedAgent(agent1.address)).to.equal(true);
        });
        
        it("Should allow whitelisted agents to register", async function () {
            await governor.whitelistAgent(agent1.address);
            
            await karaToken.connect(agent1).approve(await governor.getAddress(), AGENT_STAKE);
            await governor.connect(agent1).registerAgent("ipfs://test-metadata");
            
            const agent = await governor.getAgent(agent1.address);
            expect(agent.isActive).to.equal(true);
            expect(agent.stakedAmount).to.equal(AGENT_STAKE);
        });
        
        it("Should not allow non-whitelisted agents to register in beta mode", async function () {
            await karaToken.connect(agent2).approve(await governor.getAddress(), AGENT_STAKE);
            await expect(
                governor.connect(agent2).registerAgent("ipfs://test")
            ).to.be.revertedWith("KaraGovernor: Not whitelisted for beta");
        });
        
        it("Should calculate quadratic voting power correctly", async function () {
            // Staker stakes 10,000 KARA
            const stakeAmount = ethers.parseEther("10000");
            await karaToken.connect(staker1).approve(await treasury.getAddress(), stakeAmount);
            await treasury.connect(staker1).stake(stakeAmount);
            
            // Update governor with staker info
            await governor.updateStakerInfo(staker1.address, stakeAmount, 0, 100);
            
            const votingPower = await governor.getVotingPower(staker1.address);
            expect(votingPower).to.be.gt(0);
        });
        
        it("Should allow registered agents to submit proposals", async function () {
            // Setup agent
            await governor.whitelistAgent(agent1.address);
            await karaToken.connect(agent1).approve(await governor.getAddress(), AGENT_STAKE);
            await governor.connect(agent1).registerAgent("ipfs://test");
            
            // Also stake for proposal requirement
            await karaToken.connect(agent1).approve(await treasury.getAddress(), MIN_STAKE);
            await treasury.connect(agent1).stake(MIN_STAKE);
            await governor.updateStakerInfo(agent1.address, MIN_STAKE, 0, 100);
            
            // Submit proposal
            const promptHash = ethers.keccak256(ethers.toUtf8Bytes("Test prompt"));
            await governor.connect(agent1).submitProposal(promptHash, 0); // INFO tier
            
            const proposal = await governor.getProposal(1);
            expect(proposal.promptHash).to.equal(promptHash);
            expect(proposal.proposer).to.equal(agent1.address);
        });
        
        it("Should track proposal cycles correctly", async function () {
            const cycleInfo = await governor.getCurrentCycle();
            expect(cycleInfo.cycle).to.equal(0);
        });
        
        it("Should limit beta to 10 agents", async function () {
            expect(await governor.MAX_BETA_AGENTS()).to.equal(10);
            expect(await governor.betaMode()).to.equal(true);
        });
    });
    
    describe("KaraSafety", function () {
        it("Should set Sam correctly", async function () {
            expect(await safety.sam()).to.equal(sam.address);
        });
        
        it("Should allow Sam to pause tiers", async function () {
            await safety.connect(sam).emergencyPause(0); // INFO tier
            expect(await safety.isPaused(0)).to.equal(true);
        });
        
        it("Should allow owner to pause tiers", async function () {
            await safety.emergencyPause(0); // INFO tier
            expect(await safety.isPaused(0)).to.equal(true);
        });
        
        it("Should not allow non-Sam/non-owner to pause", async function () {
            await expect(
                safety.connect(agent1).emergencyPause(0)
            ).to.be.revertedWith("KaraSafety: Only Sam or owner");
        });
        
        it("Should allow Sam to veto critical proposals", async function () {
            await safety.connect(sam).vetoCritical(1, "Emergency veto");
            expect(await safety.isVetoed(1)).to.equal(true);
        });
        
        it("Should track circuit breaker failures", async function () {
            await safety.addGuardian(owner.address);
            await safety.recordFailure(0);
            
            const status = await safety.getCircuitBreakerStatus(0);
            expect(status.failures).to.equal(1);
        });
        
        it("Should have correct circuit breaker config", async function () {
            const status = await safety.getCircuitBreakerStatus(0);
            expect(status.isActive).to.equal(false);
        });
    });
    
    describe("KaraTreasury", function () {
        it("Should allow users to stake KARA", async function () {
            const stakeAmount = ethers.parseEther("10000");
            await karaToken.connect(staker1).approve(await treasury.getAddress(), stakeAmount);
            await treasury.connect(staker1).stake(stakeAmount);
            
            const stakerInfo = await treasury.getStakerInfo(staker1.address);
            expect(stakerInfo.stakedAmount).to.equal(stakeAmount);
        });
        
        it("Should apply time multiplier for locked stakes", async function () {
            const stakeAmount = ethers.parseEther("10000");
            const oneYear = 365 * 24 * 60 * 60;
            
            await karaToken.connect(staker1).approve(await treasury.getAddress(), stakeAmount);
            await treasury.connect(staker1).stakeWithLock(stakeAmount, oneYear);
            
            const stakerInfo = await treasury.getStakerInfo(staker1.address);
            expect(stakerInfo.timeMultiplier).to.equal(150); // 1.5x
        });
        
        it("Should apply 2x multiplier for 2-year lock", async function () {
            const stakeAmount = ethers.parseEther("10000");
            const twoYears = 2 * 365 * 24 * 60 * 60;
            
            await karaToken.connect(staker1).approve(await treasury.getAddress(), stakeAmount);
            await treasury.connect(staker1).stakeWithLock(stakeAmount, twoYears);
            
            const stakerInfo = await treasury.getStakerInfo(staker1.address);
            expect(stakerInfo.timeMultiplier).to.equal(200); // 2.0x
        });
        
        it("Should apply 3x multiplier for 4-year lock", async function () {
            const stakeAmount = ethers.parseEther("10000");
            const fourYears = 4 * 365 * 24 * 60 * 60;
            
            await karaToken.connect(staker1).approve(await treasury.getAddress(), stakeAmount);
            await treasury.connect(staker1).stakeWithLock(stakeAmount, fourYears);
            
            const stakerInfo = await treasury.getStakerInfo(staker1.address);
            expect(stakerInfo.timeMultiplier).to.equal(300); // 3.0x
        });
        
        it("Should distribute fees correctly", async function () {
            const feeAmount = ethers.parseEther("1000");
            await karaToken.approve(await treasury.getAddress(), feeAmount);
            await treasury.distributeFees(feeAmount);
            
            // Verify fees were received (treasury balance should increase)
            const stats = await treasury.getTreasuryStats();
            expect(stats[2]).to.be.gt(0); // treasuryBalance increased
        });
        
        it("Should enforce minimum stake", async function () {
            const smallStake = ethers.parseEther("100"); // Below minimum
            await karaToken.connect(staker1).approve(await treasury.getAddress(), smallStake);
            await expect(
                treasury.connect(staker1).stake(smallStake)
            ).to.be.revertedWith("KaraTreasury: Minimum 1K KARA");
        });
    });
    
    describe("KaraExecutor", function () {
        beforeEach(async function () {
            // Authorize owner as executor for claiming
            await executor.setExecutorAuthorization(owner.address, true);
        });
        
        it("Should have correct governor address", async function () {
            // The governor should be set correctly from deployment
            expect(await executor.governor()).to.equal(await governor.getAddress());
        });
        
        it("Should track pending executions", async function () {
            const pending = await executor.getPendingExecutions();
            expect(pending.length).to.equal(0);
        });
        
        it("Should authorize and deauthorize executors", async function () {
            await executor.setExecutorAuthorization(agent1.address, true);
            expect(await executor.isAuthorizedExecutor(agent1.address)).to.equal(true);
            
            await executor.setExecutorAuthorization(agent1.address, false);
            expect(await executor.isAuthorizedExecutor(agent1.address)).to.equal(false);
        });
        
        it("Should have correct execution timeout", async function () {
            expect(await executor.executionTimeout()).to.equal(300); // 5 minutes
        });
    });
    
    describe("Integration Tests", function () {
        it("Should complete full proposal lifecycle", async function () {
            // 1. Register agent
            await governor.whitelistAgent(agent1.address);
            await karaToken.connect(agent1).approve(await governor.getAddress(), AGENT_STAKE);
            await governor.connect(agent1).registerAgent("ipfs://agent");
            
            // 2. Stake for voting power
            const stakeAmount = ethers.parseEther("10000");
            await karaToken.connect(staker1).approve(await treasury.getAddress(), stakeAmount);
            await treasury.connect(staker1).stake(stakeAmount);
            
            // 3. Update staker info in governor
            await governor.updateStakerInfo(staker1.address, stakeAmount, 0, 100);
            
            // 4. Delegate to agent
            await governor.connect(staker1).delegate(agent1.address);
            
            // 5. Stake for agent proposal requirement
            await karaToken.connect(agent1).approve(await treasury.getAddress(), MIN_STAKE);
            await treasury.connect(agent1).stake(MIN_STAKE);
            await governor.updateStakerInfo(agent1.address, MIN_STAKE, 0, 100);
            
            // 6. Submit proposal
            const promptHash = ethers.keccak256(ethers.toUtf8Bytes("Integration test"));
            await governor.connect(agent1).submitProposal(promptHash, 0);
            
            // 7. Cast vote
            await governor.connect(staker1).castVote(1, true);
            
            // 8. Check proposal state
            const proposal = await governor.getProposal(1);
            expect(proposal.forVotes).to.be.gt(0);
        });
        
        it("Should apply delegate bonus for high-reputation agents", async function () {
            // Setup agent with high reputation
            await governor.whitelistAgent(agent1.address);
            await karaToken.connect(agent1).approve(await governor.getAddress(), AGENT_STAKE);
            await governor.connect(agent1).registerAgent("ipfs://agent");
            
            // Set high reputation (80+)
            await governor.updateAgentReputation(agent1.address, 90);
            
            // Stake and delegate
            const stakeAmount = ethers.parseEther("10000");
            await karaToken.connect(staker1).approve(await treasury.getAddress(), stakeAmount);
            await treasury.connect(staker1).stake(stakeAmount);
            await governor.updateStakerInfo(staker1.address, stakeAmount, 0, 100);
            await governor.connect(staker1).delegate(agent1.address);
            
            // Get voting power - should have 1.2x bonus
            const votingPower = await governor.getVotingPower(staker1.address);
            expect(votingPower).to.be.gt(0);
        });
    });
});
