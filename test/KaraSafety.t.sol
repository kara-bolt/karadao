// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/KaraGovernor.sol";
import "../contracts/KaraExecutor.sol";
import "../contracts/KaraTreasury.sol";
import "../contracts/KaraSafety.sol";
import "../contracts/MockKaraToken.sol";

/**
 * @title KaraSafetyTest
 * @notice Comprehensive test suite for KaraSafety contract
 */
contract KaraSafetyTest is Test {
    KaraGovernor public governor;
    KaraExecutor public executor;
    KaraTreasury public treasury;
    KaraSafety public safety;
    MockKaraToken public karaToken;

    address public owner;
    address public sam;
    address public guardian;
    address public agent1;
    address public agent2;

    uint256 constant INITIAL_MINT = 1_000_000_000 * 10 ** 18;
    uint256 constant AGENT_STAKE = 50_000 * 10 ** 18;

    function setUp() public {
        owner = address(this);
        sam = makeAddr("sam");
        guardian = makeAddr("guardian");
        agent1 = makeAddr("agent1");
        agent2 = makeAddr("agent2");

        // Deploy mock token
        karaToken = new MockKaraToken("KARA Token", "KARA", 18);

        // Deploy safety first (with temp addresses)
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

        // Add guardian
        safety.addGuardian(guardian);

        // Fund agent
        karaToken.transfer(agent1, AGENT_STAKE * 10);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsInitialState() public view {
        assertEq(address(safety.governor()), address(governor));
        assertEq(address(safety.treasury()), address(treasury));
        assertEq(address(safety.executor()), address(executor));
        assertEq(address(safety.karaToken()), address(karaToken));
        assertEq(safety.sam(), sam);
    }

    function test_Constructor_SetsCircuitBreakers() public view {
        (uint256 infoThreshold, uint256 infoWindow, uint256 infoCooldown, bool infoAuto) = safety.circuitBreakers(0);
        assertEq(infoThreshold, 5);
        assertEq(infoWindow, 20);
        assertEq(infoCooldown, 1 hours);
        assertTrue(infoAuto);

        (uint256 actionThreshold, uint256 actionWindow, uint256 actionCooldown, bool actionAuto) =
            safety.circuitBreakers(1);
        assertEq(actionThreshold, 3);
        assertEq(actionWindow, 10);
        assertEq(actionCooldown, 1 hours);
        assertTrue(actionAuto);

        (uint256 criticalThreshold,, uint256 criticalCooldown, bool criticalAuto) = safety.circuitBreakers(3);
        assertEq(criticalThreshold, 1);
        assertEq(criticalCooldown, 24 hours);
        assertFalse(criticalAuto);
    }

    function test_Constructor_AllowsInvalidGovernor() public {
        // Governor can be set later via updateContracts
        KaraSafety s = new KaraSafety(address(0), address(treasury), address(executor), address(karaToken), sam);
        assertEq(s.sam(), sam);
    }

    function test_Constructor_RevertsWithInvalidSam() public {
        vm.expectRevert("KaraSafety: Invalid Sam address");
        new KaraSafety(address(governor), address(treasury), address(executor), address(karaToken), address(0));
    }

    // ============ Emergency Pause Tests ============

    function test_EmergencyPause_AsSam() public {
        vm.prank(sam);
        vm.expectEmit(true, true, true, false);
        emit KaraSafety.EmergencyPaused(0, sam, 0);

        safety.emergencyPause(0);

        assertTrue(safety.isPaused(0));
    }

    function test_EmergencyPause_AsOwner() public {
        vm.expectEmit(true, true, true, false);
        emit KaraSafety.EmergencyPaused(1, address(this), 0);

        safety.emergencyPause(1);

        assertTrue(safety.isPaused(1));
    }

    function test_EmergencyPause_RevertsForInvalidTier() public {
        vm.expectRevert("KaraSafety: Invalid tier");
        safety.emergencyPause(4);
    }

    function test_EmergencyPause_RevertsForUnauthorized() public {
        vm.prank(agent1);
        vm.expectRevert();
        safety.emergencyPause(0);
    }

    function test_EmergencyUnpause_AsSam() public {
        safety.emergencyPause(0);
        assertTrue(safety.isPaused(0));

        vm.prank(sam);
        vm.expectEmit(true, true, false, false);
        emit KaraSafety.EmergencyUnpaused(0, sam);

        safety.emergencyUnpause(0);

        assertFalse(safety.isPaused(0));
    }

    function test_EmergencyUnpause_AsOwner() public {
        safety.emergencyPause(0);

        vm.expectEmit(true, true, false, false);
        emit KaraSafety.EmergencyUnpaused(0, address(this));

        safety.emergencyUnpause(0);

        assertFalse(safety.isPaused(0));
    }

    // ============ Global Pause Tests ============

    function test_GlobalPause_AsSam() public {
        vm.prank(sam);
        vm.expectEmit(true, false, false, false);
        emit KaraSafety.GlobalPaused(sam);

        safety.globalPause();

        assertTrue(safety.globalPaused());
        assertTrue(safety.isPaused(0));
        assertTrue(safety.isPaused(1));
        assertTrue(safety.isPaused(2));
        assertTrue(safety.isPaused(3));
    }

    function test_GlobalPause_RevertsForNonSam() public {
        vm.prank(owner);
        vm.expectRevert("KaraSafety: Only Sam");
        safety.globalPause();
    }

    function test_GlobalUnpause_AsSam() public {
        vm.prank(sam);
        safety.globalPause();

        vm.prank(sam);
        vm.expectEmit(true, false, false, false);
        emit KaraSafety.GlobalUnpaused(sam);

        safety.globalUnpause();

        assertFalse(safety.globalPaused());
    }

    // ============ Circuit Breaker Tests ============

    function test_RecordFailure() public {
        vm.prank(guardian);
        vm.expectEmit(true, false, false, true);
        emit KaraSafety.FailureRecorded(0, 1);

        safety.recordFailure(0);

        (uint256 failures,,,) = safety.getCircuitBreakerStatus(0);
        assertEq(failures, 1);
    }

    function test_RecordFailure_AsSam() public {
        vm.prank(sam);
        safety.recordFailure(0);

        (uint256 failures,,,) = safety.getCircuitBreakerStatus(0);
        assertEq(failures, 1);
    }

    function test_RecordFailure_RevertsForUnauthorized() public {
        vm.prank(agent1);
        vm.expectRevert();
        safety.recordFailure(0);
    }

    function test_TriggerCircuitBreaker_Manual() public {
        vm.prank(guardian);
        safety.triggerCircuitBreaker(0, 2 hours);

        (,, uint256 pausedUntil, bool isActive) = safety.getCircuitBreakerStatus(0);
        assertGt(pausedUntil, block.timestamp);
        assertTrue(isActive);
        assertTrue(safety.isPaused(0));
    }

    function test_ResetFailureCount() public {
        vm.prank(guardian);
        safety.recordFailure(0);

        vm.prank(sam);
        safety.resetFailureCount(0);

        (uint256 failures,,,) = safety.getCircuitBreakerStatus(0);
        assertEq(failures, 0);
    }

    // ============ Slashing Tests ============

    function test_SlashAgent() public {
        string memory reason = "Malicious behavior";

        vm.prank(guardian);
        vm.expectEmit(true, true, true, true);
        emit KaraSafety.AgentSlashed(1, agent1, AGENT_STAKE, reason);

        uint256 slashId = safety.slashAgent(agent1, AGENT_STAKE, reason);

        assertEq(slashId, 1);
        assertEq(safety.slashCount(), 1);
        assertEq(safety.totalSlashed(), AGENT_STAKE);

        (address agent, uint256 amount, string memory slashReason, uint256 timestamp, bool appealed, bool overturned) =
            safety.slashRecords(slashId);
        assertEq(agent, agent1);
        assertEq(amount, AGENT_STAKE);
        assertEq(slashReason, reason);
        assertGt(timestamp, 0);
        assertFalse(appealed);
        assertFalse(overturned);
    }

    function test_SlashAgent_RevertsForInvalidAgent() public {
        vm.prank(guardian);
        vm.expectRevert("KaraSafety: Invalid agent");
        safety.slashAgent(address(0), AGENT_STAKE, "test");
    }

    function test_SlashAgent_RevertsWithEmptyReason() public {
        vm.prank(guardian);
        vm.expectRevert("KaraSafety: Empty reason");
        safety.slashAgent(agent1, AGENT_STAKE, "");
    }

    function test_AppealSlash() public {
        vm.prank(guardian);
        uint256 slashId = safety.slashAgent(agent1, AGENT_STAKE, "Malicious behavior");

        vm.expectEmit(true, false, false, true);
        emit KaraSafety.SlashAppealed(slashId, "I am innocent");

        safety.appealSlash(slashId, "I am innocent");

        (,,,, bool appealed,) = safety.slashRecords(slashId);
        assertTrue(appealed);
    }

    function test_AppealSlash_RevertsIfAlreadyAppealed() public {
        vm.prank(guardian);
        uint256 slashId = safety.slashAgent(agent1, AGENT_STAKE, "test");

        safety.appealSlash(slashId, "first");

        vm.expectRevert("KaraSafety: Already appealed");
        safety.appealSlash(slashId, "second");
    }

    function test_AppealSlash_RevertsAfterWindow() public {
        vm.prank(guardian);
        uint256 slashId = safety.slashAgent(agent1, AGENT_STAKE, "test");

        vm.warp(block.timestamp + 8 days);

        vm.expectRevert("KaraSafety: Appeal window closed");
        safety.appealSlash(slashId, "too late");
    }

    function test_OverturnSlash_AsSam() public {
        vm.prank(guardian);
        uint256 slashId = safety.slashAgent(agent1, AGENT_STAKE, "test");

        safety.appealSlash(slashId, "appeal");

        vm.prank(sam);
        vm.expectEmit(true, false, false, true);
        emit KaraSafety.SlashOverturned(slashId, "Evidence shows innocence");

        safety.overturnSlash(slashId, "Evidence shows innocence");

        (,,,,, bool overturned) = safety.slashRecords(slashId);
        assertTrue(overturned);
        assertEq(safety.totalSlashed(), 0);
    }

    function test_OverturnSlash_RevertsIfNotAppealed() public {
        vm.prank(guardian);
        uint256 slashId = safety.slashAgent(agent1, AGENT_STAKE, "test");

        vm.expectRevert("KaraSafety: Not appealed");
        safety.overturnSlash(slashId, "no appeal");
    }

    // ============ Veto Tests ============

    function test_VetoCritical_AsSam() public {
        uint256 proposalId = 123;
        string memory reason = "Critical security issue";

        vm.prank(sam);
        vm.expectEmit(true, true, true, true);
        emit KaraSafety.CriticalVetoed(proposalId, sam, reason);

        safety.vetoCritical(proposalId, reason);

        assertTrue(safety.isVetoed(proposalId));
        assertEq(safety.vetoReasons(proposalId), reason);
    }

    function test_VetoCritical_RevertsForNonSam() public {
        vm.prank(owner);
        vm.expectRevert("KaraSafety: Only Sam");
        safety.vetoCritical(1, "test");
    }

    function test_IsVetoed() public {
        assertFalse(safety.isVetoed(1));

        vm.prank(sam);
        safety.vetoCritical(1, "test");

        assertTrue(safety.isVetoed(1));
    }

    // ============ Guardian Tests ============

    function test_AddGuardian_AsSam() public {
        address newGuardian = makeAddr("newGuardian");

        vm.prank(sam);
        vm.expectEmit(true, false, false, false);
        emit KaraSafety.GuardianAdded(newGuardian);

        safety.addGuardian(newGuardian);

        assertTrue(safety.isGuardian(newGuardian));
    }

    function test_AddGuardian_AsOwner() public {
        address newGuardian = makeAddr("newGuardian");
        safety.addGuardian(newGuardian);

        assertTrue(safety.isGuardian(newGuardian));
    }

    function test_AddGuardian_RevertsForInvalidAddress() public {
        vm.expectRevert("KaraSafety: Invalid address");
        safety.addGuardian(address(0));
    }

    function test_RemoveGuardian() public {
        assertTrue(safety.isGuardian(guardian));

        vm.prank(sam);
        vm.expectEmit(true, false, false, false);
        emit KaraSafety.GuardianRemoved(guardian);

        safety.removeGuardian(guardian);

        assertFalse(safety.isGuardian(guardian));
    }

    // ============ Sam Tests ============

    function test_UpdateSam() public {
        address newSam = makeAddr("newSam");

        vm.prank(sam);
        vm.expectEmit(true, false, false, false);
        emit KaraSafety.SamUpdated(newSam);

        safety.updateSam(newSam);

        assertEq(safety.sam(), newSam);
    }

    function test_UpdateSam_RevertsForNonSam() public {
        vm.prank(owner);
        vm.expectRevert("KaraSafety: Only Sam");
        safety.updateSam(makeAddr("new"));
    }

    function test_UpdateSam_RevertsForInvalidAddress() public {
        vm.prank(sam);
        vm.expectRevert("KaraSafety: Invalid address");
        safety.updateSam(address(0));
    }

    // ============ Update Circuit Breaker Tests ============

    function test_UpdateCircuitBreaker() public {
        safety.updateCircuitBreaker(0, 10, 50, 2 hours, false);

        (uint256 threshold, uint256 window, uint256 cooldown, bool autoTrigger) = safety.circuitBreakers(0);
        assertEq(threshold, 10);
        assertEq(window, 50);
        assertEq(cooldown, 2 hours);
        assertFalse(autoTrigger);
    }

    function test_UpdateCircuitBreaker_RevertsForInvalidTier() public {
        vm.expectRevert("KaraSafety: Invalid tier");
        safety.updateCircuitBreaker(4, 10, 50, 2 hours, false);
    }

    // ============ Update Contracts Tests ============

    function test_UpdateContracts() public {
        address newGovernor = makeAddr("newGovernor");
        address newTreasury = makeAddr("newTreasury");
        address newExecutor = makeAddr("newExecutor");
        address newToken = makeAddr("newToken");

        safety.updateContracts(newGovernor, newTreasury, newExecutor, newToken);

        assertEq(address(safety.governor()), newGovernor);
        assertEq(address(safety.treasury()), newTreasury);
        assertEq(address(safety.executor()), newExecutor);
        assertEq(address(safety.karaToken()), newToken);
    }

    function test_UpdateContracts_Partial() public {
        address newGovernor = makeAddr("newGovernor");

        // Update only governor, pass 0 for others
        safety.updateContracts(newGovernor, address(0), address(0), address(0));

        assertEq(address(safety.governor()), newGovernor);
        // Others should remain unchanged
        assertEq(address(safety.treasury()), address(treasury));
    }

    // ============ Can Execute Tests ============

    function test_CanExecute_WhenNotPaused() public view {
        assertTrue(safety.canExecute(0));
        assertTrue(safety.canExecute(1));
        assertTrue(safety.canExecute(2));
        assertTrue(safety.canExecute(3));
    }

    function test_CanExecute_WhenTierPaused() public {
        safety.emergencyPause(0);

        assertFalse(safety.canExecute(0));
        assertTrue(safety.canExecute(1));
    }

    function test_CanExecute_WhenGlobalPaused() public {
        vm.prank(sam);
        safety.globalPause();

        assertFalse(safety.canExecute(0));
        assertFalse(safety.canExecute(1));
        assertFalse(safety.canExecute(2));
        assertFalse(safety.canExecute(3));
    }

    function test_CanExecute_WhenCircuitBreakerActive() public {
        vm.prank(guardian);
        safety.triggerCircuitBreaker(0, 1 hours);

        assertFalse(safety.canExecute(0));
        assertTrue(safety.canExecute(1));
    }
}
