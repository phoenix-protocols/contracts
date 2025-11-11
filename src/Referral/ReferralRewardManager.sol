// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IrPUSD {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
}

/**
 * @title ReferralRewardManager
 * @notice Independent management contract for referral reward system
 * @dev Manages user referral relationships and reward distribution
 *
 * Core Features:
 * 1. Referral relationship management (each user can only set referrer once)
 * 2. Reward pool fund management (independent reward pool address)
 * 3. Reward distribution (transfer from pool, not mint)
 * 4. Anti-abuse mechanism (minimum claim amount, per-user cap)
 */
contract ReferralRewardManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    /* ========== Role Definitions ========== */

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REWARD_MANAGER_ROLE =
        keccak256("REWARD_MANAGER_ROLE"); // Manage reward distribution
    bytes32 public constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE"); // Manage fund deposits

    /* ========== State Variables ========== */

    IrPUSD public rpusdToken; // rPUSD token contract

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

    /* ========== Upgrade Gap ========== */
    uint256[50] private __gap;

    /* ========== Events ========== */

    event RewardAdded(
        address indexed user,
        uint256 amount,
        address indexed manager
    );
    event RewardReduced(
        address indexed user,
        uint256 amount,
        address indexed manager
    );
    event RewardSet(address indexed user, uint256 oldAmount, uint256 newAmount);
    event RewardCleared(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event ReferrerSet(address indexed user, address indexed referrer);
    event RewardPoolFunded(address indexed funder, uint256 amount);
    event ConfigUpdated(
        uint256 minClaimAmount,
        uint256 maxRewardPerUser,
        uint256 maxReferralsPerUser
    );

    /* ========== Constructor and Initialization ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param admin Admin address
     * @param _rpusdToken rPUSD token address
     */
    function initialize(address admin, address _rpusdToken) public initializer {
        require(admin != address(0), "Invalid admin address");
        require(_rpusdToken != address(0), "Invalid rPUSD address");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(REWARD_MANAGER_ROLE, admin);
        _grantRole(FUND_MANAGER_ROLE, admin);

        // Set contract addresses
        rpusdToken = IrPUSD(_rpusdToken);

        // Initialize configuration
        minClaimAmount = 1 * 10 ** 6; // 1 rPUSD
        maxRewardPerUser = 10000 * 10 ** 6; // 10000 rPUSD
        maxReferralsPerUser = 1000; // Max 1000 referrals per user
    }

    /* ========== Referral Relationship Management ========== */

    /**
     * @notice Set referrer
     * @dev Users can only set referrer once and cannot refer themselves
     * @param _referrer Referrer address
     */
    function setReferrer(address _referrer) external whenNotPaused {
        require(_referrer != address(0), "Invalid referrer address");
        require(_referrer != msg.sender, "Cannot refer yourself");
        require(referrer[msg.sender] == address(0), "Referrer already set");
        require(
            referralCount[_referrer] < maxReferralsPerUser,
            "Referrer has reached max referrals"
        );

        // Set referral relationship
        referrer[msg.sender] = _referrer;
        referralCount[_referrer]++;
        referrals[_referrer].push(msg.sender);

        // Update statistics
        totalUsers++;
        if (referralCount[_referrer] == 1) {
            totalReferrers++;
        }

        emit ReferrerSet(msg.sender, _referrer);
    }

    /* ========== Reward Management (Admin Only) ========== */

    /**
     * @notice Batch add rewards
     * @param users Array of user addresses
     * @param amounts Array of reward amounts
     */
    function batchAddRewards(
        address[] calldata users,
        uint256[] calldata amounts
    ) external onlyRole(REWARD_MANAGER_ROLE) {
        require(users.length == amounts.length, "Array length mismatch");
        require(users.length > 0, "Empty arrays");

        for (uint256 i = 0; i < users.length; i++) {
            _addReward(users[i], amounts[i]);
        }
    }

    /**
     * @notice Add reward for single user (internal function)
     */
    function _addReward(address user, uint256 amount) internal {
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Invalid amount");

        uint256 newTotal = pendingRewards[user] + amount;
        require(newTotal <= maxRewardPerUser, "Exceeds max reward per user");

        pendingRewards[user] = newTotal;
        totalPendingRewards += amount;

        emit RewardAdded(user, amount, msg.sender);
    }

    /**
     * @notice Batch reduce rewards
     * @param users Array of user addresses
     * @param amounts Array of amounts to reduce
     */
    function batchReduceRewards(
        address[] calldata users,
        uint256[] calldata amounts
    ) external onlyRole(REWARD_MANAGER_ROLE) {
        require(users.length == amounts.length, "Array length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "Invalid user address");
            require(amounts[i] > 0, "Invalid amount");
            require(
                pendingRewards[users[i]] >= amounts[i],
                "Insufficient pending rewards"
            );

            pendingRewards[users[i]] -= amounts[i];
            totalPendingRewards -= amounts[i];

            emit RewardReduced(users[i], amounts[i], msg.sender);
        }
    }

    /**
     * @notice Batch set rewards
     * @param users Array of user addresses
     * @param amounts Array of reward amounts
     */
    function batchSetRewards(
        address[] calldata users,
        uint256[] calldata amounts
    ) external onlyRole(REWARD_MANAGER_ROLE) {
        require(users.length == amounts.length, "Array length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "Invalid user address");
            require(
                amounts[i] <= maxRewardPerUser,
                "Exceeds max reward per user"
            );

            uint256 oldAmount = pendingRewards[users[i]];

            // Update total pending rewards
            if (amounts[i] > oldAmount) {
                totalPendingRewards += (amounts[i] - oldAmount);
            } else {
                totalPendingRewards -= (oldAmount - amounts[i]);
            }

            pendingRewards[users[i]] = amounts[i];

            emit RewardSet(users[i], oldAmount, amounts[i]);
        }
    }

    /**
     * @notice Batch clear rewards
     * @param users Array of user addresses
     */
    function batchClearRewards(
        address[] calldata users
    ) external onlyRole(REWARD_MANAGER_ROLE) {
        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "Invalid user address");

            uint256 amount = pendingRewards[users[i]];
            if (amount > 0) {
                pendingRewards[users[i]] = 0;
                totalPendingRewards -= amount;

                emit RewardCleared(users[i], amount);
            }
        }
    }

    /* ========== User Operations ========== */

    /**
     * @notice User claims referral rewards
     * @dev Transfer rPUSD from contract itself to user (not minting)
     */
    function claimReward() external nonReentrant whenNotPaused {
        uint256 pending = pendingRewards[msg.sender];
        require(pending >= minClaimAmount, "Below minimum claim amount");

        // Check contract balance
        uint256 contractBalance = rpusdToken.balanceOf(address(this));
        require(
            contractBalance >= pending,
            "Insufficient balance in contract. Please contact admin."
        );

        // Clear pending rewards
        pendingRewards[msg.sender] = 0;
        totalPendingRewards -= pending;

        // Update claimed statistics
        totalClaimedRewards[msg.sender] += pending;
        totalClaimedRewardsGlobal += pending;

        // Transfer from this contract
        require(
            rpusdToken.transfer(msg.sender, pending),
            "rPUSD transfer failed."
        );

        emit RewardClaimed(msg.sender, pending);
    }

    /* ========== Fund Management ========== */

    /**
     * @notice Fund the reward pool (contract itself)
     * @param amount Amount to fund
     * @dev Anyone can fund the reward pool
     */
    function fundRewardPool(uint256 amount) external {
        require(amount > 0, "Invalid amount");

        // Anyone can transfer rPUSD to this contract
        require(
            rpusdToken.transferFrom(msg.sender, address(this), amount),
            "rPUSD transfer failed"
        );

        emit RewardPoolFunded(msg.sender, amount);
    }

    /**
     * @notice Withdraw excess funds (only admin, for emergency)
     * @param amount Amount to withdraw
     */
    function withdrawFunds(
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "Invalid amount");

        uint256 contractBalance = rpusdToken.balanceOf(address(this));
        require(contractBalance >= amount, "Insufficient balance");

        require(
            rpusdToken.transfer(msg.sender, amount),
            "rPUSD transfer failed"
        );
    }

    /* ========== Configuration Management ========== */

    /**
     * @notice Update system configuration
     * @param _minClaimAmount Minimum claim amount
     * @param _maxRewardPerUser Maximum reward per user
     * @param _maxReferralsPerUser Maximum referrals per referrer
     */
    function updateConfig(
        uint256 _minClaimAmount,
        uint256 _maxRewardPerUser,
        uint256 _maxReferralsPerUser
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_minClaimAmount > 0, "Invalid min claim amount");
        require(_maxRewardPerUser >= _minClaimAmount, "Invalid max reward");
        require(
            _maxReferralsPerUser > 0 &&
                _maxReferralsPerUser <= type(uint16).max,
            "Invalid max referrals"
        );

        minClaimAmount = _minClaimAmount;
        maxRewardPerUser = _maxRewardPerUser;
        maxReferralsPerUser = uint16(_maxReferralsPerUser);

        emit ConfigUpdated(
            _minClaimAmount,
            _maxRewardPerUser,
            _maxReferralsPerUser
        );
    }

    /* ========== Query Functions ========== */

    /**
     * @notice Get user referral information
     * @param user User address
     * @return _referrer Referrer address
     * @return _referralCount Number of referrals as a referrer
     * @return _pendingReward Pending rewards
     * @return _totalClaimed Total claimed amount
     */
    function getUserReferralInfo(
        address user
    )
        external
        view
        returns (
            address _referrer,
            uint256 _referralCount,
            uint256 _pendingReward,
            uint256 _totalClaimed
        )
    {
        return (
            referrer[user],
            referralCount[user],
            pendingRewards[user],
            totalClaimedRewards[user]
        );
    }

    /**
     * @notice Get all referrals of a referrer
     * @param _referrer Referrer address
     * @return Array of referred user addresses
     */
    function getReferrals(
        address _referrer
    ) external view returns (address[] memory) {
        return referrals[_referrer];
    }

    /**
     * @notice Get reward pool status
     * @return poolAddress Contract address (reward pool is the contract itself)
     * @return balance Contract rPUSD balance
     * @return totalPending Total pending rewards in system
     * @return totalClaimed Total claimed rewards in system
     */
    function getRewardPoolStatus()
        external
        view
        returns (
            address poolAddress,
            uint256 balance,
            uint256 totalPending,
            uint256 totalClaimed
        )
    {
        return (
            address(this),
            rpusdToken.balanceOf(address(this)),
            totalPendingRewards,
            totalClaimedRewardsGlobal
        );
    }

    /**
     * @notice Get system statistics
     * @return _totalUsers Total number of users
     * @return _totalReferrers Total number of referrers
     * @return _totalPending Total pending rewards
     * @return _totalClaimed Total claimed rewards
     */
    function getSystemStats()
        external
        view
        returns (
            uint256 _totalUsers,
            uint256 _totalReferrers,
            uint256 _totalPending,
            uint256 _totalClaimed
        )
    {
        return (
            totalUsers,
            totalReferrers,
            totalPendingRewards,
            totalClaimedRewardsGlobal
        );
    }

    /**
     * @notice Get configuration
     * @return _minClaimAmount Minimum claim amount
     * @return _maxRewardPerUser Maximum reward per user
     * @return _maxReferralsPerUser Maximum referrals per referrer
     */
    function getConfig()
        external
        view
        returns (
            uint256 _minClaimAmount,
            uint256 _maxRewardPerUser,
            uint256 _maxReferralsPerUser
        )
    {
        return (minClaimAmount, maxRewardPerUser, maxReferralsPerUser);
    }

    /* ========== Admin Functions ========== */

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Authorize upgrade
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Only DEFAULT_ADMIN_ROLE can upgrade
    }
}
