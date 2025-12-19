// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IyPUSD.sol";
import "./ReferralRewardManagerStorage.sol";

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
    UUPSUpgradeable,
    ReferralRewardManagerStorage
{
    /* ========== Constructor and Initialization ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param admin Admin address
     * @param _ypusdToken yPUSD token address
     */
    function initialize(address admin, address _ypusdToken) public initializer {
        require(admin != address(0), "Invalid admin address");
        require(_ypusdToken != address(0), "Invalid yPUSD address");

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
        ypusdToken = IyPUSD(_ypusdToken);

        // Initialize configuration
        minClaimAmount = 1 * 10 ** 6; // 1 yPUSD
        maxRewardPerUser = 10000 * 10 ** 6; // 10000 yPUSD
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
        require(referralCount[_referrer] < maxReferralsPerUser, "Referrer has reached max referrals");

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
     * @param recordIds Array of unique record IDs for each reward (from backend log)
     * @param users Array of user addresses
     * @param amounts Array of reward amounts
     */
    function batchAddRewards(bytes32[] calldata recordIds, address[] calldata users, uint256[] calldata amounts)
        external
        onlyRole(REWARD_MANAGER_ROLE)
    {
        require(recordIds.length == users.length, "Array length mismatch");
        require(users.length == amounts.length, "Array length mismatch");
        require(users.length > 0, "Empty arrays");

        for (uint256 i = 0; i < users.length; i++) {
            require(!processedRecords[recordIds[i]], "Record already processed");
            processedRecords[recordIds[i]] = true;
            _addReward(recordIds[i], users[i], amounts[i]);
        }
    }

    /**
     * @notice Add reward for single user (internal function)
     * @param recordId Unique record ID for this reward
     * @param user User address
     * @param amount Reward amount
     */
    function _addReward(bytes32 recordId, address user, uint256 amount) internal {
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Invalid amount");

        uint256 newTotal = pendingRewards[user] + amount;
        require(newTotal <= maxRewardPerUser, "Exceeds max reward per user");

        pendingRewards[user] = newTotal;
        totalPendingRewards += amount;

        emit RewardAdded(recordId, user, amount, msg.sender);
    }

    /**
     * @notice Batch reduce rewards
     * @param recordIds Array of unique record IDs for each reduction
     * @param users Array of user addresses
     * @param amounts Array of amounts to reduce
     */
    function batchReduceRewards(bytes32[] calldata recordIds, address[] calldata users, uint256[] calldata amounts)
        external
        onlyRole(REWARD_MANAGER_ROLE)
    {
        require(recordIds.length == users.length, "Array length mismatch");
        require(users.length == amounts.length, "Array length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            _reduceReward(recordIds[i], users[i], amounts[i]);
        }
    }

    /**
     * @notice Reduce reward for single user (internal function)
     */
    function _reduceReward(bytes32 recordId, address user, uint256 amount) internal {
        require(!processedRecords[recordId], "Record already processed");
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Invalid amount");
        require(pendingRewards[user] >= amount, "Insufficient pending rewards");

        processedRecords[recordId] = true;
        pendingRewards[user] -= amount;
        totalPendingRewards -= amount;

        emit RewardReduced(recordId, user, amount, msg.sender);
    }

    /**
     * @notice Batch set rewards
     * @param recordIds Array of unique record IDs for each set operation
     * @param users Array of user addresses
     * @param amounts Array of reward amounts
     */
    function batchSetRewards(bytes32[] calldata recordIds, address[] calldata users, uint256[] calldata amounts)
        external
        onlyRole(REWARD_MANAGER_ROLE)
    {
        require(recordIds.length == users.length, "Array length mismatch");
        require(users.length == amounts.length, "Array length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            _setReward(recordIds[i], users[i], amounts[i]);
        }
    }

    /**
     * @notice Set reward for single user (internal function)
     */
    function _setReward(bytes32 recordId, address user, uint256 amount) internal {
        require(!processedRecords[recordId], "Record already processed");
        require(user != address(0), "Invalid user address");
        require(amount <= maxRewardPerUser, "Exceeds max reward per user");

        processedRecords[recordId] = true;

        uint256 oldAmount = pendingRewards[user];

        // Update total pending rewards
        if (amount > oldAmount) {
            totalPendingRewards += (amount - oldAmount);
        } else {
            totalPendingRewards -= (oldAmount - amount);
        }

        pendingRewards[user] = amount;

        emit RewardSet(recordId, user, oldAmount, amount);
    }

    /**
     * @notice Batch clear rewards
     * @param recordIds Array of unique record IDs for each clear operation
     * @param users Array of user addresses
     */
    function batchClearRewards(bytes32[] calldata recordIds, address[] calldata users) external onlyRole(REWARD_MANAGER_ROLE) {
        require(recordIds.length == users.length, "Array length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            _clearReward(recordIds[i], users[i]);
        }
    }

    /**
     * @notice Clear reward for single user (internal function)
     */
    function _clearReward(bytes32 recordId, address user) internal {
        require(!processedRecords[recordId], "Record already processed");
        require(user != address(0), "Invalid user address");

        processedRecords[recordId] = true;

        uint256 amount = pendingRewards[user];
        if (amount > 0) {
            pendingRewards[user] = 0;
            totalPendingRewards -= amount;

            emit RewardCleared(recordId, user, amount);
        }
    }

    /* ========== User Operations ========== */

    /**
     * @notice User claims referral rewards
     * @dev Transfer yPUSD from contract itself to user (not minting)
     */
    function claimReward() external nonReentrant whenNotPaused {
        uint256 pending = pendingRewards[msg.sender];
        require(pending >= minClaimAmount, "Below minimum claim amount");

        // Check contract balance
        uint256 contractBalance = ypusdToken.balanceOf(address(this));
        require(contractBalance >= pending, "Insufficient balance in contract. Please contact admin.");

        // Clear pending rewards
        pendingRewards[msg.sender] = 0;
        totalPendingRewards -= pending;

        // Update claimed statistics
        totalClaimedRewards[msg.sender] += pending;
        totalClaimedRewardsGlobal += pending;

        // Transfer from this contract
        require(ypusdToken.transfer(msg.sender, pending), "yPUSD transfer failed.");

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

        // Anyone can transfer yPUSD to this contract
        require(ypusdToken.transferFrom(msg.sender, address(this), amount), "yPUSD transfer failed");

        emit RewardPoolFunded(msg.sender, amount);
    }

    /**
     * @notice Withdraw excess funds (only admin, for emergency)
     * @param amount Amount to withdraw
     */
    function withdrawFunds(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "Invalid amount");

        uint256 contractBalance = ypusdToken.balanceOf(address(this));
        require(contractBalance >= amount, "Insufficient balance");

        require(ypusdToken.transfer(msg.sender, amount), "yPUSD transfer failed");
    }

    /* ========== Configuration Management ========== */

    /**
     * @notice Update system configuration
     * @param _minClaimAmount Minimum claim amount
     * @param _maxRewardPerUser Maximum reward per user
     * @param _maxReferralsPerUser Maximum referrals per referrer
     */
    function updateConfig(uint256 _minClaimAmount, uint256 _maxRewardPerUser, uint256 _maxReferralsPerUser)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_minClaimAmount > 0, "Invalid min claim amount");
        require(_maxRewardPerUser >= _minClaimAmount, "Invalid max reward");
        require(_maxReferralsPerUser > 0 && _maxReferralsPerUser <= type(uint16).max, "Invalid max referrals");

        minClaimAmount = _minClaimAmount;
        maxRewardPerUser = _maxRewardPerUser;
        maxReferralsPerUser = uint16(_maxReferralsPerUser);

        emit ConfigUpdated(_minClaimAmount, _maxRewardPerUser, _maxReferralsPerUser);
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
    function getUserReferralInfo(address user)
        external
        view
        returns (address _referrer, uint256 _referralCount, uint256 _pendingReward, uint256 _totalClaimed)
    {
        return (referrer[user], referralCount[user], pendingRewards[user], totalClaimedRewards[user]);
    }

    /**
     * @notice Get all referrals of a referrer
     * @param _referrer Referrer address
     * @return Array of referred user addresses
     */
    function getReferrals(address _referrer) external view returns (address[] memory) {
        return referrals[_referrer];
    }

    /**
     * @notice Get reward pool status
     * @return poolAddress Contract address (reward pool is the contract itself)
     * @return balance Contract yPUSD balance
     * @return totalPending Total pending rewards in system
     * @return totalClaimed Total claimed rewards in system
     */
    function getRewardPoolStatus()
        external
        view
        returns (address poolAddress, uint256 balance, uint256 totalPending, uint256 totalClaimed)
    {
        return (address(this), ypusdToken.balanceOf(address(this)), totalPendingRewards, totalClaimedRewardsGlobal);
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
        returns (uint256 _totalUsers, uint256 _totalReferrers, uint256 _totalPending, uint256 _totalClaimed)
    {
        return (totalUsers, totalReferrers, totalPendingRewards, totalClaimedRewardsGlobal);
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
        returns (uint256 _minClaimAmount, uint256 _maxRewardPerUser, uint256 _maxReferralsPerUser)
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
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Only DEFAULT_ADMIN_ROLE can upgrade
    }
}
