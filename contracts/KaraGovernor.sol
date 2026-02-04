// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./Interfaces.sol";

/**
 * @title KaraGovernor
 * @notice High-frequency governance with 30-second cycling votes and quadratic voting
 * @dev Phase 1: Only INFO tier active with 10 whitelisted agents
 */
contract KaraGovernor is Ownable, ReentrancyGuard {
    using Math for uint256;

    // ============ State Variables ============

    IKaraToken public karaToken;
    IKaraSafety public safety;
    IKaraExecutor public executor;
    IKaraTreasury public treasury;

    // Execution tiers
    enum Tier {
        INFO,
        ACTION,
        FUNDS,
        CRITICAL
    }

    struct TierConfig {
        uint256 votingPeriod; // in seconds
        uint256 threshold; // in basis points (e.g., 5000 = 50%)
        uint256 minStake; // minimum KARA to propose
        bool active;
    }

    struct Proposal {
        bytes32 promptHash;
        Tier tier;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        address proposer;
        bool vetoed;
    }

    struct Agent {
        address agentAddress;
        uint256 registrationTime;
        uint256 stakedAmount;
        uint256 reputationScore;
        string metadataURI;
        bool isActive;
    }

    struct Staker {
        uint256 stakedAmount;
        uint256 lockEndTime;
        address delegatedTo;
        uint256 timeMultiplier;
    }

    // Mappings
    mapping(Tier => TierConfig) public tierConfigs;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => Agent) public agents;
    mapping(address => Staker) public stakers;
    mapping(address => bool) public isWhitelistedAgent;

    // Cycle management
    uint256 public currentCycle;
    uint256 public cycleStartTime;
    uint256 public constant CYCLE_DURATION = 30 seconds;

    // Proposal tracking
    uint256 public proposalCount;
    mapping(uint256 => uint256[]) public cycleProposals;

    // Constants
    uint256 public constant AGENT_REGISTRATION_STAKE = 50_000 * 10 ** 18; // 50K KARA
    uint256 public constant MIN_STAKE_TO_VOTE = 1_000 * 10 ** 18; // 1K KARA
    uint256 public constant DELEGATE_BONUS = 120; // 1.2x = 120%
    uint256 public constant BASIS_POINTS = 10000;

    // Phase 1: Beta whitelist
    uint256 public constant MAX_BETA_AGENTS = 10;
    uint256 public currentAgentCount;
    bool public betaMode = true;

    // ============ Events ============

    event ProposalSubmitted(
        uint256 indexed proposalId, bytes32 indexed promptHash, Tier tier, address indexed proposer, uint256 cycle
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId, bytes32 promptHash, uint256 forVotes, uint256 againstVotes);
    event ProposalVetoed(uint256 indexed proposalId);
    event DelegationChanged(address indexed delegator, address indexed previousDelegate, address indexed newDelegate);
    event AgentRegistered(address indexed agent, string metadataURI, uint256 stakedAmount);
    event AgentDeregistered(address indexed agent);
    event CycleAdvanced(uint256 indexed newCycle, uint256 timestamp);
    event TierConfigUpdated(Tier tier, uint256 votingPeriod, uint256 threshold, uint256 minStake);

    // ============ Modifiers ============

    modifier onlyAgent() {
        require(agents[msg.sender].isActive, "KaraGovernor: Not registered agent");
        _;
    }

    modifier whenTierActive(Tier tier) {
        require(tierConfigs[tier].active, "KaraGovernor: Tier not active");
        require(address(safety) == address(0) || !safety.isPaused(uint8(tier)), "KaraGovernor: Tier paused");
        _;
    }

    modifier validProposal(uint256 proposalId) {
        require(proposalId > 0 && proposalId <= proposalCount, "KaraGovernor: Invalid proposal");
        _;
    }

    // ============ Constructor ============

    constructor(address _karaToken, address _safety, address _executor) Ownable(msg.sender) {
        require(_karaToken != address(0), "KaraGovernor: Invalid token");

        karaToken = IKaraToken(_karaToken);
        // Safety and executor can be set later via updateContracts to handle circular dependencies
        if (_safety != address(0)) {
            safety = IKaraSafety(_safety);
        }
        if (_executor != address(0)) {
            executor = IKaraExecutor(_executor);
        }
    }

    /**
     * @notice Update treasury reference
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "KaraGovernor: Invalid treasury");
        treasury = IKaraTreasury(_treasury);

        cycleStartTime = block.timestamp;

        // Initialize tier configs (Phase 1: Only INFO active)
        tierConfigs[Tier.INFO] = TierConfig({
            votingPeriod: 30 seconds,
            threshold: 5001, // 50% + 1
            minStake: 1_000 * 10 ** 18, // 1K KARA
            active: true
        });

        tierConfigs[Tier.ACTION] = TierConfig({
            votingPeriod: 1 minutes,
            threshold: 6000, // 60%
            minStake: 10_000 * 10 ** 18, // 10K KARA
            active: false // Disabled in Phase 1
        });

        tierConfigs[Tier.FUNDS] = TierConfig({
            votingPeriod: 5 minutes,
            threshold: 7500, // 75%
            minStake: 100_000 * 10 ** 18, // 100K KARA
            active: false // Disabled in Phase 1
        });

        tierConfigs[Tier.CRITICAL] = TierConfig({
            votingPeriod: 24 hours,
            threshold: 9000, // 90%
            minStake: 1_000_000 * 10 ** 18, // 1M KARA
            active: false // Disabled in Phase 1
        });
    }

    // ============ Proposal Functions ============

    /**
     * @notice Submit a new proposal for voting
     * @param promptHash Hash of the prompt to execute
     * @param tier Execution tier for this proposal
     * @return proposalId The ID of the created proposal
     */
    function submitProposal(bytes32 promptHash, Tier tier)
        external
        onlyAgent
        whenTierActive(tier)
        nonReentrant
        returns (uint256)
    {
        require(promptHash != bytes32(0), "KaraGovernor: Empty prompt hash");
        require(stakers[msg.sender].stakedAmount >= tierConfigs[tier].minStake, "KaraGovernor: Insufficient stake");

        // Advance cycle if needed
        _advanceCycle();

        proposalCount++;
        uint256 proposalId = proposalCount;

        TierConfig memory config = tierConfigs[tier];

        proposals[proposalId] = Proposal({
            promptHash: promptHash,
            tier: tier,
            startTime: block.timestamp,
            endTime: block.timestamp + config.votingPeriod,
            forVotes: 0,
            againstVotes: 0,
            executed: false,
            proposer: msg.sender,
            vetoed: false
        });

        cycleProposals[currentCycle].push(proposalId);

        emit ProposalSubmitted(proposalId, promptHash, tier, msg.sender, currentCycle);

        return proposalId;
    }

    /**
     * @notice Cast a vote on an active proposal
     * @param proposalId The proposal to vote on
     * @param support True for yes, false for no
     */
    function castVote(uint256 proposalId, bool support) external validProposal(proposalId) nonReentrant {
        Proposal storage proposal = proposals[proposalId];

        require(block.timestamp < proposal.endTime, "KaraGovernor: Voting ended");
        require(!proposal.executed, "KaraGovernor: Already executed");
        require(!proposal.vetoed, "KaraGovernor: Proposal vetoed");
        require(!hasVoted[proposalId][msg.sender], "KaraGovernor: Already voted");

        uint256 votingPower = getVotingPower(msg.sender);
        require(votingPower > 0, "KaraGovernor: No voting power");

        hasVoted[proposalId][msg.sender] = true;

        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }

        emit VoteCast(proposalId, msg.sender, support, votingPower);
    }

    /**
     * @notice Execute the winning proposal after voting ends
     * @param proposalId The proposal to execute
     */
    function executeWinningProposal(uint256 proposalId) external validProposal(proposalId) nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        TierConfig memory config = tierConfigs[proposal.tier];

        require(block.timestamp >= proposal.endTime, "KaraGovernor: Voting active");
        require(!proposal.executed, "KaraGovernor: Already executed");
        require(!proposal.vetoed, "KaraGovernor: Proposal vetoed");
        require(
            address(safety) == address(0) || safety.canExecute(uint8(proposal.tier)),
            "KaraGovernor: Tier execution blocked"
        );

        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        require(totalVotes > 0, "KaraGovernor: No votes cast");

        // Check threshold
        uint256 forPercentage = (proposal.forVotes * BASIS_POINTS) / totalVotes;
        require(forPercentage >= config.threshold, "KaraGovernor: Threshold not met");
        require(proposal.forVotes > proposal.againstVotes, "KaraGovernor: Not passed");

        proposal.executed = true;

        // Send to executor if set
        if (address(executor) != address(0)) {
            executor.receiveExecution(proposal.promptHash, uint8(proposal.tier));
        }

        emit ProposalExecuted(proposalId, proposal.promptHash, proposal.forVotes, proposal.againstVotes);
    }

    // ============ Voting Power & Delegation ============

    /**
     * @notice Calculate voting power with quadratic voting and multipliers
     * @param voter Address to calculate power for
     * @return The voting power
     */
    function getVotingPower(address voter) public view returns (uint256) {
        Staker memory staker = stakers[voter];

        if (staker.stakedAmount < MIN_STAKE_TO_VOTE) {
            return 0;
        }

        // Quadratic voting: sqrt(staked amount)
        uint256 sqrtStake = _sqrt(staker.stakedAmount);

        // Apply time multiplier
        uint256 timeMultiplier = staker.timeMultiplier;
        if (timeMultiplier == 0) {
            timeMultiplier = 100; // 1.0x default
        }

        uint256 power = (sqrtStake * timeMultiplier) / 100;

        // Apply delegate bonus if delegating to high-reputation agent
        if (staker.delegatedTo != address(0)) {
            Agent memory agent = agents[staker.delegatedTo];
            if (agent.reputationScore >= 80) {
                // High reputation threshold
                power = (power * DELEGATE_BONUS) / 100;
            }
        }

        return power;
    }

    /**
     * @notice Delegate voting power to an agent
     * @param agent The agent to delegate to (address(0) to undelegate)
     */
    function delegate(address agent) external {
        require(agent == address(0) || agents[agent].isActive, "KaraGovernor: Invalid agent");

        address previousDelegate = stakers[msg.sender].delegatedTo;
        stakers[msg.sender].delegatedTo = agent;

        emit DelegationChanged(msg.sender, previousDelegate, agent);
    }

    /**
     * @notice Update staker info from treasury
     * @param staker The staker address
     * @param amount The staked amount
     * @param lockEndTime When the stake unlocks
     * @param timeMultiplier The time lock multiplier
     */
    function updateStakerInfo(address staker, uint256 amount, uint256 lockEndTime, uint256 timeMultiplier) external {
        require(
            msg.sender == address(treasury) || msg.sender == owner() || msg.sender == address(karaToken),
            "KaraGovernor: Unauthorized"
        );

        stakers[staker].stakedAmount = amount;
        stakers[staker].lockEndTime = lockEndTime;
        stakers[staker].timeMultiplier = timeMultiplier;
    }

    // ============ Agent Registration ============

    /**
     * @notice Register as an agent delegate
     * @param metadataURI IPFS or other URI with agent metadata
     */
    function registerAgent(string calldata metadataURI) external nonReentrant {
        require(!agents[msg.sender].isActive, "KaraGovernor: Already registered");
        require(bytes(metadataURI).length > 0, "KaraGovernor: Empty metadata");

        // Beta mode: whitelist only
        if (betaMode) {
            require(isWhitelistedAgent[msg.sender], "KaraGovernor: Not whitelisted for beta");
            require(currentAgentCount < MAX_BETA_AGENTS, "KaraGovernor: Beta agent limit reached");
        }

        // Transfer registration stake
        require(
            karaToken.transferFrom(msg.sender, address(this), AGENT_REGISTRATION_STAKE),
            "KaraGovernor: Stake transfer failed"
        );

        agents[msg.sender] = Agent({
            agentAddress: msg.sender,
            registrationTime: block.timestamp,
            stakedAmount: AGENT_REGISTRATION_STAKE,
            reputationScore: 50, // Starting reputation
            metadataURI: metadataURI,
            isActive: true
        });

        currentAgentCount++;

        emit AgentRegistered(msg.sender, metadataURI, AGENT_REGISTRATION_STAKE);
    }

    /**
     * @notice Deregister as an agent and reclaim stake
     */
    function deregisterAgent() external nonReentrant {
        require(agents[msg.sender].isActive, "KaraGovernor: Not registered");

        uint256 stake = agents[msg.sender].stakedAmount;

        // Check if any active proposals
        // (Simplified: in production, check for active proposals)

        agents[msg.sender].isActive = false;
        currentAgentCount--;

        require(karaToken.transfer(msg.sender, stake), "KaraGovernor: Stake return failed");

        emit AgentDeregistered(msg.sender);
    }

    /**
     * @notice Whitelist an agent for beta (owner only)
     * @param agent Agent to whitelist
     */
    function whitelistAgent(address agent) external onlyOwner {
        require(agent != address(0), "KaraGovernor: Invalid address");
        isWhitelistedAgent[agent] = true;
    }

    /**
     * @notice Remove agent from whitelist
     * @param agent Agent to remove
     */
    function removeWhitelist(address agent) external onlyOwner {
        isWhitelistedAgent[agent] = false;
    }

    /**
     * @notice Update agent reputation (called by safety/executor)
     * @param agent Agent to update
     * @param newScore New reputation score (0-100)
     */
    function updateAgentReputation(address agent, uint256 newScore) external {
        require(
            msg.sender == address(safety) || msg.sender == address(executor) || msg.sender == owner(),
            "KaraGovernor: Unauthorized"
        );
        require(newScore <= 100, "KaraGovernor: Invalid score");
        require(agents[agent].isActive, "KaraGovernor: Agent not active");

        agents[agent].reputationScore = newScore;
    }

    // ============ Cycle Management ============

    /**
     * @notice Advance to the next cycle if duration elapsed
     */
    function _advanceCycle() internal {
        uint256 elapsed = block.timestamp - cycleStartTime;
        uint256 cyclesToAdvance = elapsed / CYCLE_DURATION;

        if (cyclesToAdvance > 0) {
            currentCycle += cyclesToAdvance;
            cycleStartTime += cyclesToAdvance * CYCLE_DURATION;
            emit CycleAdvanced(currentCycle, block.timestamp);
        }
    }

    /**
     * @notice Manually advance cycle (for testing/emergency)
     */
    function advanceCycle() external onlyOwner {
        currentCycle++;
        cycleStartTime = block.timestamp;
        emit CycleAdvanced(currentCycle, block.timestamp);
    }

    /**
     * @notice Get current cycle info
     */
    function getCurrentCycle() external view returns (uint256 cycle, uint256 startTime, uint256 timeRemaining) {
        uint256 elapsed = block.timestamp - cycleStartTime;
        uint256 timeInCycle = elapsed % CYCLE_DURATION;
        return (currentCycle, cycleStartTime, CYCLE_DURATION - timeInCycle);
    }

    /**
     * @notice Get proposals for a specific cycle
     */
    function getCycleProposals(uint256 cycle) external view returns (uint256[] memory) {
        return cycleProposals[cycle];
    }

    // ============ Admin Functions ============

    /**
     * @notice Update tier configuration
     */
    function updateTierConfig(Tier tier, uint256 votingPeriod, uint256 threshold, uint256 minStake, bool active)
        external
        onlyOwner
    {
        require(threshold <= BASIS_POINTS, "KaraGovernor: Invalid threshold");

        tierConfigs[tier] =
            TierConfig({votingPeriod: votingPeriod, threshold: threshold, minStake: minStake, active: active});

        emit TierConfigUpdated(tier, votingPeriod, threshold, minStake);
    }

    /**
     * @notice Disable beta mode to open registration
     */
    function disableBetaMode() external onlyOwner {
        betaMode = false;
    }

    /**
     * @notice Veto a proposal (emergency only, callable by safety)
     * @param proposalId Proposal to veto
     */
    function vetoProposal(uint256 proposalId) external validProposal(proposalId) {
        require(msg.sender == address(safety) || msg.sender == owner(), "KaraGovernor: Unauthorized");

        proposals[proposalId].vetoed = true;
        emit ProposalVetoed(proposalId);
    }

    /**
     * @notice Update contract references
     */
    function updateContracts(address _karaToken, address _safety, address _executor) external onlyOwner {
        if (_karaToken != address(0)) karaToken = IKaraToken(_karaToken);
        if (_safety != address(0)) safety = IKaraSafety(_safety);
        if (_executor != address(0)) executor = IKaraExecutor(_executor);
    }

    // ============ Internal Functions ============

    /**
     * @notice Calculate integer square root using Babylonian method
     */
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        uint256 y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }

        return y;
    }

    // ============ View Functions ============

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function getAgent(address agent) external view returns (Agent memory) {
        return agents[agent];
    }

    function getStaker(address staker) external view returns (Staker memory) {
        return stakers[staker];
    }

    function getTierConfig(Tier tier) external view returns (TierConfig memory) {
        return tierConfigs[tier];
    }
}
