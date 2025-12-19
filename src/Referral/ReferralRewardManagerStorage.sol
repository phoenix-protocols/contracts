// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IyPUSD.sol";

contract ReferralRewardManagerStorage {
    /* ========== Events ========== */

    event RewardAdded(bytes32 indexed recordId, address indexed user, uint256 amount, address manager);
    event RewardReduced(bytes32 indexed recordId, address indexed user, uint256 amount, address manager);
    event RewardSet(bytes32 indexed recordId, address indexed user, uint256 oldAmount, uint256 newAmount);
    event RewardCleared(bytes32 indexed recordId, address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event ReferrerSet(address indexed user, address indexed referrer);
    event RewardPoolFunded(address indexed funder, uint256 amount);
    event ConfigUpdated(uint256 minClaimAmount, uint256 maxRewardPerUser, uint256 maxReferralsPerUser);

    /* ========== Role Definitions ========== */

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE"); // Manage reward distribution
    bytes32 public constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE"); // Manage fund deposits

    /* ========== State Variables ========== */

    IyPUSD public ypusdToken; // yPUSD token contract

    // User reward data
    mapping(address => uint256) public pendingRewards; // Pending rewards
    mapping(address => uint256) public totalClaimedRewards; // Total claimed amount

    // Referral relationship data
    mapping(address => address) public referrer; // User => Referrer
    mapping(address => uint256) public referralCount; // Referrer => Number of referrals
    mapping(address => address[]) public referrals; // Referrer => List of referred users

    // Global statistics
    uint256 public totalPendingRewards; // Total pending rewards in system
    uint256 public totalClaimedRewardsGlobal; // Total claimed rewards in system
    uint256 public totalUsers; // Total number of users
    uint256 public totalReferrers; // Total number of referrers

    // Anti-abuse configuration
    uint256 public minClaimAmount; // Minimum claim amount (token amount)
    uint256 public maxRewardPerUser; // Maximum reward per user (token amount)
    uint16 public maxReferralsPerUser; // Maximum referrals per referrer (max 65535)

    // Idempotency: prevent duplicate records
    mapping(bytes32 => bool) public processedRecords; // recordId => processed

    /* ========== Upgrade Gap ========== */
    uint256[50] private __gap;
}
