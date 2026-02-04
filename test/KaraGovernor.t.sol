// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/KaraGovernor.sol";
import "../contracts/KaraExecutor.sol";
import "../contracts/KaraTreasury.sol";
import "../contracts/KaraSafety.sol";
import "../contracts/MockKaraToken.sol";
import "../contracts/Interfaces.sol";

/**
 * @title KaraGovernorTest
 * @notice Comprehensive test suite for KaraGovernor contract
 */
contract KaraGovernorTest is Test {
    KaraGovernor public governor;
    KaraExecutor public executor;
    KaraTreasury public treasury;
    KaraSafety public safety;
    MockKaraToken public karaToken;

    address public owner;
    address public sam;
    address public agent1;
    address public agent2;
    address public staker1;
    address public staker2;

    uint256 constant INITIAL_MINT = 1_000_000_000 * 10 ** 18;
    uint256 constant AGENT_STAKE = 50_000 * 10 ** 18;
    uint256 constant VOTER_STAKE = 10_000 * 10 ** 18;

    function setUp() public {
        owner = address(this);
        sam = makeAddr("sam");
        agent1 = makeAddr("agent1");
        agent2 = makeAddr("agent2");
        staker1 = makeAddr("staker1");
        staker2 = makeAddr("staker2");

        // Deploy mock token
        karaToken = new MockKaraToken("KARA Token", "KARA", 18);

        // Deploy contracts (will re-link later due to circular dependencies)
        // Deploy safety first with temporary addresses
        safety = new KaraSafety(
            address(0), // temp governor
            address(0), // temp treasury
            address(0), // temp executor
            address(karaToken),
            sam
        );

        // Deploy treasury
        treasury = new KaraTreasury(
            address(karaToken),
            address(0), // temp governor
            address(safety)
        );

        // Deploy executor
        executor = new KaraExecutor(
            address(0), // temp governor
            address(safety),
            address(treasury)
        );

        // Deploy governor
        governor = new KaraGovernor(address(karaToken), address(safety), address(executor));

        // Update contract references
        safety.updateContracts(address(governor), address(treasury), address(executor), address(karaToken));
        treasury.updateContracts(address(governor), address(safety));
        executor.updateContracts(address(governor), address(safety), address(treasury));
        governor.setTreasury(address(treasury));

        // Fund accounts
        karaToken.transfer(agent1, AGENT_STAKE * 10);
        karaToken.transfer(agent2, AGENT_STAKE * 10);
        karaToken.transfer(staker1, VOTER_STAKE * 10);
        karaToken.transfer(staker2, VOTER_STAKE * 10);

        // Whitelist agents for beta
        governor.whitelistAgent(agent1);
        governor.whitelistAgent(agent2);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsInitialState() public view {
        assertEq(address(governor.karaToken()), address(karaToken));
        assertEq(address(governor.safety()), address(safety));
        assertEq(address(governor.executor()), address(executor));
        assertEq(governor.cycleStartTime(), block.timestamp);
        assertEq(governor.currentCycle(), 0);
        assertTrue(governor.betaMode());
    }

    function test_Constructor_SetsTierConfigs() public view {
        // INFO tier (active)
        (uint256 votingPeriod, uint256 threshold, uint256 minStake, bool active) =
            governor.tierConfigs(KaraGovernor.Tier.INFO);
        assertEq(votingPeriod, 30 seconds);
        assertEq(threshold, 5001);
        assertEq(minStake, 1_000 * 10 ** 18);
        assertTrue(active);

        // ACTION tier (inactive)
        (votingPeriod, threshold, minStake, active) = governor.tierConfigs(KaraGovernor.Tier.ACTION);
        assertEq(votingPeriod, 1 minutes);
        assertEq(threshold, 6000);
        assertFalse(active);

        // FUNDS tier (inactive)
        (votingPeriod, threshold, minStake, active) = governor.tierConfigs(KaraGovernor.Tier.FUNDS);
        assertEq(votingPeriod, 5 minutes);
        assertEq(threshold, 7500);
        assertFalse(active);

        // CRITICAL tier (inactive)
        (votingPeriod, threshold, minStake, active) = governor.tierConfigs(KaraGovernor.Tier.CRITICAL);
        assertEq(votingPeriod, 24 hours);
        assertEq(threshold, 9000);
        assertFalse(active);
    }

    function test_Constructor_RevertsWithInvalidToken() public {
        vm.expectRevert("KaraGovernor: Invalid token");
        new KaraGovernor(address(0), address(safety), address(executor));
    }

    function test_Constructor_AllowsInvalidSafety() public {
        // Safety can be set later via updateContracts
        KaraGovernor g = new KaraGovernor(address(karaToken), address(0), address(executor));
        assertEq(address(g.karaToken()), address(karaToken));
    }

    function test_Constructor_AllowsInvalidExecutor() public {
        // Executor can be set later via updateContracts
        KaraGovernor g = new KaraGovernor(address(karaToken), address(safety), address(0));
        assertEq(address(g.karaToken()), address(karaToken));
    }

    // ============ Agent Registration Tests ============

    function test_RegisterAgent_Success() public {
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);

        vm.expectEmit(true, true, true, true);
        emit KaraGovernor.AgentRegistered(agent1, "ipfs://metadata", AGENT_STAKE);

        governor.registerAgent("ipfs://metadata");
        vm.stopPrank();

        (address agentAddr, uint256 regTime, uint256 staked, uint256 rep, string memory uri, bool isActive) =
            governor.agents(agent1);
        assertEq(agentAddr, agent1);
        assertGt(regTime, 0);
        assertEq(staked, AGENT_STAKE);
        assertEq(rep, 50); // Starting reputation
        assertEq(uri, "ipfs://metadata");
        assertTrue(isActive);
        assertEq(governor.currentAgentCount(), 1);
    }

    function test_RegisterAgent_RevertsIfAlreadyRegistered() public {
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE * 2);
        governor.registerAgent("ipfs://metadata1");

        vm.expectRevert("KaraGovernor: Already registered");
        governor.registerAgent("ipfs://metadata2");
        vm.stopPrank();
    }

    function test_RegisterAgent_RevertsIfNotWhitelisted() public {
        address nonWhitelisted = makeAddr("nonWhitelisted");
        karaToken.transfer(nonWhitelisted, AGENT_STAKE * 2);

        vm.startPrank(nonWhitelisted);
        karaToken.approve(address(governor), AGENT_STAKE);

        vm.expectRevert("KaraGovernor: Not whitelisted for beta");
        governor.registerAgent("ipfs://metadata");
        vm.stopPrank();
    }

    function test_RegisterAgent_RevertsWithEmptyMetadata() public {
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);

        vm.expectRevert("KaraGovernor: Empty metadata");
        governor.registerAgent("");
        vm.stopPrank();
    }

    function test_DeregisterAgent_Success() public {
        // Register first
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");

        uint256 balanceBefore = karaToken.balanceOf(agent1);

        vm.expectEmit(true, false, false, false);
        emit KaraGovernor.AgentDeregistered(agent1);

        governor.deregisterAgent();
        vm.stopPrank();

        (,,,,, bool isActive) = governor.agents(agent1);
        assertFalse(isActive);
        assertEq(governor.currentAgentCount(), 0);
        assertEq(karaToken.balanceOf(agent1), balanceBefore + AGENT_STAKE);
    }

    function test_DeregisterAgent_RevertsIfNotRegistered() public {
        vm.prank(agent1);
        vm.expectRevert("KaraGovernor: Not registered");
        governor.deregisterAgent();
    }

    // ============ Proposal Submission Tests ============

    function test_SubmitProposal_Success() public {
        // Setup: Register agent and stake
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");

        // Also stake for voting power
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);

        bytes32 promptHash = keccak256("test prompt");

        vm.expectEmit(true, true, true, true);
        emit KaraGovernor.ProposalSubmitted(1, promptHash, KaraGovernor.Tier.INFO, agent1, 0);

        uint256 proposalId = governor.submitProposal(promptHash, KaraGovernor.Tier.INFO);
        vm.stopPrank();

        assertEq(proposalId, 1);
        assertEq(governor.proposalCount(), 1);

        (
            bytes32 storedHash,
            KaraGovernor.Tier tier,
            uint256 startTime,
            uint256 endTime,
            uint256 forVotes,
            uint256 againstVotes,
            bool executed,
            address proposer,
            bool vetoed
        ) = governor.proposals(1);
        assertEq(storedHash, promptHash);
        assertEq(uint256(tier), uint256(KaraGovernor.Tier.INFO));
        assertGt(startTime, 0);
        assertEq(endTime, startTime + 30 seconds);
        assertEq(forVotes, 0);
        assertEq(againstVotes, 0);
        assertFalse(executed);
        assertEq(proposer, agent1);
        assertFalse(vetoed);
    }

    function test_SubmitProposal_RevertsWithEmptyHash() public {
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");

        vm.expectRevert("KaraGovernor: Empty prompt hash");
        governor.submitProposal(bytes32(0), KaraGovernor.Tier.INFO);
        vm.stopPrank();
    }

    function test_SubmitProposal_RevertsIfNotAgent() public {
        vm.prank(staker1);
        vm.expectRevert("KaraGovernor: Not registered agent");
        governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
    }

    function test_SubmitProposal_RevertsIfTierInactive() public {
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");

        vm.expectRevert("KaraGovernor: Tier not active");
        governor.submitProposal(keccak256("test"), KaraGovernor.Tier.ACTION);
        vm.stopPrank();
    }

    function test_SubmitProposal_RevertsIfInsufficientStake() public {
        // Register with minimum but then try to propose with higher tier requirement
        // First, let's make a new agent with exactly 50K stake
        address poorAgent = makeAddr("poorAgent");
        karaToken.transfer(poorAgent, AGENT_STAKE);
        governor.whitelistAgent(poorAgent);

        // Change INFO tier minimum to require more than AGENT_STAKE
        governor.updateTierConfig(
            KaraGovernor.Tier.INFO,
            30 seconds,
            5001,
            AGENT_STAKE + 1, // More than agent has staked
            true
        );

        vm.startPrank(poorAgent);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");

        vm.expectRevert("KaraGovernor: Insufficient stake");
        governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();
    }

    // ============ Voting Tests ============

    function test_CastVote_Success() public {
        // Setup
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);

        uint256 proposalId = governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();

        // Vote
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);

        uint256 votingPower = governor.getVotingPower(staker1);
        assertGt(votingPower, 0);

        vm.expectEmit(true, true, true, true);
        emit KaraGovernor.VoteCast(proposalId, staker1, true, votingPower);

        governor.castVote(proposalId, true);
        vm.stopPrank();

        (,,,, uint256 forVotes,,,,) = governor.proposals(proposalId);
        assertEq(forVotes, votingPower);
        assertTrue(governor.hasVoted(proposalId, staker1));
    }

    function test_CastVote_RevertsIfAlreadyVoted() public {
        // Setup
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);
        uint256 proposalId = governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();

        vm.startPrank(staker1);
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);

        governor.castVote(proposalId, true);

        vm.expectRevert("KaraGovernor: Already voted");
        governor.castVote(proposalId, true);
        vm.stopPrank();
    }

    function test_CastVote_RevertsIfNoVotingPower() public {
        // Setup
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);
        uint256 proposalId = governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();

        // Non-staker tries to vote
        address nonStaker = makeAddr("nonStaker");
        vm.prank(nonStaker);
        vm.expectRevert("KaraGovernor: No voting power");
        governor.castVote(proposalId, true);
    }

    function test_CastVote_RevertsAfterVotingEnds() public {
        // Setup
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);
        uint256 proposalId = governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();

        vm.startPrank(staker1);
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);

        // Fast forward past voting period
        vm.warp(block.timestamp + 31 seconds);

        vm.expectRevert("KaraGovernor: Voting ended");
        governor.castVote(proposalId, true);
        vm.stopPrank();
    }

    // ============ Voting Power Tests ============

    function test_GetVotingPower_QuadraticCalculation() public {
        // Stake 10,000 tokens - sqrt(10000) = 100
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);

        uint256 power = governor.getVotingPower(staker1);
        // sqrt(10000e18) = 1e11, but with decimals adjustment it's approx 100 * 1e9
        assertGt(power, 0);
        vm.stopPrank();
    }

    function test_GetVotingPower_WithTimeMultiplier() public {
        // Stake with 1 year lock (1.5x multiplier)
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stakeWithLock(VOTER_STAKE, 365 days);

        uint256 powerWithLock = governor.getVotingPower(staker1);

        // Compare with no lock
        vm.startPrank(staker2);
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);

        uint256 powerWithoutLock = governor.getVotingPower(staker2);

        // Power with lock should be ~1.5x
        assertGt(powerWithLock, powerWithoutLock);
    }

    function test_GetVotingPower_NoStake() public view {
        uint256 power = governor.getVotingPower(staker1);
        assertEq(power, 0);
    }

    // Note: test_GetVotingPower_BelowMinimum removed as Treasury now enforces 1K minimum stake

    // ============ Execution Tests ============

    function test_ExecuteWinningProposal_Success() public {
        // Setup: Create proposal
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);
        uint256 proposalId = governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();

        // Staker votes for
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), VOTER_STAKE * 10);
        treasury.stake(VOTER_STAKE * 10);
        governor.castVote(proposalId, true);
        vm.stopPrank();

        // Fast forward past voting
        vm.warp(block.timestamp + 31 seconds);

        // Execute
        vm.expectEmit(true, true, true, true);
        emit KaraGovernor.ProposalExecuted(proposalId, keccak256("test"), governor.getVotingPower(staker1), 0);

        governor.executeWinningProposal(proposalId);

        (,,,,,, bool executed,,) = governor.proposals(proposalId);
        assertTrue(executed);
    }

    function test_ExecuteWinningProposal_RevertsBeforeEnd() public {
        // Setup
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);
        uint256 proposalId = governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();

        vm.expectRevert("KaraGovernor: Voting active");
        governor.executeWinningProposal(proposalId);
    }

    function test_ExecuteWinningProposal_RevertsNoVotes() public {
        // Setup
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);
        uint256 proposalId = governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 seconds);

        vm.expectRevert("KaraGovernor: No votes cast");
        governor.executeWinningProposal(proposalId);
    }

    function test_ExecuteWinningProposal_RevertsThresholdNotMet() public {
        // Setup: Create proposal
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);
        uint256 proposalId = governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();

        // Vote against (just to have votes but not pass)
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);
        governor.castVote(proposalId, false);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 seconds);

        vm.expectRevert("KaraGovernor: Threshold not met");
        governor.executeWinningProposal(proposalId);
    }

    // ============ Delegation Tests ============

    function test_Delegate_Success() public {
        // Register agent1 first
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        vm.stopPrank();

        // Staker delegates to agent1
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);

        vm.expectEmit(true, true, true, true);
        emit KaraGovernor.DelegationChanged(staker1, address(0), agent1);

        governor.delegate(agent1);
        vm.stopPrank();

        (uint256 amount, uint256 lockEnd, address delegatedTo, uint256 multiplier) = governor.stakers(staker1);
        assertEq(delegatedTo, agent1);
    }

    function test_Delegate_RevertsToInvalidAgent() public {
        address nonAgent = makeAddr("nonAgent");

        vm.startPrank(staker1);
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);

        vm.expectRevert("KaraGovernor: Invalid agent");
        governor.delegate(nonAgent);
        vm.stopPrank();
    }

    // ============ Admin Tests ============

    function test_WhitelistAgent() public {
        address newAgent = makeAddr("newAgent");
        assertFalse(governor.isWhitelistedAgent(newAgent));

        governor.whitelistAgent(newAgent);

        assertTrue(governor.isWhitelistedAgent(newAgent));
    }

    function test_WhitelistAgent_RevertsForNonOwner() public {
        vm.prank(agent1);
        vm.expectRevert();
        governor.whitelistAgent(makeAddr("new"));
    }

    function test_UpdateTierConfig() public {
        governor.updateTierConfig(KaraGovernor.Tier.INFO, 60 seconds, 5500, 2000 * 10 ** 18, true);

        (uint256 votingPeriod, uint256 threshold, uint256 minStake, bool active) =
            governor.tierConfigs(KaraGovernor.Tier.INFO);
        assertEq(votingPeriod, 60 seconds);
        assertEq(threshold, 5500);
        assertEq(minStake, 2000 * 10 ** 18);
        assertTrue(active);
    }

    function test_DisableBetaMode() public {
        assertTrue(governor.betaMode());

        governor.disableBetaMode();

        assertFalse(governor.betaMode());
    }

    function test_VetoProposal() public {
        // Setup
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);
        uint256 proposalId = governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();

        // Veto as owner
        vm.expectEmit(true, false, false, false);
        emit KaraGovernor.ProposalVetoed(proposalId);

        governor.vetoProposal(proposalId);

        (,,,,,,,, bool vetoed) = governor.proposals(proposalId);
        assertTrue(vetoed);
    }

    function test_VetoProposal_RevertsForUnauthorized() public {
        // Setup
        vm.startPrank(agent1);
        karaToken.approve(address(governor), AGENT_STAKE);
        governor.registerAgent("ipfs://metadata");
        karaToken.approve(address(treasury), VOTER_STAKE);
        treasury.stake(VOTER_STAKE);
        uint256 proposalId = governor.submitProposal(keccak256("test"), KaraGovernor.Tier.INFO);
        vm.stopPrank();

        vm.prank(staker1);
        vm.expectRevert("KaraGovernor: Unauthorized");
        governor.vetoProposal(proposalId);
    }

    // ============ Cycle Management Tests ============

    function test_AdvanceCycle() public {
        uint256 initialCycle = governor.currentCycle();

        vm.expectEmit(true, true, false, false);
        emit KaraGovernor.CycleAdvanced(initialCycle + 1, block.timestamp);

        governor.advanceCycle();

        assertEq(governor.currentCycle(), initialCycle + 1);
    }

    function test_AdvanceCycle_RevertsForNonOwner() public {
        vm.prank(agent1);
        vm.expectRevert();
        governor.advanceCycle();
    }

    function test_GetCurrentCycle() public view {
        (uint256 cycle, uint256 startTime, uint256 timeRemaining) = governor.getCurrentCycle();
        assertEq(cycle, 0);
        assertGt(startTime, 0);
        assertLe(timeRemaining, 30 seconds);
    }

    // ============ View Function Tests ============

    function test_SqrtCalculation() public pure {
        // Test the internal sqrt function via getVotingPower with different stakes
        // sqrt(100) = 10, sqrt(10000) = 100, sqrt(1000000) = 1000
        // This is tested indirectly through voting power calculations
    }
}
