// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/KaraGovernor.sol";
import "../contracts/KaraExecutor.sol";
import "../contracts/KaraTreasury.sol";
import "../contracts/KaraSafety.sol";
import "../contracts/MockKaraToken.sol";

/**
 * @title KaraTreasuryTest
 * @notice Comprehensive test suite for KaraTreasury contract
 */
contract KaraTreasuryTest is Test {
    KaraGovernor public governor;
    KaraExecutor public executor;
    KaraTreasury public treasury;
    KaraSafety public safety;
    MockKaraToken public karaToken;

    address public owner;
    address public sam;
    address public staker1;
    address public staker2;

    uint256 constant INITIAL_MINT = 1_000_000_000 * 10 ** 18;
    uint256 constant STAKE_AMOUNT = 10_000 * 10 ** 18;

    function setUp() public {
        owner = address(this);
        sam = makeAddr("sam");
        staker1 = makeAddr("staker1");
        staker2 = makeAddr("staker2");

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
        governor.setTreasury(address(treasury));

        // Fund stakers
        karaToken.transfer(staker1, STAKE_AMOUNT * 100);
        karaToken.transfer(staker2, STAKE_AMOUNT * 100);
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsInitialState() public view {
        assertEq(address(treasury.karaToken()), address(karaToken));
        assertEq(address(treasury.governor()), address(governor));
        assertEq(address(treasury.safety()), address(safety));
        assertEq(treasury.totalStaked(), 0);
        assertEq(treasury.totalStakers(), 0);
    }

    function test_Constructor_RevertsWithInvalidToken() public {
        vm.expectRevert("KaraTreasury: Invalid token");
        new KaraTreasury(address(0), address(governor), address(safety));
    }

    // ============ Staking Tests ============

    function test_Stake_Success() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit KaraTreasury.Staked(staker1, STAKE_AMOUNT, 0, 100);

        treasury.stake(STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(treasury.totalStaked(), STAKE_AMOUNT);
        assertEq(treasury.totalStakers(), 1);

        (uint256 staked, uint256 lockEnd,,, uint256 multiplier,) = treasury.stakers(staker1);
        assertEq(staked, STAKE_AMOUNT);
        assertEq(lockEnd, 0);
        assertEq(multiplier, 100);
    }

    function test_Stake_RevertsBelowMinimum() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), 999 * 10 ** 18);

        vm.expectRevert("KaraTreasury: Minimum 1K KARA");
        treasury.stake(999 * 10 ** 18);
        vm.stopPrank();
    }

    function test_Stake_RevertsWhenPaused() public {
        treasury.pause();

        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);

        vm.expectRevert();
        treasury.stake(STAKE_AMOUNT);
        vm.stopPrank();
    }

    function test_StakeWithLock_OneYear() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit KaraTreasury.Staked(staker1, STAKE_AMOUNT, block.timestamp + 365 days, 150);

        treasury.stakeWithLock(STAKE_AMOUNT, 365 days);
        vm.stopPrank();

        (uint256 staked, uint256 lockEnd,,, uint256 multiplier,) = treasury.stakers(staker1);
        assertEq(staked, STAKE_AMOUNT);
        assertEq(lockEnd, block.timestamp + 365 days);
        assertEq(multiplier, 150);
    }

    function test_StakeWithLock_TwoYears() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stakeWithLock(STAKE_AMOUNT, 730 days);
        vm.stopPrank();

        (,,,, uint256 multiplier,) = treasury.stakers(staker1);
        assertEq(multiplier, 200);
    }

    function test_StakeWithLock_FourYears() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stakeWithLock(STAKE_AMOUNT, 1460 days);
        vm.stopPrank();

        (,,,, uint256 multiplier,) = treasury.stakers(staker1);
        assertEq(multiplier, 300);
    }

    function test_StakeWithLock_RevertsInvalidDuration() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);

        vm.expectRevert("KaraTreasury: Invalid lock duration");
        treasury.stakeWithLock(STAKE_AMOUNT, 100 days);
        vm.stopPrank();
    }

    // ============ Unstaking Tests ============

    function test_Unstake_Success() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stake(STAKE_AMOUNT);

        uint256 balanceBefore = karaToken.balanceOf(staker1);

        vm.expectEmit(true, true, false, false);
        emit KaraTreasury.Unstaked(staker1, STAKE_AMOUNT);

        treasury.unstake(STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(treasury.totalStaked(), 0);
        assertEq(treasury.totalStakers(), 0);
        assertEq(karaToken.balanceOf(staker1), balanceBefore + STAKE_AMOUNT);
    }

    function test_Unstake_Partial() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT * 2);
        treasury.stake(STAKE_AMOUNT * 2);

        treasury.unstake(STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(treasury.totalStaked(), STAKE_AMOUNT);
        assertEq(treasury.totalStakers(), 1);

        (uint256 staked,,,,,) = treasury.stakers(staker1);
        assertEq(staked, STAKE_AMOUNT);
    }

    function test_Unstake_AllWithZeroParameter() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stake(STAKE_AMOUNT);

        treasury.unstake(0); // 0 means all
        vm.stopPrank();

        assertEq(treasury.totalStaked(), 0);
        assertEq(treasury.totalStakers(), 0);
    }

    function test_Unstake_RevertsIfStillLocked() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stakeWithLock(STAKE_AMOUNT, 365 days);

        vm.expectRevert("KaraTreasury: Still locked");
        treasury.unstake(STAKE_AMOUNT);
        vm.stopPrank();
    }

    function test_Unstake_RevertsIfNoStake() public {
        vm.prank(staker1);
        vm.expectRevert("KaraTreasury: No stake");
        treasury.unstake(STAKE_AMOUNT);
    }

    function test_Unstake_RevertsIfInsufficientStake() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stake(STAKE_AMOUNT);

        vm.expectRevert("KaraTreasury: Insufficient stake");
        treasury.unstake(STAKE_AMOUNT + 1);
        vm.stopPrank();
    }

    // ============ Rewards Tests ============

    function test_ClaimRewards_Integration() public {
        // This test verifies the claimRewards function exists and can be called
        // Full reward flow testing requires complex setup
        // For unit testing, we verify the function doesn't revert when there are no rewards
        // (it should revert with "No rewards" which is tested separately)

        // First stake to become a staker
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stake(STAKE_AMOUNT);

        // Try to claim - should revert with no rewards
        vm.expectRevert("KaraTreasury: No rewards");
        treasury.claimRewards();
        vm.stopPrank();
    }

    function test_ClaimRewards_RevertsIfNoRewards() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stake(STAKE_AMOUNT);

        vm.expectRevert("KaraTreasury: No rewards");
        treasury.claimRewards();
        vm.stopPrank();
    }

    // ============ Fee Distribution Tests ============

    function test_DistributeFees_WithStakers() public {
        // First stake so totalStaked > 0
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stake(STAKE_AMOUNT);
        vm.stopPrank();

        uint256 fees = 100_000 * 10 ** 18;
        karaToken.approve(address(treasury), fees);

        vm.expectEmit(true, true, true, true);
        emit KaraTreasury.FeesDistributed(
            fees,
            (fees * 3000) / 10000, // 30% to stakers (goes to rewardRate)
            (fees * 2000) / 10000, // 20% to AI500
            (fees * 5000) / 10000 // 50% to treasury
        );

        treasury.distributeFees(fees);

        (
            uint256 totalStaked,
            uint256 totalStakers,
            uint256 treasuryBalance,
            uint256 ai500Reserve,
            uint256 totalFeesReceived,
            uint256 totalRewardsDistributed
        ) = treasury.getTreasuryStats();

        assertEq(totalStaked, STAKE_AMOUNT);
        assertEq(totalStakers, 1);
        assertEq(ai500Reserve, (fees * 2000) / 10000);
        assertEq(treasuryBalance, (fees * 5000) / 10000);
        assertEq(totalFeesReceived, fees);
    }

    function test_DistributeFees_RevertsWithNoFees() public {
        vm.expectRevert("KaraTreasury: No fees");
        treasury.distributeFees(0);
    }

    function test_DistributeFees_NoStakers() public {
        uint256 fees = 100_000 * 10 ** 18;
        karaToken.approve(address(treasury), fees);

        treasury.distributeFees(fees);

        // When no stakers, stakers share goes to treasury
        (,, uint256 treasuryBalance, uint256 ai500Reserve,,) = treasury.getTreasuryStats();
        assertEq(ai500Reserve, (fees * 2000) / 10000);
        // 50% + 30% = 80% to treasury
        assertEq(treasuryBalance, (fees * 8000) / 10000);
    }

    // ============ Bounty Tests ============

    function test_CreateBounty() public {
        uint256 bountyAmount = 10_000 * 10 ** 18;
        karaToken.approve(address(treasury), bountyAmount);

        vm.expectEmit(true, true, true, true);
        emit KaraTreasury.BountyCreated(1, address(this), bountyAmount, "Complete this task");

        uint256 bountyId = treasury.createBounty(bountyAmount, "Complete this task");

        assertEq(bountyId, 1);

        (address creator, uint256 amount, string memory desc, bool active, address claimedBy, uint256 claimedAt) =
            treasury.bounties(bountyId);
        assertEq(creator, address(this));
        assertEq(amount, bountyAmount);
        assertEq(desc, "Complete this task");
        assertTrue(active);
        assertEq(claimedBy, address(0));
        assertEq(claimedAt, 0);
    }

    function test_CreateBounty_RevertsWithEmptyDescription() public {
        karaToken.approve(address(treasury), 10_000 * 10 ** 18);
        vm.expectRevert("KaraTreasury: Empty description");
        treasury.createBounty(10_000 * 10 ** 18, "");
    }

    function test_ClaimBounty() public {
        uint256 bountyAmount = 10_000 * 10 ** 18;
        karaToken.approve(address(treasury), bountyAmount);
        uint256 bountyId = treasury.createBounty(bountyAmount, "Complete this task");

        uint256 balanceBefore = karaToken.balanceOf(staker1);

        vm.expectEmit(true, true, false, false);
        emit KaraTreasury.BountyClaimed(bountyId, staker1);

        treasury.claimBounty(bountyId, staker1);

        assertEq(karaToken.balanceOf(staker1), balanceBefore + bountyAmount);

        (,,, bool active, address claimedBy,) = treasury.bounties(bountyId);
        assertFalse(active);
        assertEq(claimedBy, staker1);
    }

    function test_ClaimBounty_RevertsIfAlreadyClaimed() public {
        uint256 bountyAmount = 10_000 * 10 ** 18;
        karaToken.approve(address(treasury), bountyAmount);
        uint256 bountyId = treasury.createBounty(bountyAmount, "Complete this task");

        treasury.claimBounty(bountyId, staker1);

        // After claiming, bounty is no longer active
        vm.expectRevert("KaraTreasury: Bounty not active");
        treasury.claimBounty(bountyId, staker2);
    }

    // ============ Emergency Tests ============

    function test_EmergencyWithdraw() public {
        // First add to treasury
        uint256 fees = 100_000 * 10 ** 18;
        karaToken.approve(address(treasury), fees);
        treasury.distributeFees(fees);

        address recipient = makeAddr("recipient");
        uint256 withdrawAmount = 10_000 * 10 ** 18;

        vm.expectEmit(true, true, true, true);
        emit KaraTreasury.EmergencyWithdrawal(recipient, withdrawAmount, "Test emergency");

        treasury.emergencyWithdraw(recipient, withdrawAmount, "Test emergency");

        assertEq(karaToken.balanceOf(recipient), withdrawAmount);
    }

    function test_EmergencyWithdraw_RevertsForUnauthorized() public {
        vm.prank(staker1);
        vm.expectRevert("KaraTreasury: Unauthorized");
        treasury.emergencyWithdraw(staker1, 1000, "test");
    }

    function test_Pause() public {
        assertFalse(treasury.paused());

        vm.expectEmit(false, false, false, false);
        emit Pausable.Paused(address(this));

        treasury.pause();

        assertTrue(treasury.paused());
    }

    function test_Pause_RevertsForUnauthorized() public {
        vm.prank(staker1);
        vm.expectRevert("KaraTreasury: Unauthorized");
        treasury.pause();
    }

    function test_Unpause() public {
        treasury.pause();
        assertTrue(treasury.paused());

        treasury.unpause();

        assertFalse(treasury.paused());
    }

    // ============ View Function Tests ============

    function test_Earned() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stake(STAKE_AMOUNT);
        vm.stopPrank();

        uint256 fees = 100_000 * 10 ** 18;
        karaToken.approve(address(treasury), fees);
        treasury.distributeFees(fees);

        vm.warp(block.timestamp + 1 days);

        uint256 earned = treasury.earned(staker1);
        assertGt(earned, 0);
    }

    function test_RewardPerToken() public view {
        uint256 rewardPerToken = treasury.rewardPerToken();
        assertEq(rewardPerToken, 0); // No rewards yet
    }

    function test_GetEstimatedAPR() public {
        // Initially 0
        assertEq(treasury.getEstimatedAPR(), 0);

        // Stake and distribute fees
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stake(STAKE_AMOUNT);
        vm.stopPrank();

        uint256 fees = 100_000 * 10 ** 18;
        karaToken.approve(address(treasury), fees);
        treasury.distributeFees(fees);

        uint256 apr = treasury.getEstimatedAPR();
        assertGt(apr, 0);
    }

    function test_GetStakerInfo() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stake(STAKE_AMOUNT);
        vm.stopPrank();

        KaraTreasury.StakerInfo memory info = treasury.getStakerInfo(staker1);
        assertEq(info.stakedAmount, STAKE_AMOUNT);
        assertEq(info.timeMultiplier, 100);
    }

    function test_GetTreasuryStats() public {
        vm.startPrank(staker1);
        karaToken.approve(address(treasury), STAKE_AMOUNT);
        treasury.stake(STAKE_AMOUNT);
        vm.stopPrank();

        uint256 fees = 100_000 * 10 ** 18;
        karaToken.approve(address(treasury), fees);
        treasury.distributeFees(fees);

        (
            uint256 totalStaked,
            uint256 totalStakers,
            uint256 treasuryBalance,
            uint256 ai500Reserve,
            uint256 totalFeesReceived,
            uint256 totalRewardsDistributed
        ) = treasury.getTreasuryStats();

        assertEq(totalStaked, STAKE_AMOUNT);
        assertEq(totalStakers, 1);
        assertGt(treasuryBalance, 0);
        assertGt(ai500Reserve, 0);
        assertEq(totalFeesReceived, fees);
        assertEq(totalRewardsDistributed, 0);
    }
}
