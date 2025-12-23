// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IPUSD.sol";
import "../interfaces/IyPUSD.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IMessageManager.sol";
import {IFarm} from "../interfaces/IFarm.sol";
import {FarmStorage} from "./FarmStorage.sol";
import {NFTManager} from "../token/NFTManager/NFTManager.sol";

/**
 * @title FarmUpgradeable
 * @notice Core Farm contract of Phoenix DeFi system
 * @dev Mining contract specially designed for PUSD/yPUSD ecosystem
 *
 * Core design philosophy:
 * - Only PUSD ↔ yPUSD can be directly exchanged
 * - Other assets → PUSD → yPUSD unidirectional flow
 * - yPUSD yield handled within its own contract; Farm no longer queries dynamic APY for post-expiry stakes
 * - Multi-asset support but unified management
 *
 * Main functions:
 * 1. Multi-asset deposits (USDT/USDC → PUSD)
 * 2. PUSD ↔ yPUSD exchange
 * 3. Staking mining system
 * 4. Automatic yield reinvestment
 * 5. Flexible withdrawal mechanism
 */
contract FarmUpgradeable is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable, FarmStorage {
    using SafeERC20 for IERC20;

    /* ========== Constructor and Initialization ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize Farm contract
     * @param admin Administrator address
     * @param _pusdToken PUSD token contract address
     * @param _ypusdToken yPUSD token contract address
     * @param _vault Vault contract address
     */
    function initialize(address admin, address _pusdToken, address _ypusdToken, address _vault) public initializer {
        require(admin != address(0), "Invalid admin");
        require(_pusdToken != address(0), "Invalid PUSD");
        require(_ypusdToken != address(0), "Invalid yPUSD");
        require(_vault != address(0), "Invalid vault");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BRIDGE_ROLE, admin); // Grant bridge management permissions
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin); // Grant operations management permissions (APY/fees/configuration)

        pusdToken = IPUSD(_pusdToken);
        ypusdToken = IyPUSD(_ypusdToken);
        vault = IVault(_vault);

        // Initialize staking mining system
        currentAPY = 2000; // Initial APY 20% (2000 basis points)

        // Initialize APY history
        apyHistory.push(APYRecord({apy: currentAPY, timestamp: block.timestamp}));
    }

    /* ========== Core Business Functions ========== */

    /**
     * @notice Deposit assets to get PUSD
     * @dev Support multiple asset deposits, automatically convert to PUSD
     * @param asset Asset address
     * @param amount Deposit amount
     */
    function depositAsset(address asset, uint256 amount) external nonReentrant whenNotPaused {
        require(vault.isValidAsset(asset), "Bad asset");
        // Here amount is asset quantity, not USD, need to convert to pusd amount
        (uint256 pusdAmount, uint256 referenceTimestamp) = vault.getTokenPUSDValue(asset, amount);
        require(pusdAmount > 0, "Invalid amount");
        require(block.timestamp - referenceTimestamp <= HEALTH_CHECK_TIMEOUT, "Stale oracle");

        require(pusdAmount >= minDepositAmount * (10 ** pusdToken.decimals()), "Amount below min");

        // Calculate fee (explicit uint256 cast to avoid potential optimizer issues)
        uint256 fee = (amount * uint256(depositFeeRate)) / 10000;
        uint256 netPUSD = pusdAmount - (pusdAmount * uint256(depositFeeRate)) / 10000;

        // All assets deposited to Vault
        vault.depositFor(msg.sender, asset, amount);

        // Handle fees
        if (fee > 0) {
            vault.addFee(asset, fee);
        }

        // But mint netPUSD amount of PUSD to user
        pusdToken.mint(msg.sender, netPUSD);

        // Update user information
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        if (userInfo.totalDeposited == 0) {
            totalUsers++;
        }
        userInfo.totalDeposited += netPUSD;
        userInfo.lastActionTime = block.timestamp;

        // Update statistics
        assetTotalDeposits[asset] += amount;
        totalVolumeUSD += netPUSD;

        emit AssetOperation(msg.sender, asset, amount, netPUSD, true);
    }

    /**
     * @notice Withdraw assets
     * @dev PUSD exchanged to specified asset through Vault for withdrawal
     * @param asset Asset address to withdraw
     * @param pusdAmount PUSD amount to withdraw
     */
    function withdrawAsset(address asset, uint256 pusdAmount) external nonReentrant whenNotPaused {
        require(vault.isValidAsset(asset), "Bad asset");
        require(pusdAmount > 0, "Zero amount");

        // Check user PUSD balance
        require(pusdToken.balanceOf(msg.sender) >= pusdAmount, "Low PUSD");

        // Calculate required asset amount for withdrawal (reverse calculation through Oracle)
        (uint256 assetAmount, uint256 referenceTimestamp) = vault.getPUSDAssetValue(asset, pusdAmount);
        require(assetAmount > 0, "Invalid amount");
        require(block.timestamp - referenceTimestamp <= HEALTH_CHECK_TIMEOUT, "Stale oracle");

        // Check if Vault has sufficient asset balance
        (uint256 vaultBalance, ) = vault.getTVL(asset);
        require(vaultBalance >= assetAmount, "Low vault");

        UserAssetInfo storage userInfo = userAssets[msg.sender];

        // Calculate withdrawal fee (based on PUSD amount, explicit uint256 cast)
        uint256 pusdFee = (pusdAmount * uint256(withdrawFeeRate)) / 10000;
        (uint256 assetFee, uint256 feeReferenceTimestamp) = vault.getPUSDAssetValue(asset, pusdFee);
        require(block.timestamp - feeReferenceTimestamp <= HEALTH_CHECK_TIMEOUT, "Stale oracle");
        uint256 netAssetAmount = assetAmount - assetFee;

        // Burn user's PUSD
        pusdToken.burn(msg.sender, pusdAmount);

        // Withdraw assets from Vault to user
        vault.withdrawTo(msg.sender, asset, netAssetAmount);

        // Process fees
        if (assetFee > 0) {
            vault.addFee(asset, assetFee);
        }

        // Update user information
        userInfo.lastActionTime = block.timestamp;

        // Reduce user's total deposited amount (based on total PUSD consumed including fees)
        if (userInfo.totalDeposited >= pusdAmount) {
            userInfo.totalDeposited -= pusdAmount;
        } else {
            userInfo.totalDeposited = 0; // Prevent underflow
        }

        // Update statistics
        totalVolumeUSD += pusdAmount;

        emit AssetOperation(msg.sender, asset, netAssetAmount, assetFee, false);
    }

    /**
     * @notice Stake PUSD to earn mining rewards (DAO pool mode)
     * @dev Each stake recorded independently; rewards accrue ONLY during the lock period (no post-expiry yield)
     * @param amount Amount of PUSD to stake
     * @param lockPeriod Lock period (5-180 days)
     * @return tokenId Record ID for this stake
     */
    function stakePUSD(uint256 amount, uint256 lockPeriod) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        require(amount >= minLockAmount * (10 ** pusdToken.decimals()), "Too small");

        // Verify if lock period is supported
        require(lockPeriodMultipliers[lockPeriod] > 0, "Invalid period");

        // Check pool cap if set
        require(poolCap[lockPeriod] == 0 || poolTVL[lockPeriod] + amount <= poolCap[lockPeriod], "Pool full");

        // Check max stakes per user
        require(userAssets[msg.sender].tokenIds.length < maxStakesPerUser, "Max stakes reached");

        // Check user PUSD balance
        require(pusdToken.balanceOf(msg.sender) >= amount, "Low PUSD");

        // Check if user has authorized sufficient PUSD to Farm contract
        require(IERC20(address(pusdToken)).allowance(msg.sender, address(this)) >= amount, "Approve PUSD first");

        // Directly transfer PUSD from user address to Vault contract
        IERC20(address(pusdToken)).safeTransferFrom(msg.sender, address(vault), amount);

        // Set reward multiplier based on lock period
        uint16 multiplier = lockPeriodMultipliers[lockPeriod];

        // Record stake in NFT Manager contract
        NFTManager nftManager = NFTManager(_nftManager);
        tokenId = nftManager.mintStakeNFT(msg.sender, amount, uint64(lockPeriod), multiplier, 0);

        // Update total staked amount
        totalStaked += amount;

        // Update pool TVL
        poolTVL[lockPeriod] += amount;

        // Update user operation time
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        userInfo.lastActionTime = block.timestamp;
        userInfo.tokenIds.push(tokenId);

        emit StakeOperation(msg.sender, tokenId, amount, lockPeriod, true);
    }

    /**
     * @notice Renew stake
     * @dev After stake unlock, can choose new lock period to continue staking
     * @param tokenId Stake record ID (NFT tokenId)
     * @param compoundRewards Whether to compound rewards into stake
     */
    function renewStake(uint256 tokenId, bool compoundRewards, uint256 newLockPeriod) external nonReentrant whenNotPaused {
        NFTManager nftManager = NFTManager(_nftManager);
        require(nftManager.ownerOf(tokenId) == msg.sender, "Not owner");
        StakeRecord memory stakeRecord = nftManager.getStakeRecord(tokenId);

        require(stakeRecord.active, "Inactive stake");
        require(block.timestamp >= stakeRecord.startTime + stakeRecord.lockPeriod, "Still locked");
        // Verify if lock period is supported
        require(lockPeriodMultipliers[newLockPeriod] > 0, "Invalid period");

        // Call internal function directly to avoid code duplication
        _executeRenewal(tokenId, compoundRewards, newLockPeriod);
    }

    /**
     * @notice Internal function to execute renewal
     * @dev Core logic extracted from renewStake to avoid code duplication
     */
    function _executeRenewal(uint256 tokenId, bool compoundRewards, uint256 newLockPeriod) internal {
        NFTManager nftManager = NFTManager(_nftManager);
        StakeRecord memory stakeRecord = nftManager.getStakeRecord(tokenId);
        // Reset stake record for new lock period
        stakeRecord.startTime = block.timestamp;
        stakeRecord.lastClaimTime = block.timestamp;
        stakeRecord.lockPeriod = newLockPeriod;
        stakeRecord.rewardMultiplier = lockPeriodMultipliers[newLockPeriod];

        // Calculate rewards for this stake
        uint256 reward = _calculateStakeReward(stakeRecord);
        uint256 totalReward = reward + stakeRecord.pendingReward;

        if (totalReward > 0) {
            if (compoundRewards) {
                // Compounding mode: directly add rewards to stake principal (rewards in PUSD units)
                stakeRecord.amount += totalReward;
                stakeRecord.pendingReward = 0;
                emit StakeRenewal(msg.sender, tokenId, newLockPeriod, totalReward, stakeRecord.amount, true);
            } else {
                // Traditional mode: distribute PUSD rewards from reserve
                bool success = _distributeReward(msg.sender, totalReward);
                require(success, "Low reserve");
                stakeRecord.pendingReward = 0;

                emit StakeRewardsClaimed(msg.sender, tokenId, totalReward);
                emit StakeRenewal(msg.sender, tokenId, stakeRecord.lockPeriod, totalReward, stakeRecord.amount, false);
            }
        }

        // Update user operation time
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        userInfo.lastActionTime = block.timestamp;

        nftManager.updateStakeRecord(tokenId, stakeRecord);
    }

    /**
     * @notice Cancel PUSD stake (DAO pool mode)
     * @dev Cancel specific stake based on stake record ID
     * @param tokenId Stake record ID to cancel
     */
    function unstakePUSD(uint256 tokenId) external nonReentrant whenNotPaused {
        NFTManager nftManager = NFTManager(_nftManager);
        require(nftManager.ownerOf(tokenId) == msg.sender, "Not owner");

        StakeRecord memory stakeRecord = nftManager.getStakeRecord(tokenId);
        require(stakeRecord.active, "Inactive stake");
        require(block.timestamp >= stakeRecord.startTime + stakeRecord.lockPeriod, "Still locked");

        uint256 amount = stakeRecord.amount;

        // Calculate and distribute rewards for this stake
        uint256 reward = _calculateStakeReward(stakeRecord);
        uint256 totalReward = reward + stakeRecord.pendingReward;
        if (totalReward > 0) {
            // Distribute PUSD rewards from reserve
            bool success = _distributeReward(msg.sender, totalReward);
            require(success, "Low reserve");
            emit StakeRewardsClaimed(msg.sender, tokenId, totalReward);
        }

        // Mark stake record as inactive, preserve historical record
        stakeRecord.active = false;
        stakeRecord.amount = 0; // Mark as withdrawn

        // Update total staked amount
        if (totalStaked >= amount) {
            totalStaked -= amount;
        } else {
            totalStaked = 0;
        }
        // Update pool TVL
        if (poolTVL[stakeRecord.lockPeriod] >= amount) {
            poolTVL[stakeRecord.lockPeriod] -= amount;
        } else {
            poolTVL[stakeRecord.lockPeriod] = 0;
        }

        // Withdraw staked PUSD from Vault to user
        vault.withdrawPUSDTo(msg.sender, amount);

        nftManager.updateStakeRecord(tokenId, stakeRecord);
        // Burn stake NFT
        nftManager.burn(tokenId);

        // Update user operation time
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        userInfo.lastActionTime = block.timestamp;

        // Remove tokenId from user's tokenIds array
        _removeTokenIdFromUser(msg.sender, tokenId);

        emit StakeOperation(msg.sender, tokenId, amount, 0, false);
    }

    /**
     * @notice Claim rewards for specific stake record
     * @dev Rewards accrue only until unlock; claiming after unlock does not add extra yield
     * @param tokenId Stake record ID
     */
    function claimStakeRewards(uint256 tokenId) external nonReentrant whenNotPaused {
        NFTManager nftManager = NFTManager(_nftManager);
        require(nftManager.exists(tokenId), "Invaild tokenId");
        require(nftManager.ownerOf(tokenId) == msg.sender, "Not owner");

        StakeRecord memory stakeRecord = nftManager.getStakeRecord(tokenId);
        require(stakeRecord.active, "Inactive stake");

        // Calculate rewards (from last claim time to now)
        uint256 pendingReward = _calculateStakeReward(stakeRecord) + stakeRecord.pendingReward;
        require(pendingReward > 0, "No rewards");
        // Update last claim time
        stakeRecord.lastClaimTime = block.timestamp;
        stakeRecord.pendingReward = 0;

        nftManager.updateStakeRecord(tokenId, stakeRecord);

        // Distribute PUSD rewards from reserve
        bool success = _distributeReward(msg.sender, pendingReward);
        require(success, "Low reserve");

        emit StakeRewardsClaimed(msg.sender, tokenId, pendingReward);
    }

    /**
     * @notice Claim rewards for all active stakes at once
     * @dev Batch claim current available rewards for all user's active stake records
     * @return totalReward Total amount of rewards claimed
     */
    function claimAllStakeRewards() external nonReentrant whenNotPaused returns (uint256 totalReward) {
        uint256[] memory tokenIds = userAssets[msg.sender].tokenIds;
        require(tokenIds.length > 0, "No stakes");

        NFTManager nftManager = NFTManager(_nftManager);
        StakeRecord[] memory stakes = new StakeRecord[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            StakeRecord memory record = nftManager.getStakeRecord(tokenIds[i]);
            if (record.active) {
                stakes[i] = record;
            }
        }

        totalReward = 0;

        // Iterate through all stake records to claim rewards
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].active) {
                uint256 reward = _calculateStakeReward(stakes[i]) + stakes[i].pendingReward;
                if (reward > 0) {
                    // Update last claim time
                    stakes[i].lastClaimTime = block.timestamp;
                    totalReward += reward;
                    nftManager.updateStakeRecord(tokenIds[i], stakes[i]);

                    emit StakeRewardsClaimed(msg.sender, i, reward);
                }
            }
        }

        require(totalReward > 0, "No rewards");

        // Distribute PUSD rewards from reserve
        bool success = _distributeReward(msg.sender, totalReward);
        require(success, "Low reserve");
    }

    /**
     * @notice Unified stake query function (merged version)
     * @param account User address
     * @param queryType Query type: 0-total rewards, 1-specific ID rewards, 2-allowance amount, 3-stake validation
     * @param tokenId Stake record ID (used when queryType=1)
     * @param amount Stake amount (used when queryType=3)
     * @return result Query result
     * @return reason Validation failure reason (used when queryType=3)
     */
    function getStakeInfo(address account, uint256 queryType, uint256 tokenId, uint256 amount) external view returns (uint256 result, string memory reason) {
        if (queryType == 0) {
            // Get total rewards
            uint256[] memory tokenIds = userAssets[msg.sender].tokenIds;
            require(tokenIds.length > 0, "No stakes");
            StakeRecord[] memory stakes = new StakeRecord[](tokenIds.length);
            for (uint256 i = 0; i < tokenIds.length; i++) {
                StakeRecord memory record = NFTManager(_nftManager).getStakeRecord(tokenIds[i]);
                stakes[i] = record;
            }
            uint256 totalRewards = 0;
            for (uint256 i = 0; i < stakes.length; i++) {
                if (stakes[i].active) {
                    totalRewards += _calculateStakeReward(stakes[i]) + stakes[i].pendingReward;
                }
            }
            return (totalRewards, "");
        } else if (queryType == 1) {
            // Get specific ID rewards
            StakeRecord memory stakeRecord = NFTManager(_nftManager).getStakeRecord(tokenId);
            if (!stakeRecord.active) return (0, "Stake Info Not Active");
            return (_calculateStakeReward(stakeRecord) + stakeRecord.pendingReward, "");
        } else if (queryType == 2) {
            // Get allowance amount
            return (IERC20(address(pusdToken)).allowance(account, address(this)), "");
        } else if (queryType == 3) {
            // Validate if staking is possible
            if (amount < minLockAmount * (10 ** pusdToken.decimals())) {
                return (0, "Below min amount");
            }
            if (pusdToken.balanceOf(account) < amount) {
                return (0, "Low PUSD");
            }
            if (IERC20(address(pusdToken)).allowance(account, address(this)) < amount) {
                return (0, "Insufficient PUSD allowance");
            }
            return (1, "");
        }
        return (0, "Bad query");
    }

    /* ========== APY Management Functions ========== */

    /**
     * @notice Set new APY (supports historical records)
     * @param newAPY New annual percentage yield (basis points, 1500 = 15%)
     */
    function setAPY(uint256 newAPY) external onlyRole(OPERATOR_ROLE) {
        require(newAPY <= type(uint16).max, "APY overflow");
        require(newAPY != currentAPY, "APY unchanged");

        uint16 oldAPY = currentAPY;
        currentAPY = uint16(newAPY);

        // Record APY change history
        _recordAPYChange(uint16(newAPY));

        emit APYUpdated(oldAPY, uint16(newAPY), block.timestamp);
    }

    /**
     * @notice Record APY change history
     * @param newAPY New APY
     */
    function _recordAPYChange(uint16 newAPY) internal {
        // Check historical record count limit
        if (apyHistory.length >= maxAPYHistory) {
            // Delete oldest record (keep most recent records)
            for (uint256 i = 0; i < apyHistory.length - 1; i++) {
                apyHistory[i] = apyHistory[i + 1];
            }
            apyHistory.pop();
        }

        // Add new APY record
        apyHistory.push(APYRecord({apy: newAPY, timestamp: block.timestamp}));
    }

    /* ========== DAO Pool Helper Functions ========== */

    /**
     * @notice Calculate rewards for single stake record (NO post-expiry yield)
     * @dev After lock period ends, rewards stop accruing. If the user claims late, only
     *      the portion up to unlockTime is counted once.
     * @param stakeRecord Stake record
     * @return Rewards for this stake
     */
    function _calculateStakeReward(StakeRecord memory stakeRecord) internal view returns (uint256) {
        if (!stakeRecord.active || stakeRecord.amount == 0) {
            return 0;
        }

        uint256 unlockTime = stakeRecord.startTime + stakeRecord.lockPeriod;
        uint256 toTime = block.timestamp;

        // If already past unlock and user has claimed up to or beyond unlock, no further rewards
        if (stakeRecord.lastClaimTime >= unlockTime) {
            return 0;
        }

        // Cap calculation window at unlockTime (no rewards after unlock)
        uint256 effectiveEnd = toTime <= unlockTime ? toTime : unlockTime;

        return _calculateRewardWithHistory(stakeRecord.amount, stakeRecord.lastClaimTime, effectiveEnd, stakeRecord.rewardMultiplier);
    }

    /**
     * @notice Calculate yield for specified time period based on APY history (snapshot method, supports external data sources)
     * @param amount Stake amount
     * @param fromTime Start time
     * @param toTime End time
     * @param multiplier Reward multiplier
     * @return Calculated yield
     */
    function _calculateRewardWithHistory(uint256 amount, uint256 fromTime, uint256 toTime, uint16 multiplier) internal view returns (uint256) {
        if (fromTime >= toTime || amount == 0) {
            return 0;
        }

        uint256 totalReward = 0;
        uint256 currentTime = fromTime;

        // Iterate through APY history records, calculate yield in segments
        for (uint256 i = 0; i < apyHistory.length && currentTime < toTime; i++) {
            APYRecord memory record = apyHistory[i];

            // If this APY record is within our time range
            if (record.timestamp > currentTime) {
                // Calculate yield to next APY change point or end time
                uint256 segmentEndTime = record.timestamp > toTime ? toTime : record.timestamp;
                uint256 segmentDuration = segmentEndTime - currentTime;

                // Get APY effective for current time segment: if first record, use initial APY; otherwise use previous record's APY
                uint256 segmentAPY = (i == 0) ? apyHistory[0].apy : apyHistory[i - 1].apy;

                // Calculate yield for this segment
                uint256 segmentReward = _calculateSegmentReward(amount, segmentAPY, segmentDuration, multiplier);
                totalReward += segmentReward;
                currentTime = segmentEndTime;
            }
        }

        // Handle final segment (using current APY)
        if (currentTime < toTime) {
            uint256 finalDuration = toTime - currentTime;
            uint256 finalReward = _calculateSegmentReward(amount, currentAPY, finalDuration, multiplier);
            totalReward += finalReward;
        }

        return totalReward;
    }

    /**
     * @notice Calculate yield for single time segment
     * @param amount Amount
     * @param apy APY (basis points)
     * @param duration Duration (seconds)
     * @param multiplier Reward multiplier
     * @return Calculated yield
     */
    function _calculateSegmentReward(uint256 amount, uint256 apy, uint256 duration, uint16 multiplier) internal pure returns (uint256) {
        if (duration == 0 || amount == 0) {
            return 0;
        }

        // Apply multiplier to get effective APY (cast to prevent overflow)
        uint256 effectiveAPY = (apy * uint256(multiplier)) / 10000;

        // Convert basis points to decimal with precision
        uint256 precision = 1e18;
        // percentage = effectiveAPY / 10000
        uint256 annualRate = (effectiveAPY * precision) / 10000;

        // Calculate second rate for better precision
        uint256 secondRate = annualRate / (365 * 24 * 3600);

        // Calculate reward for the time period
        return (amount * secondRate * duration) / precision;
    }

    /* ========== Query Functions ========== */

    /**
     * @notice Get all supported lock periods with their multipliers
     * @return lockPeriods Array of supported lock periods (in seconds)
     * @return multipliers Array of corresponding multipliers (basis points)
     */
    function getSupportedLockPeriodsWithMultipliers() external view returns (uint256[] memory lockPeriods, uint16[] memory multipliers) {
        lockPeriods = supportedLockPeriods;
        multipliers = new uint16[](lockPeriods.length);

        for (uint256 i = 0; i < lockPeriods.length; i++) {
            multipliers[i] = lockPeriodMultipliers[lockPeriods[i]];
        }
    }

    /**
     * @notice Get complete user information (DAO pool mode)
     * @param user User address
     * @return pusdBalance User PUSD balance
     * @return ypusdBalance User yPUSD balance
     * @return totalDeposited Total deposited amount
     * @return totalStakedAmount Total staked amount
     * @return totalStakeRewards Total pending rewards
     * @return activeStakeCount Active stake record count
     */
    function getUserInfo(address user) external view returns (uint256 pusdBalance, uint256 ypusdBalance, uint256 totalDeposited, uint256 totalStakedAmount, uint256 totalStakeRewards, uint256 activeStakeCount) {
        UserAssetInfo storage info = userAssets[user];

        uint256[] memory tokenIds = info.tokenIds;
        StakeRecord[] memory stakes = new StakeRecord[](tokenIds.length);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            stakes[i] = NFTManager(_nftManager).getStakeRecord(tokenIds[i]);
        }

        // Calculate total amount and rewards for all active stakes
        uint256 _totalStakedAmount = 0;
        uint256 _totalStakeRewards = 0;
        uint256 _activeStakeCount = 0;

        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].active) {
                _totalStakedAmount += stakes[i].amount;
                _totalStakeRewards += _calculateStakeReward(stakes[i]) + stakes[i].pendingReward;
                _activeStakeCount++;
            }
        }

        return (
            pusdToken.balanceOf(user), // Query real balance from PUSD contract
            ypusdToken.balanceOf(user), // Query real balance from yPUSD contract
            info.totalDeposited,
            _totalStakedAmount,
            _totalStakeRewards,
            _activeStakeCount
        );
    }

    /**
     * @notice Get detailed information for user's specific stake record
     * @param user User address
     * @param tokenId Stake record ID
     * @return stakeRecord Stake record details
     * @return pendingReward Pending rewards
     * @return unlockTime Unlock time
     * @return isUnlocked Whether already unlocked
     * @return remainingTime Remaining lock time
     */
    function getStakeDetails(address user, uint256 tokenId) external view returns (StakeRecord memory stakeRecord, uint256 pendingReward, uint256 unlockTime, bool isUnlocked, uint256 remainingTime) {
        NFTManager nftManager = NFTManager(_nftManager);
        require(nftManager.ownerOf(tokenId) == user, "Not owner");
        stakeRecord = nftManager.getStakeRecord(tokenId);
        require(stakeRecord.active, "Inactive stake");

        // Calculate rewards using snapshot method
        pendingReward = _calculateRewardWithHistory(stakeRecord.amount, stakeRecord.lastClaimTime, block.timestamp, stakeRecord.rewardMultiplier) + stakeRecord.pendingReward;

        unlockTime = stakeRecord.startTime + stakeRecord.lockPeriod;
        isUnlocked = block.timestamp >= unlockTime;
        remainingTime = isUnlocked ? 0 : unlockTime - block.timestamp;
    }

    /**
     * @notice Get user stake record details with pagination
     * @param user User address
     * @param offset Starting position
     * @param limit Return quantity limit (maximum 50)
     * @param activeOnly Filter condition: true=only return active records, false=return all records
     * @param lockPeriod Filter by lock period (0 = no filter, returns all pools)
     * @return stakeDetails Array of stake details
     * @return totalCount Total record count (matching conditions)
     * @return hasMore Whether there are more records
     */
    function getUserStakeDetails(address user, uint256 offset, uint256 limit, bool activeOnly, uint256 lockPeriod) external view returns (StakeDetail[] memory stakeDetails, uint256 totalCount, bool hasMore) {
        NFTManager nftManager = NFTManager(_nftManager);
        uint256[] memory tokenIds = userAssets[user].tokenIds;

        StakeRecord[] memory stakes = new StakeRecord[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            stakes[i] = nftManager.getStakeRecord(tokenIds[i]);
        }
        // Limit single query quantity to prevent gas overflow
        if (limit > 50) limit = 50;

        // First calculate qualifying record count and positions
        uint256[] memory validIndices = new uint256[](stakes.length);
        uint256 validCount = 0;

        for (uint256 i = 0; i < stakes.length; i++) {
            // Apply filters: activeOnly and lockPeriod
            bool matchesActiveFilter = !activeOnly || stakes[i].active;
            bool matchesLockPeriodFilter = lockPeriod == 0 || stakes[i].lockPeriod == lockPeriod;

            if (matchesActiveFilter && matchesLockPeriodFilter) {
                validIndices[validCount] = i;
                validCount++;
            }
        }

        totalCount = validCount;

        if (offset >= totalCount) {
            return (new StakeDetail[](0), totalCount, false);
        }

        uint256 endIndex = offset + limit;
        if (endIndex > totalCount) endIndex = totalCount;

        uint256 resultLength = endIndex - offset;
        stakeDetails = new StakeDetail[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            uint256 stakeIndex = validIndices[offset + i];
            StakeRecord memory record = stakes[stakeIndex];

            stakeDetails[i] = StakeDetail({
                tokenId: tokenIds[stakeIndex],
                amount: record.amount,
                startTime: record.startTime,
                lockPeriod: record.lockPeriod,
                lastClaimTime: record.lastClaimTime,
                rewardMultiplier: record.rewardMultiplier,
                active: record.active,
                currentReward: record.active ? _calculateStakeReward(record) : 0,
                unlockTime: record.startTime + record.lockPeriod,
                isUnlocked: block.timestamp >= record.startTime + record.lockPeriod,
                effectiveAPY: (uint256(currentAPY) * uint256(record.rewardMultiplier)) / 10000
            });
        }

        hasMore = endIndex < totalCount;
    }

    /* ========== Admin Functions ========== */

    /**
     * @dev Internal function to distribute rewards via Vault
     * @param to Recipient address
     * @param amount Reward amount
     * @return success Whether the reward was distributed
     */
    function _distributeReward(address to, uint256 amount) internal returns (bool success) {
        if (amount == 0) return true;
        return vault.distributeReward(to, amount);
    }

    /**
     * @dev Internal function to remove tokenId from user's tokenIds array
     * @param user User address
     * @param tokenId Token ID to remove
     */
    function _removeTokenIdFromUser(address user, uint256 tokenId) internal {
        uint256[] storage tokenIds = userAssets[user].tokenIds;
        uint256 len = tokenIds.length;

        for (uint256 i = 0; i < len; i++) {
            if (tokenIds[i] == tokenId) {
                // Move last element to current position, then pop
                tokenIds[i] = tokenIds[len - 1];
                tokenIds.pop();
                return;
            }
        }
    }

    /* ========== Multiplier Configuration Management ========== */
    /**
     * @notice Batch set lock period configuration (multipliers and pool caps)
     * @dev Multiplier is in basis points (10000 = 1.00x, 15000 = 1.50x, 50000 = 5.00x)
     *      The actual effective APY = base APY × (multiplier / 10000)
     *      For example: base APY 20% (2000 bps), multiplier 15000 (1.5x) → effective APY = 30%
     * @param lockPeriods Array of lock periods (in seconds)
     * @param multipliers Array of corresponding multipliers (basis points, range: 5000-50000, i.e., 0.5x-5.0x)
     * @param caps Array of pool caps (0 = no limit)
     */
    function batchSetLockPeriodConfig(uint256[] calldata lockPeriods, uint16[] calldata multipliers, uint256[] calldata caps) external onlyRole(OPERATOR_ROLE) {
        require(lockPeriods.length == multipliers.length && lockPeriods.length == caps.length, "Length mismatch");
        require(lockPeriods.length > 0, "Empty arrays");

        for (uint256 i = 0; i < lockPeriods.length; i++) {
            require(lockPeriods[i] > 0, "Invalid period");
            require(multipliers[i] >= 5000, "Bad multiplier");

            uint16 oldMultiplier = lockPeriodMultipliers[lockPeriods[i]];

            if (oldMultiplier == 0) {
                supportedLockPeriods.push(lockPeriods[i]);
                emit LockPeriodAdded(lockPeriods[i], multipliers[i]);
            } else {
                emit MultiplierUpdated(lockPeriods[i], oldMultiplier, multipliers[i]);
            }

            lockPeriodMultipliers[lockPeriods[i]] = multipliers[i];
            poolCap[lockPeriods[i]] = caps[i];
            emit PoolCapUpdated(lockPeriods[i], caps[i]);
        }
    }

    /**
     * @notice Remove lock period configuration
     * @param lockPeriod Lock period to remove
     */
    function removeLockPeriod(uint256 lockPeriod) external onlyRole(OPERATOR_ROLE) {
        require(lockPeriodMultipliers[lockPeriod] > 0, "Period not found");

        // Remove from array
        for (uint256 i = 0; i < supportedLockPeriods.length; i++) {
            if (supportedLockPeriods[i] == lockPeriod) {
                // Move last element to current position, then delete last element
                supportedLockPeriods[i] = supportedLockPeriods[supportedLockPeriods.length - 1];
                supportedLockPeriods.pop();
                break;
            }
        }

        delete lockPeriodMultipliers[lockPeriod];
        emit LockPeriodRemoved(lockPeriod);
    }

    /**
     * @notice Update stake record by FarmLend
     * @param tokenId Token ID
     * @param pusdAmount PUSD amount
     */
    function updateByFarmLend(uint256 tokenId, uint256 pusdAmount) public {
        require(msg.sender == farmLend, "Unauthorized");
        NFTManager nftManager = NFTManager(_nftManager);
        IFarm.StakeRecord memory record = nftManager.getStakeRecord(tokenId);
        require(record.amount >= pusdAmount, "Low stake");
        uint256 reward = _calculateStakeReward(record);
        // Update last claim time
        record.lastClaimTime = block.timestamp;
        // Update pending reward
        record.pendingReward += reward;
        // Update stake amount
        record.amount = pusdAmount;
        nftManager.updateStakeRecord(tokenId, record);
    }

    /* ========== PUSD Bridge Functions ========== */

    /**
     * @notice Initiate PUSD bridge to another chain
     * @dev Burns PUSD on source chain and sends message via MessageManager
     * @param sourceChainId Source chain ID (must match current chain)
     * @param destChainId Destination chain ID
     * @param to Recipient address on destination chain
     * @param value Amount of PUSD to bridge
     * @return success Whether initiation succeeded
     */
    function bridgeInitiatePUSD(uint256 sourceChainId, uint256 destChainId, address to, uint256 value) external nonReentrant whenNotPaused returns (bool success) {
        require(sourceChainId == block.chainid, "Invalid chain");
        require(bridgeMessenger != address(0), "Bridge messenger not set");
        require(to != address(0), "Bad recipient");
        require(value > 0, "Zero amount");

        // Check user PUSD balance
        require(pusdToken.balanceOf(msg.sender) >= value, "Low PUSD");
        require(isSupportedBridgeChain[destChainId], "Destination chain not supported");

        // Calculate bridge fee (explicit uint256 cast to avoid potential optimizer issues)
        uint256 fee = (value * uint256(bridgeFeeRate)) / 10000;
        uint256 netAmount = value - fee;

        // Burn PUSD from user (total amount including fee)
        pusdToken.burn(msg.sender, value);

        // Send cross-chain message via MessageManager
        // MessageManager will generate messageNumber internally
        IMessageManager(bridgeMessenger).sendMessage(sourceChainId, destChainId, address(pusdToken), address(pusdToken), msg.sender, to, netAmount, fee);

        emit BridgePUSDInitiated(sourceChainId, destChainId, msg.sender, to, value, netAmount, fee);

        return true;
    }

    /**
     * @notice Finalize PUSD bridge from another chain
     * @dev Mints PUSD to recipient after cross-chain message is verified by Relayer
     *      This function is called by OPERATOR_ROLE (Relayer) after verifying MessageSent event on source chain
     * @param sourceChainId Source chain ID (e.g., 56 for BNB Chain, 10 for Optimism)
     * @param destChainId Destination chain ID (must match current chain)
     * @param from Original sender address on source chain
     * @param to Recipient address on destination chain
     * @param amount Amount to mint (net after fees)
     * @param _fee Bridge fee amount
     * @param _nonce Message nonce from MessageManager on source chain
     * @return success Whether finalization succeeded
     */
    function bridgeFinalizedPUSD(uint256 sourceChainId, uint256 destChainId, address from, address to, uint256 amount, uint256 _fee, uint256 _nonce) external nonReentrant whenNotPaused onlyRole(BRIDGE_ROLE) returns (bool success) {
        // Verify destination chain ID matches current chain
        require(destChainId == block.chainid, "Invalid chain");
        require(isSupportedBridgeChain[sourceChainId], "Bad chain");
        require(to != address(0), "Bad recipient");
        require(amount > 0, "Zero amount");

        // Mint PUSD to recipient
        pusdToken.mint(to, amount);

        // Handle fees
        if (_fee > 0) {
            vault.addFee(address(pusdToken), _fee);
        }

        // Claim message via MessageManager to mark as completed
        IMessageManager(bridgeMessenger).claimMessage(sourceChainId, destChainId, address(pusdToken), address(pusdToken), from, to, amount, _fee, _nonce);

        emit BridgePUSDFinalized(sourceChainId, destChainId, from, to, amount, _fee, _nonce);

        return true;
    }

    /**
     * @notice Set bridge messenger address (MessageManager)
     * @param messenger MessageManager contract address on current chain
     */
    function setBridgeMessenger(address messenger) external onlyRole(OPERATOR_ROLE) {
        require(messenger != address(0), "Bad messenger");
        address oldMessenger = bridgeMessenger;
        bridgeMessenger = messenger;
        emit BridgeMessengerUpdated(oldMessenger, messenger);
    }

    function setSupportedBridgeChain(uint256[] memory chainId, bool[] memory isSupported) external onlyRole(OPERATOR_ROLE) {
        require(chainId.length == isSupported.length, "Length mismatch");
        for (uint256 i = 0; i < chainId.length; i++) {
            isSupportedBridgeChain[chainId[i]] = isSupported[i];
        }
        emit BridgeChainSupportUpdated(chainId, isSupported);
    }

    /* ========== System Configuration Management ========== */

    /**
     * @notice Unified configuration management function (merged version)
     * @param configType Configuration type: 0-minimum deposit, 1-minimum stake, 2-max stakes, 3-max APY history
     * @param newValue New value
     */
    function updateSystemConfig(uint256 configType, uint256 newValue) external onlyRole(OPERATOR_ROLE) {
        if (configType == 0) {
            require(
                // pusd has 6 decimals
                newValue >= 0 && newValue <= 1000 * 10 ** 6,
                "Invalid min deposit amount"
            );
            minDepositAmount = newValue;
        } else if (configType == 1) {
            require(
                // pusd has 6 decimals
                newValue >= 0 && newValue <= 10000 * 10 ** 6,
                "Invalid min lock amount"
            );
            minLockAmount = newValue;
        } else if (configType == 2) {
            require(newValue >= 10 && newValue <= 65535, "Invalid max stakes per user");
            maxStakesPerUser = uint16(newValue);
        } else if (configType == 3) {
            require(newValue >= 50 && newValue <= 65535, "Invalid max APY history");
            maxAPYHistory = uint16(newValue);
        } else {
            revert("Bad config");
        }
    }

    /* ========== Admin Functions ========== */

    /**
     * @notice Set fee rates
     * @param _depositFeeRate Deposit fee rate (basis points, 100 = 1%)
     * @param _withdrawFeeRate Withdrawal fee rate (basis points, 100 = 1%)
     * @param _bridgeFeeRate Bridge fee rate (basis points, 100 = 1%)
     */
    function setFeeRates(uint256 _depositFeeRate, uint256 _withdrawFeeRate, uint256 _bridgeFeeRate) external onlyRole(OPERATOR_ROLE) {
        require(_depositFeeRate <= type(uint16).max, "Fee overflow");
        require(_withdrawFeeRate <= type(uint16).max, "Fee overflow");
        require(_bridgeFeeRate <= type(uint16).max, "Fee overflow");

        depositFeeRate = uint16(_depositFeeRate);
        withdrawFeeRate = uint16(_withdrawFeeRate);
        bridgeFeeRate = uint16(_bridgeFeeRate);

        emit FeeRatesUpdated(_depositFeeRate, _withdrawFeeRate, _bridgeFeeRate);
    }

    function setNFTManager(address nftManager_) external onlyRole(OPERATOR_ROLE) {
        require(nftManager_ != address(0), "Invalid NFT mgr");
        _nftManager = nftManager_;
        emit NFTManagerUpdated(nftManager_);
    }

    function setFarmLend(address farmLend_) external onlyRole(OPERATOR_ROLE) {
        require(farmLend_ != address(0), "Bad FarmLend");
        farmLend = farmLend_;
        emit FarmLendUpdated(farmLend_);
    }

    /**
     * @notice Pause contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Upgrade authorization
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin privileges are sufficient, no additional validation needed
    }
}
