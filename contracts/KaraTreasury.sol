// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./Interfaces.sol";

/**
 * @title KaraTreasury
 * @notice Staking, rewards distribution, and treasury management
 * @dev 30% to stakers, 20% to AI500 buybacks, 50% to treasury
 */
contract KaraTreasury is Ownable, ReentrancyGuard, Pausable {
    // ============ State Variables ============

    IKaraToken public karaToken;
    IKaraGovernor public governor;
    IKaraSafety public safety;

    // Staker info
    struct StakerInfo {
        uint256 stakedAmount;
        uint256 lockEndTime;
        uint256 lastClaimTime;
        uint256 pendingRewards;
        uint256 timeMultiplier;
        uint256 totalClaimed;
    }

    mapping(address => StakerInfo) public stakers;
    uint256 public totalStaked;
    uint256 public totalStakers;

    // Reward distribution percentages (in basis points)
    uint256 public constant STAKERS_SHARE = 3000; // 30%
    uint256 public constant AI500_SHARE = 2000; // 20%
    uint256 public constant TREASURY_SHARE = 5000; // 50%
    uint256 public constant BASIS_POINTS = 10000;

    // Time multiplier tiers (lock periods)
    uint256 public constant NO_LOCK_MULTIPLIER = 100; // 1.0x
    uint256 public constant ONE_YEAR_MULTIPLIER = 150; // 1.5x
    uint256 public constant TWO_YEAR_MULTIPLIER = 200; // 2.0x
    uint256 public constant FOUR_YEAR_MULTIPLIER = 300; // 3.0x

    uint256 public constant ONE_YEAR = 365 days;
    uint256 public constant TWO_YEARS = 730 days;
    uint256 public constant FOUR_YEARS = 1460 days;

    // Treasury funds
    uint256 public treasuryBalance;
    uint256 public ai500Reserve;
    uint256 public totalFeesReceived;
    uint256 public totalRewardsDistributed;

    // Bounty system
    struct Bounty {
        address creator;
        uint256 amount;
        string description;
        bool active;
        address claimedBy;
        uint256 claimedAt;
    }

    mapping(uint256 => Bounty) public bounties;
    uint256 public bountyCount;

    // Reward rate tracking
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;
    uint256 public rewardRate; // rewards per second per token

    // ============ Events ============

    event Staked(address indexed staker, uint256 amount, uint256 lockEndTime, uint256 multiplier);
    event Unstaked(address indexed staker, uint256 amount);
    event RewardsClaimed(address indexed staker, uint256 amount);
    event FeesDistributed(uint256 totalFees, uint256 stakersAmount, uint256 ai500Amount, uint256 treasuryAmount);
    event BountyCreated(uint256 indexed bountyId, address indexed creator, uint256 amount, string description);
    event BountyClaimed(uint256 indexed bountyId, address indexed claimer);
    event EmergencyWithdrawal(address indexed to, uint256 amount, string reason);
    event RewardRateUpdated(uint256 newRate);

    // ============ Modifiers ============

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            stakers[account].pendingRewards = earned(account);
        }
        _;
    }

    // ============ Constructor ============

    constructor(address _karaToken, address _governor, address _safety) Ownable(msg.sender) {
        require(_karaToken != address(0), "KaraTreasury: Invalid token");

        karaToken = IKaraToken(_karaToken);
        if (_governor != address(0)) governor = IKaraGovernor(_governor);
        if (_safety != address(0)) safety = IKaraSafety(_safety);

        lastUpdateTime = block.timestamp;
    }

    // ============ Staking Functions ============

    /**
     * @notice Stake KARA tokens without lock
     * @param amount Amount to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount >= 1000 * 10 ** 18, "KaraTreasury: Minimum 1K KARA");
        require(karaToken.transferFrom(msg.sender, address(this), amount), "KaraTreasury: Transfer failed");

        if (stakers[msg.sender].stakedAmount == 0) {
            totalStakers++;
        }

        stakers[msg.sender].stakedAmount += amount;
        stakers[msg.sender].timeMultiplier = NO_LOCK_MULTIPLIER;
        stakers[msg.sender].lockEndTime = 0;
        totalStaked += amount;

        // Update governor with staker info
        _updateGovernorStakerInfo(msg.sender);

        emit Staked(msg.sender, amount, 0, NO_LOCK_MULTIPLIER);
    }

    /**
     * @notice Stake KARA with time lock for multiplier
     * @param amount Amount to stake
     * @param lockDuration Lock period (1, 2, or 4 years)
     */
    function stakeWithLock(uint256 amount, uint256 lockDuration)
        external
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        require(amount >= 1000 * 10 ** 18, "KaraTreasury: Minimum 1K KARA");
        require(
            lockDuration == ONE_YEAR || lockDuration == TWO_YEARS || lockDuration == FOUR_YEARS,
            "KaraTreasury: Invalid lock duration"
        );

        require(karaToken.transferFrom(msg.sender, address(this), amount), "KaraTreasury: Transfer failed");

        if (stakers[msg.sender].stakedAmount == 0) {
            totalStakers++;
        }

        uint256 multiplier;
        if (lockDuration == ONE_YEAR) {
            multiplier = ONE_YEAR_MULTIPLIER;
        } else if (lockDuration == TWO_YEARS) {
            multiplier = TWO_YEAR_MULTIPLIER;
        } else {
            multiplier = FOUR_YEAR_MULTIPLIER;
        }

        uint256 lockEndTime = block.timestamp + lockDuration;

        stakers[msg.sender].stakedAmount += amount;
        stakers[msg.sender].lockEndTime = lockEndTime;
        stakers[msg.sender].timeMultiplier = multiplier;
        totalStaked += amount;

        _updateGovernorStakerInfo(msg.sender);

        emit Staked(msg.sender, amount, lockEndTime, multiplier);
    }

    /**
     * @notice Unstake KARA tokens
     * @param amount Amount to unstake (0 for all)
     */
    function unstake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        StakerInfo storage staker = stakers[msg.sender];
        require(staker.stakedAmount > 0, "KaraTreasury: No stake");

        uint256 unstakeAmount = amount == 0 ? staker.stakedAmount : amount;
        require(unstakeAmount <= staker.stakedAmount, "KaraTreasury: Insufficient stake");

        // Check lock
        if (staker.lockEndTime > 0) {
            require(block.timestamp >= staker.lockEndTime, "KaraTreasury: Still locked");
        }

        // Claim pending rewards first
        if (staker.pendingRewards > 0) {
            _claimRewards(msg.sender);
        }

        staker.stakedAmount -= unstakeAmount;
        totalStaked -= unstakeAmount;

        if (staker.stakedAmount == 0) {
            totalStakers--;
            staker.timeMultiplier = 0;
            staker.lockEndTime = 0;
        }

        _updateGovernorStakerInfo(msg.sender);

        require(karaToken.transfer(msg.sender, unstakeAmount), "KaraTreasury: Transfer failed");

        emit Unstaked(msg.sender, unstakeAmount);
    }

    /**
     * @notice Claim staking rewards
     */
    function claimRewards() external nonReentrant updateReward(msg.sender) {
        _claimRewards(msg.sender);
    }

    /**
     * @notice Internal claim rewards function
     */
    function _claimRewards(address staker) internal {
        uint256 rewards = stakers[staker].pendingRewards;
        require(rewards > 0, "KaraTreasury: No rewards");

        stakers[staker].pendingRewards = 0;
        stakers[staker].lastClaimTime = block.timestamp;
        stakers[staker].totalClaimed += rewards;
        totalRewardsDistributed += rewards;

        require(karaToken.transfer(staker, rewards), "KaraTreasury: Reward transfer failed");

        emit RewardsClaimed(staker, rewards);
    }

    // ============ Fee Distribution ============

    /**
     * @notice Distribute incoming fees according to allocation
     * @param amount Total fees to distribute
     */
    function distributeFees(uint256 amount) external nonReentrant {
        require(amount > 0, "KaraTreasury: No fees");
        require(karaToken.transferFrom(msg.sender, address(this), amount), "KaraTreasury: Transfer failed");

        totalFeesReceived += amount;

        uint256 stakersAmount = (amount * STAKERS_SHARE) / BASIS_POINTS;
        uint256 ai500Amount = (amount * AI500_SHARE) / BASIS_POINTS;
        uint256 treasuryAmount = amount - stakersAmount - ai500Amount;

        // Add to staker rewards
        if (totalStaked > 0) {
            rewardRate += (stakersAmount * 1e18) / totalStaked / 1 days; // Normalize to daily rate
        } else {
            // If no stakers, add to treasury
            treasuryAmount += stakersAmount;
        }

        // Add to AI500 reserve
        ai500Reserve += ai500Amount;

        // Add to treasury
        treasuryBalance += treasuryAmount;

        emit FeesDistributed(amount, stakersAmount, ai500Amount, treasuryAmount);
    }

    /**
     * @notice Deposit bounty for agent rewards
     * @param amount Amount to deposit as bounty
     */
    function depositBounty(uint256 amount) external nonReentrant {
        require(amount > 0, "KaraTreasury: Invalid amount");
        require(karaToken.transferFrom(msg.sender, address(this), amount), "KaraTreasury: Transfer failed");

        treasuryBalance += amount;
    }

    /**
     * @notice Create a bounty for specific tasks
     * @param amount Bounty amount
     * @param description Description of the task
     * @return bountyId The ID of the created bounty
     */
    function createBounty(uint256 amount, string calldata description) external nonReentrant returns (uint256) {
        require(amount > 0, "KaraTreasury: Invalid amount");
        require(bytes(description).length > 0, "KaraTreasury: Empty description");
        require(karaToken.transferFrom(msg.sender, address(this), amount), "KaraTreasury: Transfer failed");

        bountyCount++;
        bounties[bountyCount] = Bounty({
            creator: msg.sender,
            amount: amount,
            description: description,
            active: true,
            claimedBy: address(0),
            claimedAt: 0
        });

        emit BountyCreated(bountyCount, msg.sender, amount, description);

        return bountyCount;
    }

    /**
     * @notice Claim a bounty (called by governor for winning agents)
     * @param bountyId Bounty to claim
     * @param claimer Address to receive the bounty
     */
    function claimBounty(uint256 bountyId, address claimer) external nonReentrant {
        require(msg.sender == address(governor) || msg.sender == owner(), "KaraTreasury: Unauthorized");
        require(claimer != address(0), "KaraTreasury: Invalid claimer");

        Bounty storage bounty = bounties[bountyId];
        require(bounty.active, "KaraTreasury: Bounty not active");
        require(bounty.claimedBy == address(0), "KaraTreasury: Already claimed");

        bounty.active = false;
        bounty.claimedBy = claimer;
        bounty.claimedAt = block.timestamp;

        require(karaToken.transfer(claimer, bounty.amount), "KaraTreasury: Transfer failed");

        emit BountyClaimed(bountyId, claimer);
    }

    // ============ Emergency & Admin ============

    /**
     * @notice Emergency withdrawal (only safety contract or owner)
     * @param to Address to send to
     * @param amount Amount to withdraw
     * @param reason Reason for withdrawal
     */
    function emergencyWithdraw(address to, uint256 amount, string calldata reason) external nonReentrant {
        require(msg.sender == address(safety) || msg.sender == owner(), "KaraTreasury: Unauthorized");
        require(to != address(0), "KaraTreasury: Invalid address");
        require(amount <= treasuryBalance, "KaraTreasury: Insufficient treasury");

        treasuryBalance -= amount;

        require(karaToken.transfer(to, amount), "KaraTreasury: Transfer failed");

        emit EmergencyWithdrawal(to, amount, reason);
    }

    /**
     * @notice Execute AI500 buyback
     * @param amount Amount to use for buyback
     */
    function executeAI500Buyback(uint256 amount) external onlyOwner {
        require(amount <= ai500Reserve, "KaraTreasury: Insufficient reserve");
        ai500Reserve -= amount;

        // In production, this would swap KARA for AI500 index tokens
        // For now, just transfer to a designated buyback address
        // Implementation depends on DEX integration
    }

    /**
     * @notice Pause staking (emergency)
     */
    function pause() external {
        require(msg.sender == address(safety) || msg.sender == owner(), "KaraTreasury: Unauthorized");
        _pause();
    }

    /**
     * @notice Unpause staking
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Update contract references
     */
    function updateContracts(address _governor, address _safety) external onlyOwner {
        if (_governor != address(0)) governor = IKaraGovernor(_governor);
        if (_safety != address(0)) safety = IKaraSafety(_safety);
    }

    // ============ View Functions ============

    /**
     * @notice Calculate reward per token
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + ((rewardRate * (block.timestamp - lastUpdateTime) * 1e18) / totalStaked);
    }

    /**
     * @notice Calculate earned rewards for an account
     */
    function earned(address account) public view returns (uint256) {
        StakerInfo storage staker = stakers[account];
        uint256 baseEarned =
            staker.pendingRewards + ((staker.stakedAmount * (rewardPerToken() - rewardPerTokenStored)) / 1e18);
        // Apply time multiplier
        return (baseEarned * staker.timeMultiplier) / 100;
    }

    /**
     * @notice Get staker info
     */
    function getStakerInfo(address staker) external view returns (StakerInfo memory) {
        return stakers[staker];
    }

    /**
     * @notice Get APR estimate based on current reward rate
     */
    function getEstimatedAPR() external view returns (uint256) {
        if (totalStaked == 0) return 0;
        // Simplified APR calculation
        return (rewardRate * 365 days * 100) / 1e18;
    }

    /**
     * @notice Get total treasury stats
     */
    function getTreasuryStats()
        external
        view
        returns (
            uint256 _totalStaked,
            uint256 _totalStakers,
            uint256 _treasuryBalance,
            uint256 _ai500Reserve,
            uint256 _totalFeesReceived,
            uint256 _totalRewardsDistributed
        )
    {
        return (totalStaked, totalStakers, treasuryBalance, ai500Reserve, totalFeesReceived, totalRewardsDistributed);
    }

    // ============ Internal Functions ============

    /**
     * @notice Update governor with staker info for voting power calculation
     */
    function _updateGovernorStakerInfo(address staker) internal {
        if (address(governor) != address(0)) {
            StakerInfo memory info = stakers[staker];
            governor.updateStakerInfo(staker, info.stakedAmount, info.lockEndTime, info.timeMultiplier);
        }
    }
}
