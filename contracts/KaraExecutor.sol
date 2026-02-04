// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./Interfaces.sol";

/**
 * @title KaraExecutor
 * @notice Interface between on-chain votes and off-chain execution
 * @dev Receives winning prompts and emits events for Kara's message queue
 */
contract KaraExecutor is Ownable, ReentrancyGuard {
    // ============ State Variables ============

    IKaraGovernor public governor;
    IKaraSafety public safety;
    IKaraTreasury public treasury;

    // Execution tracking
    struct Execution {
        bytes32 promptHash;
        uint8 tier;
        uint256 timestamp;
        bool executed;
        bool success;
        address executor; // Off-chain executor that claimed this
        string resultURI; // IPFS hash of execution result
        uint256 retryCount;
    }

    mapping(uint256 => Execution) public executions;
    mapping(bytes32 => uint256) public promptToExecution;
    mapping(address => bool) public authorizedExecutors;

    uint256 public executionCount;
    uint256 public pendingCount;

    // Execution config
    uint256 public constant MAX_RETRIES = 3;
    uint256 public executionTimeout = 5 minutes;

    // Circuit breaker tracking
    uint256 public consecutiveFailures;
    uint256 public lastFailureTime;
    uint256 public constant FAILURE_THRESHOLD = 3;
    uint256 public constant FAILURE_WINDOW = 10; // cycles

    // ============ Events ============

    event ExecutionRequested(
        bytes32 indexed promptHash, uint8 tier, uint256 indexed executionId, uint256 timestamp, uint256 cycle
    );

    event ExecutionClaimed(uint256 indexed executionId, address indexed executor);

    event ExecutionCompleted(uint256 indexed executionId, bool success, string resultURI);

    event ExecutionRetry(uint256 indexed executionId, uint256 retryCount);

    event ExecutionFailed(uint256 indexed executionId, string reason);

    event BatchExecutionRequested(bytes32[] promptHashes, uint8[] tiers, uint256[] executionIds);

    event ExecutorAuthorized(address indexed executor, bool authorized);
    event TimeoutUpdated(uint256 newTimeout);

    // ============ Modifiers ============

    modifier onlyGovernor() {
        require(address(governor) != address(0) && msg.sender == address(governor), "KaraExecutor: Only governor");
        _;
    }

    modifier onlyAuthorizedExecutor() {
        require(authorizedExecutors[msg.sender], "KaraExecutor: Not authorized");
        _;
    }

    modifier validExecution(uint256 executionId) {
        require(executionId > 0 && executionId <= executionCount, "KaraExecutor: Invalid execution");
        _;
    }

    // ============ Constructor ============

    constructor(address _governor, address _safety, address _treasury) Ownable(msg.sender) {
        require(_safety != address(0), "KaraExecutor: Invalid safety");

        // Governor can be set later via updateContracts to handle circular dependencies
        if (_governor != address(0)) {
            governor = IKaraGovernor(_governor);
        }
        safety = IKaraSafety(_safety);
        if (_treasury != address(0)) {
            treasury = IKaraTreasury(_treasury);
        }
    }

    // ============ Core Functions ============

    /**
     * @notice Receive execution request from governor (winning proposal)
     * @param promptHash Hash of the prompt to execute
     * @param tier Execution tier
     * @return executionId The ID of the created execution
     */
    function receiveExecution(bytes32 promptHash, uint8 tier) external onlyGovernor nonReentrant returns (uint256) {
        require(promptHash != bytes32(0), "KaraExecutor: Empty prompt");
        require(address(safety) == address(0) || safety.canExecute(tier), "KaraExecutor: Tier blocked");

        // Check if this prompt already has a pending execution
        require(
            promptToExecution[promptHash] == 0 || executions[promptToExecution[promptHash]].executed,
            "KaraExecutor: Duplicate pending execution"
        );

        executionCount++;
        uint256 executionId = executionCount;

        executions[executionId] = Execution({
            promptHash: promptHash,
            tier: tier,
            timestamp: block.timestamp,
            executed: false,
            success: false,
            executor: address(0),
            resultURI: "",
            retryCount: 0
        });

        promptToExecution[promptHash] = executionId;
        pendingCount++;

        // Get current cycle from governor
        (uint256 cycle,,) = getCycleInfo();

        emit ExecutionRequested(promptHash, tier, executionId, block.timestamp, cycle);

        return executionId;
    }

    /**
     * @notice Receive batch execution from governor
     * @param promptHashes Array of prompt hashes
     * @param tiers Array of tiers
     */
    function receiveBatchExecution(bytes32[] calldata promptHashes, uint8[] calldata tiers)
        external
        onlyGovernor
        nonReentrant
    {
        require(promptHashes.length == tiers.length, "KaraExecutor: Array length mismatch");
        require(promptHashes.length > 0, "KaraExecutor: Empty batch");
        require(promptHashes.length <= 10, "KaraExecutor: Batch too large");

        uint256[] memory executionIds = new uint256[](promptHashes.length);

        for (uint256 i = 0; i < promptHashes.length; i++) {
            require(address(safety) == address(0) || safety.canExecute(tiers[i]), "KaraExecutor: Tier blocked");

            executionCount++;
            executionIds[i] = executionCount;

            executions[executionCount] = Execution({
                promptHash: promptHashes[i],
                tier: tiers[i],
                timestamp: block.timestamp,
                executed: false,
                success: false,
                executor: address(0),
                resultURI: "",
                retryCount: 0
            });

            promptToExecution[promptHashes[i]] = executionCount;
            pendingCount++;
        }

        emit BatchExecutionRequested(promptHashes, tiers, executionIds);
    }

    /**
     * @notice Claim an execution for off-chain processing
     * @param executionId Execution to claim
     */
    function claimExecution(uint256 executionId) external onlyAuthorizedExecutor validExecution(executionId) {
        Execution storage execution = executions[executionId];

        require(!execution.executed, "KaraExecutor: Already executed");
        require(execution.executor == address(0), "KaraExecutor: Already claimed");
        require(block.timestamp <= execution.timestamp + executionTimeout, "KaraExecutor: Execution expired");

        execution.executor = msg.sender;

        emit ExecutionClaimed(executionId, msg.sender);
    }

    /**
     * @notice Confirm execution completion
     * @param executionId Execution to confirm
     * @param success Whether execution succeeded
     * @param resultURI IPFS hash of execution result
     */
    function confirmExecution(uint256 executionId, bool success, string calldata resultURI)
        external
        onlyAuthorizedExecutor
        validExecution(executionId)
        nonReentrant
    {
        Execution storage execution = executions[executionId];

        require(execution.executor == msg.sender, "KaraExecutor: Not claimed by you");
        require(!execution.executed, "KaraExecutor: Already executed");

        execution.executed = true;
        execution.success = success;
        execution.resultURI = resultURI;
        pendingCount--;

        if (success) {
            // Reset failure counter on success
            consecutiveFailures = 0;

            // Update agent reputation via governor
            _updateReputation(executionId, true);
        } else {
            // Track failures for circuit breaker
            consecutiveFailures++;
            lastFailureTime = block.timestamp;

            // Update agent reputation
            _updateReputation(executionId, false);

            // Check if we need to trigger circuit breaker
            if (consecutiveFailures >= FAILURE_THRESHOLD) {
                emit ExecutionFailed(executionId, "Circuit breaker threshold reached");
            }
        }

        emit ExecutionCompleted(executionId, success, resultURI);
    }

    /**
     * @notice Request a retry for failed execution
     * @param executionId Execution to retry
     */
    function requestRetry(uint256 executionId) external onlyAuthorizedExecutor validExecution(executionId) {
        Execution storage execution = executions[executionId];

        require(execution.executed, "KaraExecutor: Not yet executed");
        require(!execution.success, "KaraExecutor: Already successful");
        require(execution.retryCount < MAX_RETRIES, "KaraExecutor: Max retries reached");

        execution.executed = false;
        execution.executor = address(0);
        execution.retryCount++;
        pendingCount++;

        emit ExecutionRetry(executionId, execution.retryCount);
    }

    // ============ Admin Functions ============

    /**
     * @notice Authorize an executor address
     * @param executor Address to authorize
     * @param authorized Authorization status
     */
    function setExecutorAuthorization(address executor, bool authorized) external onlyOwner {
        require(executor != address(0), "KaraExecutor: Invalid address");
        authorizedExecutors[executor] = authorized;
        emit ExecutorAuthorized(executor, authorized);
    }

    /**
     * @notice Update execution timeout
     * @param newTimeout New timeout in seconds
     */
    function setExecutionTimeout(uint256 newTimeout) external onlyOwner {
        require(newTimeout >= 1 minutes && newTimeout <= 1 hours, "KaraExecutor: Invalid timeout");
        executionTimeout = newTimeout;
        emit TimeoutUpdated(newTimeout);
    }

    /**
     * @notice Force mark execution as failed (emergency)
     * @param executionId Execution to mark
     */
    function forceFailExecution(uint256 executionId) external onlyOwner validExecution(executionId) {
        Execution storage execution = executions[executionId];
        require(!execution.executed, "KaraExecutor: Already executed");

        execution.executed = true;
        execution.success = false;
        pendingCount--;

        emit ExecutionCompleted(executionId, false, "Force failed by admin");
    }

    /**
     * @notice Update contract references
     */
    function updateContracts(address _governor, address _safety, address _treasury) external onlyOwner {
        if (_governor != address(0)) governor = IKaraGovernor(_governor);
        if (_safety != address(0)) safety = IKaraSafety(_safety);
        if (_treasury != address(0)) treasury = IKaraTreasury(_treasury);
    }

    // ============ View Functions ============

    /**
     * @notice Get all pending executions
     * @return Array of pending execution IDs
     */
    function getPendingExecutions() external view returns (Execution[] memory) {
        Execution[] memory pending = new Execution[](pendingCount);
        uint256 index = 0;

        for (uint256 i = 1; i <= executionCount && index < pendingCount; i++) {
            if (!executions[i].executed) {
                pending[index] = executions[i];
                index++;
            }
        }

        return pending;
    }

    /**
     * @notice Get pending execution IDs only
     * @return Array of pending execution IDs
     */
    function getPendingExecutionIds() external view returns (uint256[] memory) {
        uint256[] memory pendingIds = new uint256[](pendingCount);
        uint256 index = 0;

        for (uint256 i = 1; i <= executionCount && index < pendingCount; i++) {
            if (!executions[i].executed) {
                pendingIds[index] = i;
                index++;
            }
        }

        return pendingIds;
    }

    /**
     * @notice Get execution details
     */
    function getExecution(uint256 executionId) external view returns (Execution memory) {
        return executions[executionId];
    }

    /**
     * @notice Get execution ID by prompt hash
     */
    function getExecutionByPrompt(bytes32 promptHash) external view returns (uint256) {
        return promptToExecution[promptHash];
    }

    /**
     * @notice Check if an executor is authorized
     */
    function isAuthorizedExecutor(address executor) external view returns (bool) {
        return authorizedExecutors[executor];
    }

    /**
     * @notice Get cycle info from governor
     */
    function getCycleInfo() public view returns (uint256 cycle, uint256 startTime, uint256 timeRemaining) {
        // This would call governor.getCurrentCycle() if we had that interface
        // For now, return placeholder values
        return (0, block.timestamp, 0);
    }

    /**
     * @notice Check if circuit breaker should trigger
     */
    function shouldTriggerCircuitBreaker() external view returns (bool) {
        return consecutiveFailures >= FAILURE_THRESHOLD;
    }

    // ============ Internal Functions ============

    /**
     * @notice Update agent reputation based on execution result
     */
    function _updateReputation(
        uint256,
        /*executionId*/
        bool /*success*/
    )
        internal {
        // This would call back to governor to update reputation
        // Implementation depends on cross-contract call pattern
    }
}
