// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./Interfaces.sol";

/**
 * @title KaraSafety
 * @notice Circuit breakers, emergency pause/veto, and slashing
 * @dev Sam has emergency veto + pause authority
 */
contract KaraSafety is Ownable, ReentrancyGuard {
    // ============ State Variables ============

    IKaraGovernor public governor;
    IKaraTreasury public treasury;
    IKaraExecutor public executor;
    IKaraToken public karaToken;

    // Sam's address (emergency powers)
    address public sam;

    // Pause state per tier
    mapping(uint8 => bool) public tierPaused;
    bool public globalPaused;

    // Circuit breaker config
    struct CircuitBreaker {
        uint256 failureThreshold;
        uint256 windowSize; // in cycles
        uint256 cooldownPeriod; // how long to pause
        bool autoTriggerEnabled;
    }

    mapping(uint8 => CircuitBreaker) public circuitBreakers;
    mapping(uint8 => uint256) public failureCount;
    mapping(uint8 => uint256) public lastFailureTime;
    mapping(uint8 => uint256) public pauseEndTime;

    // Slashing
    struct SlashRecord {
        address agent;
        uint256 amount;
        string reason;
        uint256 timestamp;
        bool appealed;
        bool overturned;
    }

    mapping(uint256 => SlashRecord) public slashRecords;
    uint256 public slashCount;
    uint256 public totalSlashed;

    // Appeal window
    uint256 public constant APPEAL_WINDOW = 7 days;

    // Proposal vetoes
    mapping(uint256 => bool) public criticalVetoes;
    mapping(uint256 => string) public vetoReasons;

    // Authorized guardians (can trigger circuit breakers)
    mapping(address => bool) public guardians;

    // ============ Events ============

    event EmergencyPaused(uint8 indexed tier, address indexed by, uint256 duration);
    event EmergencyUnpaused(uint8 indexed tier, address indexed by);
    event GlobalPaused(address indexed by);
    event GlobalUnpaused(address indexed by);

    event CircuitBreakerTriggered(uint8 indexed tier, uint256 failureCount, uint256 pauseUntil);

    event AgentSlashed(uint256 indexed slashId, address indexed agent, uint256 amount, string reason);

    event SlashAppealed(uint256 indexed slashId, string appealReason);
    event SlashOverturned(uint256 indexed slashId, string reason);

    event CriticalVetoed(uint256 indexed proposalId, address indexed by, string reason);

    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event SamUpdated(address indexed newSam);

    event FailureRecorded(uint8 indexed tier, uint256 count);

    // ============ Modifiers ============

    modifier onlySam() {
        require(msg.sender == sam, "KaraSafety: Only Sam");
        _;
    }

    modifier onlySamOrOwner() {
        require(msg.sender == sam || msg.sender == owner(), "KaraSafety: Only Sam or owner");
        _;
    }

    modifier onlyGuardian() {
        require(guardians[msg.sender] || msg.sender == sam || msg.sender == owner(), "KaraSafety: Not authorized");
        _;
    }

    modifier whenNotPaused(uint8 tier) {
        require(!globalPaused, "KaraSafety: Global pause active");
        require(!tierPaused[tier], "KaraSafety: Tier paused");
        require(block.timestamp > pauseEndTime[tier], "KaraSafety: Circuit breaker active");
        _;
    }

    // ============ Constructor ============

    constructor(address _governor, address _treasury, address _executor, address _karaToken, address _sam)
        Ownable(msg.sender)
    {
        require(_sam != address(0), "KaraSafety: Invalid Sam address");

        // Governor can be set later via updateContracts to handle circular dependencies
        if (_governor != address(0)) {
            governor = IKaraGovernor(_governor);
        }
        treasury = IKaraTreasury(_treasury);
        executor = IKaraExecutor(_executor);
        karaToken = IKaraToken(_karaToken);
        sam = _sam;

        // Initialize circuit breakers
        circuitBreakers[0] = CircuitBreaker({ // INFO tier
            failureThreshold: 5,
            windowSize: 20,
            cooldownPeriod: 1 hours,
            autoTriggerEnabled: true
        });

        circuitBreakers[1] = CircuitBreaker({ // ACTION tier
            failureThreshold: 3,
            windowSize: 10,
            cooldownPeriod: 1 hours,
            autoTriggerEnabled: true
        });

        circuitBreakers[2] = CircuitBreaker({ // FUNDS tier
            failureThreshold: 2,
            windowSize: 5,
            cooldownPeriod: 4 hours,
            autoTriggerEnabled: true
        });

        circuitBreakers[3] = CircuitBreaker({ // CRITICAL tier
            failureThreshold: 1,
            windowSize: 1,
            cooldownPeriod: 24 hours,
            autoTriggerEnabled: false // Manual only for critical
        });
    }

    // ============ Emergency Pause Functions ============

    /**
     * @notice Emergency pause a specific tier (Sam only)
     * @param tier Tier to pause
     */
    function emergencyPause(uint8 tier) external onlySamOrOwner {
        require(tier <= 3, "KaraSafety: Invalid tier");
        tierPaused[tier] = true;
        emit EmergencyPaused(tier, msg.sender, 0);
    }

    /**
     * @notice Emergency unpause a tier (Sam or DAO vote required for >24h)
     * @param tier Tier to unpause
     */
    function emergencyUnpause(uint8 tier) external {
        require(tier <= 3, "KaraSafety: Invalid tier");

        if (msg.sender == sam || msg.sender == owner()) {
            tierPaused[tier] = false;
            pauseEndTime[tier] = 0;
            emit EmergencyUnpaused(tier, msg.sender);
        } else {
            // DAO vote required - would check governor
            revert("KaraSafety: Only Sam or DAO vote");
        }
    }

    /**
     * @notice Global pause all tiers (Sam only)
     */
    function globalPause() external onlySam {
        globalPaused = true;
        emit GlobalPaused(msg.sender);
    }

    /**
     * @notice Global unpause (Sam only)
     */
    function globalUnpause() external onlySam {
        globalPaused = false;
        emit GlobalUnpaused(msg.sender);
    }

    // ============ Circuit Breaker Functions ============

    /**
     * @notice Record a failure for circuit breaker tracking
     * @param tier Tier where failure occurred
     */
    function recordFailure(uint8 tier) external onlyGuardian {
        require(tier <= 3, "KaraSafety: Invalid tier");

        failureCount[tier]++;
        lastFailureTime[tier] = block.timestamp;

        emit FailureRecorded(tier, failureCount[tier]);

        // Check if circuit breaker should trigger
        _checkCircuitBreaker(tier);
    }

    /**
     * @notice Manually trigger circuit breaker
     * @param tier Tier to pause
     * @param duration Pause duration in seconds
     */
    function triggerCircuitBreaker(uint8 tier, uint256 duration) external onlyGuardian {
        require(tier <= 3, "KaraSafety: Invalid tier");
        pauseEndTime[tier] = block.timestamp + duration;
        emit CircuitBreakerTriggered(tier, failureCount[tier], pauseEndTime[tier]);
    }

    /**
     * @notice Check and potentially trigger circuit breaker
     */
    function _checkCircuitBreaker(uint8 tier) internal {
        CircuitBreaker memory cb = circuitBreakers[tier];

        if (!cb.autoTriggerEnabled) return;
        if (failureCount[tier] < cb.failureThreshold) return;

        // Check if within window
        // In production, would check actual cycle count
        pauseEndTime[tier] = block.timestamp + cb.cooldownPeriod;

        emit CircuitBreakerTriggered(tier, failureCount[tier], pauseEndTime[tier]);

        // Reset failure count after triggering
        failureCount[tier] = 0;
    }

    /**
     * @notice Reset failure count for a tier
     * @param tier Tier to reset
     */
    function resetFailureCount(uint8 tier) external onlySamOrOwner {
        failureCount[tier] = 0;
    }

    // ============ Slashing Functions ============

    /**
     * @notice Slash an agent for misbehavior
     * @param agent Agent to slash
     * @param amount Amount to slash (in KARA)
     * @param reason Reason for slashing
     * @return slashId The ID of the slash record
     */
    function slashAgent(address agent, uint256 amount, string calldata reason)
        external
        onlyGuardian
        nonReentrant
        returns (uint256)
    {
        require(agent != address(0), "KaraSafety: Invalid agent");
        require(amount > 0, "KaraSafety: Invalid amount");
        require(bytes(reason).length > 0, "KaraSafety: Empty reason");

        slashCount++;
        slashRecords[slashCount] = SlashRecord({
            agent: agent, amount: amount, reason: reason, timestamp: block.timestamp, appealed: false, overturned: false
        });

        totalSlashed += amount;

        // In production, would:
        // 1. Deregister agent from governor
        // 2. Transfer slashed amount to treasury
        // 3. Update agent reputation

        emit AgentSlashed(slashCount, agent, amount, reason);

        return slashCount;
    }

    /**
     * @notice Appeal a slash (can be called by anyone on behalf of agent)
     * @param slashId Slash record to appeal
     * @param appealReason Reason for appeal
     */
    function appealSlash(uint256 slashId, string calldata appealReason) external {
        require(slashId > 0 && slashId <= slashCount, "KaraSafety: Invalid slash ID");

        SlashRecord storage record = slashRecords[slashId];
        require(!record.appealed, "KaraSafety: Already appealed");
        require(block.timestamp <= record.timestamp + APPEAL_WINDOW, "KaraSafety: Appeal window closed");

        record.appealed = true;
        emit SlashAppealed(slashId, appealReason);
    }

    /**
     * @notice Overturn a slash (Sam or DAO vote)
     * @param slashId Slash to overturn
     * @param reason Reason for overturning
     */
    function overturnSlash(uint256 slashId, string calldata reason) external onlySamOrOwner {
        require(slashId > 0 && slashId <= slashCount, "KaraSafety: Invalid slash ID");

        SlashRecord storage record = slashRecords[slashId];
        require(record.appealed, "KaraSafety: Not appealed");
        require(!record.overturned, "KaraSafety: Already overturned");

        record.overturned = true;
        totalSlashed -= record.amount;

        // Return slashed funds
        // Implementation depends on where slashed funds go

        emit SlashOverturned(slashId, reason);
    }

    // ============ Veto Functions ============

    /**
     * @notice Veto a critical tier proposal (Sam only)
     * @param proposalId Proposal to veto
     * @param reason Reason for veto
     */
    function vetoCritical(uint256 proposalId, string calldata reason) external onlySam {
        criticalVetoes[proposalId] = true;
        vetoReasons[proposalId] = reason;

        // Call governor to mark proposal as vetoed
        // governor.vetoProposal(proposalId);

        emit CriticalVetoed(proposalId, msg.sender, reason);
    }

    /**
     * @notice Check if a proposal is vetoed
     * @param proposalId Proposal to check
     */
    function isVetoed(uint256 proposalId) external view returns (bool) {
        return criticalVetoes[proposalId];
    }

    // ============ Admin Functions ============

    /**
     * @notice Add a guardian
     * @param guardian Address to add
     */
    function addGuardian(address guardian) external onlySamOrOwner {
        require(guardian != address(0), "KaraSafety: Invalid address");
        guardians[guardian] = true;
        emit GuardianAdded(guardian);
    }

    /**
     * @notice Remove a guardian
     * @param guardian Address to remove
     */
    function removeGuardian(address guardian) external onlySamOrOwner {
        guardians[guardian] = false;
        emit GuardianRemoved(guardian);
    }

    /**
     * @notice Update Sam's address (Sam only)
     * @param newSam New Sam address
     */
    function updateSam(address newSam) external onlySam {
        require(newSam != address(0), "KaraSafety: Invalid address");
        sam = newSam;
        emit SamUpdated(newSam);
    }

    /**
     * @notice Update circuit breaker config
     * @param tier Tier to update
     * @param threshold New failure threshold
     * @param windowSize New window size
     * @param cooldown New cooldown period
     * @param autoTrigger Enable auto trigger
     */
    function updateCircuitBreaker(uint8 tier, uint256 threshold, uint256 windowSize, uint256 cooldown, bool autoTrigger)
        external
        onlySamOrOwner
    {
        require(tier <= 3, "KaraSafety: Invalid tier");

        circuitBreakers[tier] = CircuitBreaker({
            failureThreshold: threshold,
            windowSize: windowSize,
            cooldownPeriod: cooldown,
            autoTriggerEnabled: autoTrigger
        });
    }

    /**
     * @notice Update contract references
     */
    function updateContracts(address _governor, address _treasury, address _executor, address _karaToken)
        external
        onlySamOrOwner
    {
        if (_governor != address(0)) governor = IKaraGovernor(_governor);
        if (_treasury != address(0)) treasury = IKaraTreasury(_treasury);
        if (_executor != address(0)) executor = IKaraExecutor(_executor);
        if (_karaToken != address(0)) karaToken = IKaraToken(_karaToken);
    }

    // ============ View Functions ============

    /**
     * @notice Check if a tier is paused
     * @param tier Tier to check
     */
    function isPaused(uint8 tier) external view returns (bool) {
        if (globalPaused) return true;
        if (tierPaused[tier]) return true;
        if (block.timestamp <= pauseEndTime[tier]) return true;
        return false;
    }

    /**
     * @notice Check if execution is allowed for tier
     * @param tier Tier to check
     */
    function canExecute(uint8 tier) external view returns (bool) {
        if (globalPaused) return false;
        if (tierPaused[tier]) return false;
        if (block.timestamp <= pauseEndTime[tier]) return false;
        return true;
    }

    /**
     * @notice Get slash record
     * @param slashId Slash ID
     */
    function getSlashRecord(uint256 slashId) external view returns (SlashRecord memory) {
        return slashRecords[slashId];
    }

    /**
     * @notice Get circuit breaker status
     * @param tier Tier to check
     */
    function getCircuitBreakerStatus(uint8 tier)
        external
        view
        returns (uint256 failures, uint256 lastFailure, uint256 pausedUntil, bool isActive)
    {
        return (failureCount[tier], lastFailureTime[tier], pauseEndTime[tier], block.timestamp <= pauseEndTime[tier]);
    }

    /**
     * @notice Check if address is guardian
     */
    function isGuardian(address addr) external view returns (bool) {
        return guardians[addr];
    }
}
