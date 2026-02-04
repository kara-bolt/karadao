// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/KaraGovernor.sol";
import "../contracts/KaraExecutor.sol";
import "../contracts/KaraTreasury.sol";
import "../contracts/KaraSafety.sol";
import "../contracts/MockKaraToken.sol";

/**
 * @title KaraExecutorTest
 * @notice Comprehensive test suite for KaraExecutor contract
 */
contract KaraExecutorTest is Test {
    KaraGovernor public governor;
    KaraExecutor public executor;
    KaraTreasury public treasury;
    KaraSafety public safety;
    MockKaraToken public karaToken;

    address public owner;
    address public sam;
    address public agent1;
    address public executor1;
    address public executor2;

    uint256 constant INITIAL_MINT = 1_000_000_000 * 10 ** 18;
    uint256 constant AGENT_STAKE = 50_000 * 10 ** 18;

    function setUp() public {
        owner = address(this);
        sam = makeAddr("sam");
        agent1 = makeAddr("agent1");
        executor1 = makeAddr("executor1");
        executor2 = makeAddr("executor2");

        // Deploy mock token
        karaToken = new MockKaraToken("KARA Token", "KARA", 18);

        // Deploy safety
        safety = new KaraSafety(address(0), address(0), address(0), address(karaToken), sam);

        // Deploy treasury
        treasury = new KaraTreasury(address(karaToken), address(0), address(safety));

        // Deploy executor
        executor = new KaraExecutor(address(0), address(safety), address(treasury));

        // Deploy governor
        governor = new KaraGovernor(address(karaToken), address(safety), address(executor));

        // Update references
        safety.updateContracts(address(governor), address(treasury), address(executor), address(karaToken));
        treasury.updateContracts(address(governor), address(safety));
        executor.updateContracts(address(governor), address(safety), address(treasury));

        // Fund accounts
        karaToken.transfer(agent1, AGENT_STAKE * 10);

        // Whitelist and authorize
        governor.whitelistAgent(agent1);
        executor.setExecutorAuthorization(executor1, true);
        executor.setExecutorAuthorization(executor2, true);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsInitialState() public view {
        assertEq(address(executor.governor()), address(governor));
        assertEq(address(executor.safety()), address(safety));
        assertEq(address(executor.treasury()), address(treasury));
        assertEq(executor.executionTimeout(), 5 minutes);
        assertEq(executor.executionCount(), 0);
    }

    function test_Constructor_AllowsInvalidGovernor() public {
        // Governor can be set later via updateContracts
        KaraExecutor e = new KaraExecutor(address(0), address(safety), address(treasury));
        assertEq(address(e.safety()), address(safety));
    }

    function test_Constructor_RevertsWithInvalidSafety() public {
        vm.expectRevert("KaraExecutor: Invalid safety");
        new KaraExecutor(address(governor), address(0), address(treasury));
    }

    // ============ Receive Execution Tests ============

    function test_ReceiveExecution_Success() public {
        bytes32 promptHash = keccak256("test prompt");
        uint8 tier = 0; // INFO

        vm.expectEmit(true, true, true, true);
        emit KaraExecutor.ExecutionRequested(promptHash, tier, 1, block.timestamp, 0);

        // Only governor can call
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(promptHash, tier);

        assertEq(executionId, 1);
        assertEq(executor.executionCount(), 1);
        assertEq(executor.pendingCount(), 1);

        (
            bytes32 storedHash,
            uint8 storedTier,
            uint256 timestamp,
            bool executed,
            bool success,
            address exec,
            string memory resultURI,
            uint256 retryCount
        ) = executor.executions(executionId);

        assertEq(storedHash, promptHash);
        assertEq(storedTier, tier);
        assertGt(timestamp, 0);
        assertFalse(executed);
        assertFalse(success);
        assertEq(exec, address(0));
        assertEq(bytes(resultURI).length, 0);
        assertEq(retryCount, 0);
    }

    function test_ReceiveExecution_RevertsForNonGovernor() public {
        vm.expectRevert("KaraExecutor: Only governor");
        executor.receiveExecution(keccak256("test"), 0);
    }

    function test_ReceiveExecution_RevertsWithEmptyHash() public {
        vm.prank(address(governor));
        vm.expectRevert("KaraExecutor: Empty prompt");
        executor.receiveExecution(bytes32(0), 0);
    }

    function test_ReceiveExecution_RevertsWhenTierBlocked() public {
        // Pause the tier
        safety.emergencyPause(0);

        vm.prank(address(governor));
        vm.expectRevert("KaraExecutor: Tier blocked");
        executor.receiveExecution(keccak256("test"), 0);
    }

    function test_ReceiveExecution_RevertsDuplicatePending() public {
        bytes32 promptHash = keccak256("test prompt");

        vm.startPrank(address(governor));
        executor.receiveExecution(promptHash, 0);

        vm.expectRevert("KaraExecutor: Duplicate pending execution");
        executor.receiveExecution(promptHash, 0);
        vm.stopPrank();
    }

    // ============ Batch Execution Tests ============

    function test_ReceiveBatchExecution_Success() public {
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256("test1");
        hashes[1] = keccak256("test2");
        hashes[2] = keccak256("test3");

        uint8[] memory tiers = new uint8[](3);
        tiers[0] = 0;
        tiers[1] = 0;
        tiers[2] = 0;

        vm.prank(address(governor));
        executor.receiveBatchExecution(hashes, tiers);

        assertEq(executor.executionCount(), 3);
        assertEq(executor.pendingCount(), 3);
    }

    function test_ReceiveBatchExecution_RevertsArrayLengthMismatch() public {
        bytes32[] memory hashes = new bytes32[](2);
        uint8[] memory tiers = new uint8[](3);

        vm.prank(address(governor));
        vm.expectRevert("KaraExecutor: Array length mismatch");
        executor.receiveBatchExecution(hashes, tiers);
    }

    function test_ReceiveBatchExecution_RevertsEmptyBatch() public {
        bytes32[] memory hashes = new bytes32[](0);
        uint8[] memory tiers = new uint8[](0);

        vm.prank(address(governor));
        vm.expectRevert("KaraExecutor: Empty batch");
        executor.receiveBatchExecution(hashes, tiers);
    }

    function test_ReceiveBatchExecution_RevertsBatchTooLarge() public {
        bytes32[] memory hashes = new bytes32[](11);
        uint8[] memory tiers = new uint8[](11);

        vm.prank(address(governor));
        vm.expectRevert("KaraExecutor: Batch too large");
        executor.receiveBatchExecution(hashes, tiers);
    }

    // ============ Claim Execution Tests ============

    function test_ClaimExecution_Success() public {
        // Create execution
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        // Claim as authorized executor
        vm.prank(executor1);
        vm.expectEmit(true, true, false, false);
        emit KaraExecutor.ExecutionClaimed(executionId, executor1);

        executor.claimExecution(executionId);

        (,,,,, address exec,,) = executor.executions(executionId);
        assertEq(exec, executor1);
    }

    function test_ClaimExecution_RevertsForUnauthorized() public {
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert("KaraExecutor: Not authorized");
        executor.claimExecution(executionId);
    }

    function test_ClaimExecution_RevertsIfAlreadyExecuted() public {
        // Create, claim, and complete execution
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        vm.prank(executor1);
        executor.claimExecution(executionId);

        vm.prank(executor1);
        executor.confirmExecution(executionId, true, "ipfs://result");

        // Try to claim again
        vm.prank(executor2);
        vm.expectRevert("KaraExecutor: Already executed");
        executor.claimExecution(executionId);
    }

    function test_ClaimExecution_RevertsIfAlreadyClaimed() public {
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        vm.prank(executor1);
        executor.claimExecution(executionId);

        vm.prank(executor2);
        vm.expectRevert("KaraExecutor: Already claimed");
        executor.claimExecution(executionId);
    }

    function test_ClaimExecution_RevertsIfExpired() public {
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        // Fast forward past timeout
        vm.warp(block.timestamp + 6 minutes);

        vm.prank(executor1);
        vm.expectRevert("KaraExecutor: Execution expired");
        executor.claimExecution(executionId);
    }

    // ============ Confirm Execution Tests ============

    function test_ConfirmExecution_Success() public {
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        vm.prank(executor1);
        executor.claimExecution(executionId);

        vm.prank(executor1);
        vm.expectEmit(true, true, true, true);
        emit KaraExecutor.ExecutionCompleted(executionId, true, "ipfs://result");

        executor.confirmExecution(executionId, true, "ipfs://result");

        (,,, bool executed, bool success,, string memory resultURI,) = executor.executions(executionId);
        assertTrue(executed);
        assertTrue(success);
        assertEq(resultURI, "ipfs://result");
        assertEq(executor.pendingCount(), 0);
    }

    function test_ConfirmExecution_TracksFailures() public {
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        vm.prank(executor1);
        executor.claimExecution(executionId);

        vm.prank(executor1);
        executor.confirmExecution(executionId, false, "ipfs://failure");

        assertEq(executor.consecutiveFailures(), 1);
        assertGt(executor.lastFailureTime(), 0);
    }

    function test_ConfirmExecution_ResetsFailureOnSuccess() public {
        // First failure
        vm.prank(address(governor));
        uint256 id1 = executor.receiveExecution(keccak256("test1"), 0);
        vm.prank(executor1);
        executor.claimExecution(id1);
        vm.prank(executor1);
        executor.confirmExecution(id1, false, "");

        // Success
        vm.prank(address(governor));
        uint256 id2 = executor.receiveExecution(keccak256("test2"), 0);
        vm.prank(executor2);
        executor.claimExecution(id2);
        vm.prank(executor2);
        executor.confirmExecution(id2, true, "success");

        assertEq(executor.consecutiveFailures(), 0);
    }

    function test_ConfirmExecution_RevertsIfNotClaimedByYou() public {
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        vm.prank(executor1);
        executor.claimExecution(executionId);

        vm.prank(executor2);
        vm.expectRevert("KaraExecutor: Not claimed by you");
        executor.confirmExecution(executionId, true, "");
    }

    // ============ Retry Tests ============

    function test_RequestRetry_Success() public {
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        vm.prank(executor1);
        executor.claimExecution(executionId);

        vm.prank(executor1);
        executor.confirmExecution(executionId, false, "failed");

        vm.prank(executor2);
        vm.expectEmit(true, false, false, true);
        emit KaraExecutor.ExecutionRetry(executionId, 1);

        executor.requestRetry(executionId);

        (,,, bool executed,, address exec,, uint256 retryCount) = executor.executions(executionId);
        assertFalse(executed);
        assertEq(exec, address(0));
        assertEq(retryCount, 1);
        assertEq(executor.pendingCount(), 1);
    }

    function test_RequestRetry_RevertsIfMaxRetriesReached() public {
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        // Original attempt + 3 retries = 4 total attempts
        for (uint256 i = 0; i < 3; i++) {
            // Claim
            vm.prank(executor1);
            executor.claimExecution(executionId);

            // Confirm failure
            vm.prank(executor1);
            executor.confirmExecution(executionId, false, "failed");

            // Retry (all 3 retries allowed)
            vm.prank(executor1);
            executor.requestRetry(executionId);
        }

        // Claim and fail for 4th time
        vm.prank(executor1);
        executor.claimExecution(executionId);
        vm.prank(executor1);
        executor.confirmExecution(executionId, false, "failed");

        // Try to retry 4th time - should fail because retryCount = 3 (MAX_RETRIES)
        vm.prank(executor1);
        vm.expectRevert("KaraExecutor: Max retries reached");
        executor.requestRetry(executionId);
    }

    // ============ Admin Tests ============

    function test_SetExecutorAuthorization() public {
        address newExecutor = makeAddr("newExecutor");
        assertFalse(executor.isAuthorizedExecutor(newExecutor));

        executor.setExecutorAuthorization(newExecutor, true);

        assertTrue(executor.isAuthorizedExecutor(newExecutor));
    }

    function test_SetExecutorAuthorization_RevertsForNonOwner() public {
        vm.prank(executor1);
        vm.expectRevert();
        executor.setExecutorAuthorization(makeAddr("new"), true);
    }

    function test_SetExecutorAuthorization_RevertsForZeroAddress() public {
        vm.expectRevert("KaraExecutor: Invalid address");
        executor.setExecutorAuthorization(address(0), true);
    }

    function test_SetExecutionTimeout() public {
        executor.setExecutionTimeout(10 minutes);
        assertEq(executor.executionTimeout(), 10 minutes);
    }

    function test_SetExecutionTimeout_RevertsForInvalidTimeout() public {
        vm.expectRevert("KaraExecutor: Invalid timeout");
        executor.setExecutionTimeout(30 seconds); // Too short

        vm.expectRevert("KaraExecutor: Invalid timeout");
        executor.setExecutionTimeout(2 hours); // Too long
    }

    function test_ForceFailExecution() public {
        vm.prank(address(governor));
        uint256 executionId = executor.receiveExecution(keccak256("test"), 0);

        vm.prank(executor1);
        executor.claimExecution(executionId);

        executor.forceFailExecution(executionId);

        (,,, bool executed, bool success,,,) = executor.executions(executionId);
        assertTrue(executed);
        assertFalse(success);
    }

    function test_UpdateContracts() public {
        address newSafety = makeAddr("newSafety");

        executor.updateContracts(address(0), newSafety, address(0));

        assertEq(address(executor.safety()), newSafety);
    }

    // ============ View Function Tests ============

    function test_GetPendingExecutions() public {
        // Create 3 executions
        vm.startPrank(address(governor));
        executor.receiveExecution(keccak256("test1"), 0);
        executor.receiveExecution(keccak256("test2"), 0);
        executor.receiveExecution(keccak256("test3"), 0);
        vm.stopPrank();

        KaraExecutor.Execution[] memory pending = executor.getPendingExecutions();
        assertEq(pending.length, 3);
    }

    function test_GetPendingExecutionIds() public {
        vm.startPrank(address(governor));
        executor.receiveExecution(keccak256("test1"), 0);
        executor.receiveExecution(keccak256("test2"), 0);
        vm.stopPrank();

        // Complete one
        vm.prank(executor1);
        executor.claimExecution(1);
        vm.prank(executor1);
        executor.confirmExecution(1, true, "");

        uint256[] memory pendingIds = executor.getPendingExecutionIds();
        assertEq(pendingIds.length, 1);
        assertEq(pendingIds[0], 2);
    }

    function test_GetExecutionByPrompt() public {
        bytes32 promptHash = keccak256("test");

        vm.prank(address(governor));
        executor.receiveExecution(promptHash, 0);

        assertEq(executor.getExecutionByPrompt(promptHash), 1);
    }

    function test_ShouldTriggerCircuitBreaker() public view {
        assertFalse(executor.shouldTriggerCircuitBreaker());
    }
}
