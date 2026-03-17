// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../interfaces/IPUSD.sol";
import "../interfaces/IyPUSD.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IStakingVault.sol";
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
        if (admin == address(0)) revert ZeroAddress();
        if (_pusdToken == address(0)) revert ZeroAddress();
        if (_ypusdToken == address(0)) revert ZeroAddress();
        if (_vault == address(0)) revert ZeroAddress();

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
        if (!vault.isValidAsset(asset)) revert BadAsset();
        // Here amount is asset quantity, not USD, need to convert to pusd amount
        (uint256 pusdAmount, ) = vault.getTokenPUSDValue(asset, amount);
        if (pusdAmount == 0) revert InvalidAmount();

        if (pusdAmount < minDepositAmount) revert TooSmall();

        // Calculate fee using effective fee rate (custom or default)
        uint16 effectiveFeeRate = getEffectiveFeeRate(0, msg.sender);
        uint256 fee = (amount * uint256(effectiveFeeRate)) / 10000;
        uint256 netPUSD = pusdAmount - (pusdAmount * uint256(effectiveFeeRate)) / 10000;

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
        if (userInfo.lastActionTime == 0) {
            totalUsers++;
        }
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
        if (!vault.isValidAsset(asset)) revert BadAsset();
        if (pusdAmount == 0) revert ZeroAmount();

        // Check user PUSD balance
        if (pusdToken.balanceOf(msg.sender) < pusdAmount) revert LowPUSD();

        // Calculate required asset amount for withdrawal (reverse calculation through Oracle)
        (uint256 assetAmount, ) = vault.getPUSDAssetValue(asset, pusdAmount);
        if (assetAmount == 0) revert InvalidAmount();

        // Check if Vault has sufficient asset balance
        (uint256 vaultBalance, ) = vault.getTVL(asset);
        if (vaultBalance < assetAmount) revert LowReserve();

        UserAssetInfo storage userInfo = userAssets[msg.sender];

        // Calculate withdrawal fee using effective fee rate (custom or default)
        uint16 effectiveFeeRate = getEffectiveFeeRate(1, msg.sender);
        uint256 assetFee = (assetAmount * uint256(effectiveFeeRate)) / 10000;
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
        if (userInfo.lastActionTime == 0) {
            totalUsers++;
        }
        userInfo.lastActionTime = block.timestamp;

        // Update statistics
        totalVolumeUSD += pusdAmount;

        emit AssetOperation(msg.sender, asset, netAssetAmount, assetFee, false);
    }

    /**
     * @notice Stake PUSD to earn mining rewards (DAO pool mode)
     * @dev Each stake recorded independently; rewards accrue ONLY during the lock period (no post-expiry yield)
     * @param poolId Pool ID to stake into
     * @param amount Amount of PUSD to stake
     * @return tokenId Record ID for this stake
     */
    function stakePUSD(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        if (amount < minLockAmount) revert TooSmall();

        // Verify pool exists and is enabled
        Pool storage pool = pools[poolId];
        if (pool.createdAt == 0) revert PoolNotExists();
        if (!pool.enabled) revert PoolNotEnabled();

        // Check pool cap (using pool.used which never decreases)
        if (pool.cap != 0 && pool.used + amount > pool.cap) revert PoolFull();

        // Check max stakes per user
        if (userAssets[msg.sender].tokenIds.length >= maxStakesPerUser) revert MaxStakesReached();

        // Check user PUSD balance
        if (pusdToken.balanceOf(msg.sender) < amount) revert LowPUSD();

        // Transfer PUSD from user to StakingVault (isolated from Treasury)
        stakingVault.depositStake(msg.sender, amount);

        // Use pool's reward multiplier
        uint16 multiplier = pool.rewardMultiplier;
        if (multiplier == 0) revert BadMultiplier();

        // Record stake in NFT Manager contract
        NFTManager nftManager = NFTManager(_nftManager);
        tokenId = nftManager.mintStakeNFT(msg.sender, poolId, amount, uint64(pool.lockPeriod), multiplier, 0);

        // Update total staked amount
        totalStaked += amount;

        // Update pool TVL and used (pool.used never decreases)
        pool.tvl += amount;
        pool.used += amount;

        // Update user operation time
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        if (userInfo.lastActionTime == 0) {
            totalUsers++;
        }
        userInfo.lastActionTime = block.timestamp;
        userInfo.tokenIds.push(tokenId);

        emit StakeOperation(msg.sender, tokenId, amount, pool.lockPeriod, true);
    }

    /**
     * @notice Renew stake
     * @dev After stake unlock, can choose new pool to continue staking.
     *      Rewards are automatically compounded into the stake principal.
     * @param tokenId Stake record ID (NFT tokenId)
     * @param newPoolId New pool ID
     */
    function renewStake(uint256 tokenId, uint256 newPoolId) external nonReentrant whenNotPaused {
        NFTManager nftManager = NFTManager(_nftManager);
        if (nftManager.ownerOf(tokenId) != msg.sender) revert NotOwner();
        StakeRecord memory stakeRecord = nftManager.getStakeRecord(tokenId);

        if (!stakeRecord.active) revert InactiveStake();
        if (block.timestamp < stakeRecord.startTime + stakeRecord.lockPeriod) revert StillLocked();
        
        // Verify new pool exists and is enabled
        Pool storage newPool = pools[newPoolId];
        if (newPool.createdAt == 0) revert PoolNotExists();
        if (!newPool.enabled) revert PoolNotEnabled();

        // Call internal function directly to avoid code duplication
        _executeRenewal(tokenId, newPoolId);
    }

    /**
     * @notice Internal function to execute renewal
     * @dev Core logic extracted from renewStake to avoid code duplication.
     *      Rewards are always compounded into the stake principal.
     */
    function _executeRenewal(uint256 tokenId, uint256 newPoolId) internal {
        NFTManager nftManager = NFTManager(_nftManager);
        StakeRecord memory stakeRecord = nftManager.getStakeRecord(tokenId);

        // Calculate rewards BEFORE updating stake record (uses old startTime/lastClaimTime/lockPeriod)
        uint256 reward = _calculateStakeReward(stakeRecord);
        uint256 totalReward = reward + stakeRecord.pendingReward;

        // Save old pool info
        uint256 oldPoolId = stakeRecord.poolId;
        uint256 oldAmount = stakeRecord.amount;

        // Get new pool
        Pool storage newPool = pools[newPoolId];

        // Check pool cap before renewal (using pool.used which never decreases)
        // Every renewal consumes quota for the full amount (principal + rewards)
        uint256 newAmount = oldAmount + totalReward;
        if (newPool.cap != 0 && newPool.used + newAmount > newPool.cap) revert PoolFull();

        // Reset stake record for new pool AFTER reward calculation
        stakeRecord.poolId = newPoolId;
        stakeRecord.startTime = block.timestamp;
        stakeRecord.lastClaimTime = block.timestamp;
        stakeRecord.lockPeriod = newPool.lockPeriod;
        stakeRecord.rewardMultiplier = newPool.rewardMultiplier;
        stakeRecord.pendingReward = 0;

        // Compound rewards: add to stake principal
        // CRITICAL: Move rewards from reserve to staked principal in StakingVault
        if (totalReward > 0) {
            // Compound reward (moves from rewardReserve to totalStaked in StakingVault)
            bool success = stakingVault.compoundReward(totalReward);
            if (!success) revert LowReserve();
            
            stakeRecord.amount += totalReward;
            totalStaked += totalReward;
        }

        // Update pool TVL and used
        // Every renewal consumes quota for the full amount (principal + rewards)
        if (oldPoolId != newPoolId) {
            // Transfer TVL from old pool to new pool
            Pool storage oldPool = pools[oldPoolId];
            if (oldPool.tvl >= oldAmount) {
                oldPool.tvl -= oldAmount;
            } else {
                oldPool.tvl = 0;
            }
            newPool.tvl += stakeRecord.amount;
        } else if (totalReward > 0) {
            // Same pool but amount increased due to compounding
            newPool.tvl += totalReward;
        }
        // pool.used: always add full amount for every renewal
        newPool.used += stakeRecord.amount;

        emit StakeRenewal(msg.sender, tokenId, newPool.lockPeriod, totalReward, stakeRecord.amount, true);

        // Update user operation time
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        if (userInfo.lastActionTime == 0) {
            totalUsers++;
        }
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
        if (nftManager.ownerOf(tokenId) != msg.sender) revert NotOwner();

        StakeRecord memory stakeRecord = nftManager.getStakeRecord(tokenId);
        if (!stakeRecord.active) revert InactiveStake();
        if (block.timestamp < stakeRecord.startTime + stakeRecord.lockPeriod) revert StillLocked();

        uint256 amount = stakeRecord.amount;

        // Calculate and distribute rewards for this stake
        uint256 reward = _calculateStakeReward(stakeRecord);
        uint256 totalReward = reward + stakeRecord.pendingReward;
        if (totalReward > 0) {
            // Distribute PUSD rewards from reserve
            bool success = _distributeReward(msg.sender, totalReward);
            if (!success) revert LowReserve();
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
        // Update pool TVL (pool.used is NOT decreased - it never decreases)
        Pool storage pool = pools[stakeRecord.poolId];
        if (pool.tvl >= amount) {
            pool.tvl -= amount;
        } else {
            pool.tvl = 0;
        }

        // Withdraw staked PUSD from StakingVault to user
        stakingVault.withdrawStake(msg.sender, amount);

        nftManager.updateStakeRecord(tokenId, stakeRecord);
        // Burn stake NFT
        nftManager.burn(tokenId);

        // Update user operation time
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        if (userInfo.lastActionTime == 0) {
            totalUsers++;
        }
        userInfo.lastActionTime = block.timestamp;

        // Remove tokenId from user's tokenIds array
        _removeTokenIdFromUser(msg.sender, tokenId);

        emit StakeOperation(msg.sender, tokenId, amount, 0, false);
    }

    /**
     * @notice Unified stake query function (merged version)
     * @param account User address
     * @param queryType Query type: 
     *        0 - total rewards for all stakes
     *        1 - specific stake rewards (tokenId = stake ID)
     *        2 - PUSD allowance amount
     *        3 - canStake validation (tokenId = poolId, amount = stake amount)
     *        4 - canRenewStake validation (tokenId = stake ID, amount = newPoolId)
     * @param tokenId Stake record ID (queryType 1,4) or poolId (queryType 3)
     * @param amount Stake amount (queryType 3) or newPoolId (queryType 4)
     * @return result Query result:
     *         queryType 0,1: reward amount
     *         queryType 2: allowance amount
     *         queryType 3: 1=can stake, 0=cannot
     *         queryType 4: estimatedNewAmount if can renew, 0 if cannot
     * @return reason Validation failure reason (queryType 3,4)
     */
    function getStakeInfo(address account, uint256 queryType, uint256 tokenId, uint256 amount) external view returns (uint256 result, string memory reason) {
        if (queryType == 0) {
            // Get total rewards
            uint256[] memory tokenIds = userAssets[account].tokenIds;
            if (tokenIds.length == 0) revert NoStakes();
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
            // canStake validation (tokenId parameter is used as poolId)
            uint256 poolId = tokenId;
            
            // Check minimum amount
            if (amount < minLockAmount) {
                return (0, "Below min amount");
            }
            
            // Check if pool exists and is enabled
            Pool storage pool = pools[poolId];
            if (pool.createdAt == 0) {
                return (0, "Pool not exists");
            }
            if (!pool.enabled) {
                return (0, "Pool not enabled");
            }
            
            // Check pool cap (using pool.used which never decreases)
            if (pool.cap > 0 && pool.used + amount > pool.cap) {
                return (0, "Pool full");
            }
            
            // Check max stakes per user
            if (userAssets[account].tokenIds.length >= maxStakesPerUser) {
                return (0, "Max stakes reached");
            }
            
            // Check PUSD balance
            if (pusdToken.balanceOf(account) < amount) {
                return (0, "Low PUSD");
            }
            
            // Check allowance
            if (IERC20(address(pusdToken)).allowance(account, address(this)) < amount) {
                return (0, "Insufficient allowance");
            }
            
            return (1, "");
        } else if (queryType == 4) {
            // canRenewStake validation (tokenId parameter is tokenId, amount parameter is newPoolId)
            uint256 newPoolId = amount;
            NFTManager nftManager = NFTManager(_nftManager);
            
            // Check if tokenId exists
            try nftManager.ownerOf(tokenId) returns (address) {
                // tokenId exists
            } catch {
                return (0, "Invalid tokenId");
            }
            
            StakeRecord memory stakeRecord = nftManager.getStakeRecord(tokenId);
            
            // Check if stake is active
            if (!stakeRecord.active) {
                return (0, "Inactive stake");
            }
            
            // Check if unlocked
            if (block.timestamp < stakeRecord.startTime + stakeRecord.lockPeriod) {
                return (0, "Still locked");
            }
            
            // Check if new pool exists and is enabled
            Pool storage newPool = pools[newPoolId];
            if (newPool.createdAt == 0) {
                return (0, "Pool not exists");
            }
            if (!newPool.enabled) {
                return (0, "Pool not enabled");
            }
            
            // Calculate estimated rewards for compounding
            uint256 reward = _calculateStakeReward(stakeRecord);
            uint256 totalReward = reward + stakeRecord.pendingReward;
            uint256 estimatedNewAmount = stakeRecord.amount + totalReward;
            
            // Check pool cap (using pool.used which never decreases)
            // Every renewal consumes quota for the full amount
            if (newPool.cap > 0 && newPool.used + estimatedNewAmount > newPool.cap) {
                return (0, "Pool full");
            }
            
            // Check if stakingVault has enough reserve for compounding
            if (totalReward > 0) {
                uint256 reserveBalance = stakingVault.getRewardReserve();
                if (reserveBalance < totalReward) {
                    return (0, "Low reserve");
                }
            }
            
            // Return estimatedNewAmount as result (> 0 means can renew)
            return (estimatedNewAmount, "");
        }
        return (0, "Bad query");
    }

    /* ========== APY Management Functions ========== */

    /**
     * @notice Set new APY (supports historical records)
     * @param newAPY New annual percentage yield (basis points, 1500 = 15%)
     */
    function setAPY(uint256 newAPY) external onlyRole(OPERATOR_ROLE) {
        if (newAPY > type(uint16).max) revert InvalidAmount();
        if (newAPY == currentAPY) revert AlreadyActioned();

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

    /* ========== Pool Management Functions ========== */

    /**
     * @notice Create a new staking pool
     * @param name Pool name (e.g., "2026Q1-30D")
     * @param lockPeriod Lock period in seconds
     * @param cap Maximum capacity (0 = unlimited)
     * @param multiplier Reward multiplier (basis points, 10000 = 1.0x, 15000 = 1.5x)
     * @return poolId The newly created pool ID
     */
    function createPool(string calldata name, uint256 lockPeriod, uint256 cap, uint16 multiplier) external onlyRole(OPERATOR_ROLE) returns (uint256 poolId) {
        if (lockPeriod == 0) revert InvalidPeriod();
        if (multiplier < 5000) revert BadMultiplier(); // At least 0.5x
        if (bytes(name).length == 0) revert EmptyName();
        
        // Check name uniqueness
        bytes32 nameHash = keccak256(bytes(name));
        if (poolNameExists[nameHash]) revert NameExists();
        poolNameExists[nameHash] = true;

        poolId = nextPoolId++;
        pools[poolId] = Pool({
            name: name,
            lockPeriod: lockPeriod,
            cap: cap,
            used: 0,
            tvl: 0,
            rewardMultiplier: multiplier,
            enabled: true,
            createdAt: block.timestamp
        });

        emit PoolCreated(poolId, name, lockPeriod, cap);
    }

    /**
     * @notice Update pool configuration
     * @param poolId Pool ID
     * @param fieldType Field to update: 0=enabled, 1=cap, 2=multiplier
     * @param value New value (for enabled: 0=false, 1=true)
     */
    function updatePool(uint256 poolId, uint8 fieldType, uint256 value) external onlyRole(OPERATOR_ROLE) {
        if (pools[poolId].createdAt == 0) revert PoolNotExists();
        
        if (fieldType == 0) {
            // enabled
            bool enabled = value != 0;
            pools[poolId].enabled = enabled;
            emit PoolEnabledChanged(poolId, enabled);
        } else if (fieldType == 1) {
            // cap
            uint256 oldCap = pools[poolId].cap;
            pools[poolId].cap = value;
            emit PoolCapUpdated(poolId, oldCap, value);
        } else if (fieldType == 2) {
            // multiplier
            if (value < 5000) revert BadMultiplier(); // At least 0.5x
            pools[poolId].rewardMultiplier = uint16(value);
        } else {
            revert InvalidConfig();
        }
    }

    /**
     * @notice Set pool name
     * @param poolId Pool ID
     * @param newName New pool name
     */
    function setPoolName(uint256 poolId, string calldata newName) external onlyRole(OPERATOR_ROLE) {
        if (pools[poolId].createdAt == 0) revert PoolNotExists();
        if (bytes(newName).length == 0) revert EmptyName();
        
        // Check name uniqueness
        bytes32 oldHash = keccak256(bytes(pools[poolId].name));
        bytes32 newHash = keccak256(bytes(newName));
        if (poolNameExists[newHash]) revert NameExists();
        
        // Update name registry
        poolNameExists[oldHash] = false;
        poolNameExists[newHash] = true;
        
        string memory oldName = pools[poolId].name;
        pools[poolId].name = newName;
        emit PoolNameUpdated(poolId, oldName, newName);
    }

    /**
     * @notice Get complete user information (DAO pool mode)
     * @param user User address
     * @return pusdBalance User PUSD balance
     * @return ypusdBalance User yPUSD balance
     * @return totalStakedAmount Total staked amount
     * @return totalStakeRewards Total pending rewards
     * @return activeStakeCount Active stake record count
     */
    function getUserInfo(address user) external view returns (uint256 pusdBalance, uint256 ypusdBalance, uint256 totalStakedAmount, uint256 totalStakeRewards, uint256 activeStakeCount) {
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
     * @return totalReward Total unclaimed rewards (currentReward + pendingReward)
     * @return unlockTime Unlock time
     * @return isUnlocked Whether already unlocked
     * @return remainingTime Remaining lock time
     */
    function getStakeDetails(address user, uint256 tokenId) external view returns (StakeRecord memory stakeRecord, uint256 totalReward, uint256 unlockTime, bool isUnlocked, uint256 remainingTime) {
        NFTManager nftManager = NFTManager(_nftManager);
        if (nftManager.ownerOf(tokenId) != user) revert NotOwner();
        stakeRecord = nftManager.getStakeRecord(tokenId);
        if (!stakeRecord.active) revert InactiveStake();

        // Total unclaimed rewards = calculated current reward + stored pending reward
        totalReward = _calculateStakeReward(stakeRecord) + stakeRecord.pendingReward;

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
            uint256 _unlockTime = record.startTime + record.lockPeriod;

            stakeDetails[i] = StakeDetail({
                tokenId: tokenIds[stakeIndex],
                poolId: record.poolId,
                poolName: pools[record.poolId].name,
                amount: record.amount,
                startTime: record.startTime,
                lockPeriod: record.lockPeriod,
                lastClaimTime: record.lastClaimTime,
                rewardMultiplier: record.rewardMultiplier,
                active: record.active,
                currentReward: record.active ? _calculateStakeReward(record) : 0,
                pendingReward: record.pendingReward,
                unlockTime: _unlockTime,
                isUnlocked: block.timestamp >= _unlockTime,
                effectiveAPY: (uint256(currentAPY) * uint256(record.rewardMultiplier)) / 10000
            });
        }

        hasMore = endIndex < totalCount;
    }

    /* ========== Admin Functions ========== */

    /**
     * @dev Internal function to distribute rewards via StakingVault
     * @param to Recipient address
     * @param amount Reward amount
     * @return success Whether the reward was distributed
     */
    function _distributeReward(address to, uint256 amount) internal returns (bool success) {
        if (amount == 0) return true;
        return stakingVault.distributeReward(to, amount);
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

    /**
     * @notice Callback from NFTManager when stake NFT is transferred
     * @dev Updates tokenIds arrays for both sender and receiver
     * @param from Previous owner address
     * @param to New owner address  
     * @param tokenId The transferred token ID
     */
    function onNFTTransfer(address from, address to, uint256 tokenId) external {
        if (msg.sender != _nftManager) revert OnlyNFTManager();
        
        // Check max stakes limit for receiver
        if (userAssets[to].tokenIds.length >= maxStakesPerUser) revert MaxStakesReached();
        
        // Remove tokenId from sender's array
        _removeTokenIdFromUser(from, tokenId);
        
        // Add tokenId to receiver's array
        UserAssetInfo storage receiverInfo = userAssets[to];
        receiverInfo.tokenIds.push(tokenId);
        
        // Update receiver's lastActionTime if first interaction
        if (receiverInfo.lastActionTime == 0) {
            totalUsers++;
        }
        receiverInfo.lastActionTime = block.timestamp;
        
        emit StakeNFTTransferred(from, to, tokenId);
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
        if (sourceChainId != block.chainid) revert InvalidChain();
        if (bridgeMessenger == address(0)) revert ZeroAddress();
        if (to == address(0)) revert BadRecipient();
        if (value == 0) revert ZeroAmount();

        // Check user PUSD balance
        if (pusdToken.balanceOf(msg.sender) < value) revert LowPUSD();
        if (!isSupportedBridgeChain[destChainId]) revert InvalidChain();

        // Calculate bridge fee using effective fee rate (custom or default)
        uint16 effectiveFeeRate = getEffectiveFeeRate(2, msg.sender);
        uint256 fee = (value * uint256(effectiveFeeRate)) / 10000;
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
     *      Fee is minted to Vault as protocol revenue (consistent with deposit/withdraw fees)
     * @param sourceChainId Source chain ID (e.g., 56 for BNB Chain, 10 for Optimism)
     * @param destChainId Destination chain ID (must match current chain)
     * @param from Original sender address on source chain
     * @param to Recipient address on destination chain
     * @param amount Amount to mint (net after fees)
     * @param _fee Bridge fee amount (minted to Vault as protocol revenue)
     * @param _nonce Message nonce from MessageManager on source chain
     * @return success Whether finalization succeeded
     */
    function bridgeFinalizedPUSD(uint256 sourceChainId, uint256 destChainId, address from, address to, uint256 amount, uint256 _fee, uint256 _nonce) external nonReentrant whenNotPaused onlyRole(BRIDGE_ROLE) returns (bool success) {
        // Verify destination chain ID matches current chain
        if (destChainId != block.chainid) revert InvalidChain();
        if (!isSupportedBridgeChain[sourceChainId]) revert InvalidChain();
        if (to == address(0)) revert BadRecipient();
        if (amount == 0) revert ZeroAmount();

        // Mint PUSD to recipient
        pusdToken.mint(to, amount);

        // Mint fee to Vault and record as protocol revenue
        if (_fee > 0) {
            pusdToken.mint(address(vault), _fee);
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
        if (messenger == address(0)) revert ZeroAddress();
        address oldMessenger = bridgeMessenger;
        bridgeMessenger = messenger;
        emit BridgeMessengerUpdated(oldMessenger, messenger);
    }

    function setSupportedBridgeChain(uint256[] memory chainId, bool[] memory isSupported) external onlyRole(OPERATOR_ROLE) {
        if (chainId.length != isSupported.length) revert LengthMismatch();
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
            if (newValue > 1000 * 10 ** 6) revert InvalidConfig();
            minDepositAmount = newValue;
        } else if (configType == 1) {
            if (newValue > 10000 * 10 ** 6) revert InvalidConfig();
            minLockAmount = newValue;
        } else if (configType == 2) {
            if (newValue < 10 || newValue > 65535) revert InvalidConfig();
            maxStakesPerUser = uint16(newValue);
        } else if (configType == 3) {
            if (newValue < 50 || newValue > 65535) revert InvalidConfig();
            maxAPYHistory = uint16(newValue);
        } else {
            revert InvalidConfig();
        }
    }

    /* ========== Admin Functions ========== */

    /**
     * @notice Batch set custom fee rates for multiple users
     * @param feeType Fee type: 0=deposit, 1=withdraw, 2=bridge
     * @param users Array of user addresses
     * @param feeRates Array of custom fee rates (0 = use default)
     */
    function batchSetCustomFeeRate(uint8 feeType, address[] calldata users, uint16[] calldata feeRates) external onlyRole(OPERATOR_ROLE) {
        if (feeType > 2) revert InvalidFeeType();
        if (users.length != feeRates.length) revert LengthMismatch();
        if (users.length == 0) revert EmptyArrays();
        
        for (uint256 i = 0; i < users.length; i++) {
            if (feeRates[i] > 10000) revert FeeTooHigh();
            customFeeRates[feeType][users[i]] = feeRates[i];
        }
    }

    /**
     * @notice Get effective fee rate for user (custom or default)
     * @param feeType Fee type: 0=deposit, 1=withdraw, 2=bridge
     * @param user User address
     * @return Effective fee rate in basis points
     */
    function getEffectiveFeeRate(uint8 feeType, address user) public view returns (uint16) {
        uint16 customRate = customFeeRates[feeType][user];
        if (customRate > 0) return customRate;
        
        if (feeType == 0) return depositFeeRate;
        if (feeType == 1) return withdrawFeeRate;
        if (feeType == 2) return bridgeFeeRate;
        return 0;
    }

    /**
     * @notice Set fee rates
     * @param _depositFeeRate Deposit fee rate (basis points, 100 = 1%)
     * @param _withdrawFeeRate Withdrawal fee rate (basis points, 100 = 1%)
     * @param _bridgeFeeRate Bridge fee rate (basis points, 100 = 1%)
     */
    function setFeeRates(uint256 _depositFeeRate, uint256 _withdrawFeeRate, uint256 _bridgeFeeRate) external onlyRole(OPERATOR_ROLE) {
        if (_depositFeeRate > type(uint16).max) revert FeeOverflow();
        if (_withdrawFeeRate > type(uint16).max) revert FeeOverflow();
        if (_bridgeFeeRate > type(uint16).max) revert FeeOverflow();

        depositFeeRate = uint16(_depositFeeRate);
        withdrawFeeRate = uint16(_withdrawFeeRate);
        bridgeFeeRate = uint16(_bridgeFeeRate);

        emit FeeRatesUpdated(_depositFeeRate, _withdrawFeeRate, _bridgeFeeRate);
    }

    function setNFTManager(address nftManager_) external onlyRole(OPERATOR_ROLE) {
        if (nftManager_ == address(0)) revert ZeroAddress();
        _nftManager = nftManager_;
        emit NFTManagerUpdated(nftManager_);
    }

    function setStakingVault(address stakingVault_) external onlyRole(OPERATOR_ROLE) {
        if (stakingVault_ == address(0)) revert ZeroAddress();
        stakingVault = IStakingVault(stakingVault_);
        emit StakingVaultUpdated(stakingVault_);
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
