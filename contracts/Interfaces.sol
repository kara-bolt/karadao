// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title I KaraToken
 * @notice Interface for the KARA token contract
 */
interface IKaraToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title I KaraGovernor
 * @notice Interface for the KaraGovernor contract
 */
interface IKaraGovernor {
    enum Tier {
        INFO,
        ACTION,
        FUNDS,
        CRITICAL
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

    struct TierConfig {
        uint256 votingPeriod;
        uint256 threshold; // in basis points (e.g., 5000 = 50%)
        uint256 minStake;
        bool active;
    }

    function submitProposal(bytes32 promptHash, Tier tier) external returns (uint256 proposalId);
    function castVote(uint256 proposalId, bool support) external;
    function executeWinningProposal(uint256 proposalId) external;
    function delegate(address agent) external;
    function registerAgent(string calldata metadataURI) external;
    function updateStakerInfo(address staker, uint256 amount, uint256 lockEndTime, uint256 timeMultiplier) external;
    function getVotingPower(address voter) external view returns (uint256);
    function getTierConfig(Tier tier) external view returns (TierConfig memory);

    event ProposalSubmitted(
        uint256 indexed proposalId, bytes32 indexed promptHash, Tier tier, address indexed proposer
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId, bytes32 promptHash);
    event DelegationChanged(address indexed delegator, address indexed fromAgent, address indexed toAgent);
    event AgentRegistered(address indexed agent, string metadataURI);
}

/**
 * @title I KaraExecutor
 * @notice Interface for the KaraExecutor contract
 */
interface IKaraExecutor {
    struct Execution {
        bytes32 promptHash;
        uint8 tier;
        uint256 timestamp;
        bool executed;
        bool success;
    }

    function receiveExecution(bytes32 promptHash, uint8 tier) external returns (uint256 executionId);
    function confirmExecution(uint256 executionId, bool success) external;
    function getPendingExecutions() external view returns (Execution[] memory);

    event ExecutionRequested(bytes32 indexed promptHash, uint8 tier, uint256 indexed executionId, uint256 timestamp);
    event ExecutionCompleted(uint256 indexed executionId, bool success);
}

/**
 * @title I KaraTreasury
 * @notice Interface for the KaraTreasury contract
 */
interface IKaraTreasury {
    function stakers(address staker)
        external
        view
        returns (
            uint256 stakedAmount,
            uint256 lockEndTime,
            uint256 lastClaimTime,
            uint256 pendingRewards,
            uint256 timeMultiplier,
            uint256 totalClaimed
        );

    struct StakerInfo {
        uint256 stakedAmount;
        uint256 lockEndTime;
        uint256 lastClaimTime;
        uint256 pendingRewards;
        uint256 timeMultiplier;
    }

    function stake(uint256 amount) external;
    function stakeWithLock(uint256 amount, uint256 lockDuration) external;
    function unstake(uint256 amount) external;
    function claimRewards() external;
    function distributeFees() external;
    function depositBounty(uint256 amount) external;
    function getStakerInfo(address staker) external view returns (StakerInfo memory);

    event Staked(address indexed staker, uint256 amount, uint256 lockEndTime);
    event Unstaked(address indexed staker, uint256 amount);
    event RewardsClaimed(address indexed staker, uint256 amount);
    event FeesDistributed(uint256 stakersAmount, uint256 ai500Amount, uint256 treasuryAmount);
    event BountyDeposited(address indexed depositor, uint256 amount);
}

/**
 * @title I KaraSafety
 * @notice Interface for the KaraSafety contract
 */
interface IKaraSafety {
    function emergencyPause(uint8 tier) external;
    function emergencyUnpause(uint8 tier) external;
    function slashAgent(address agent, uint256 amount) external;
    function vetoCritical(uint256 proposalId) external;
    function isPaused(uint8 tier) external view returns (bool);
    function canExecute(uint8 tier) external view returns (bool);

    event EmergencyPaused(uint8 tier, address indexed by);
    event EmergencyUnpaused(uint8 tier, address indexed by);
    event AgentSlashed(address indexed agent, uint256 amount, string reason);
    event CriticalVetoed(uint256 indexed proposalId, address indexed by);
}
