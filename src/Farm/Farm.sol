// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPUSD {
    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function decimals() external view returns (uint8);
}

interface IrPUSD {
    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function totalSupply() external view returns (uint256);
}

interface IVault {
    function depositFor(address user, address asset, uint256 amount) external;

    function withdrawTo(address user, address asset, uint256 amount) external;

    function addFee(address asset, uint256 amount) external;

    function getTVL(
        address asset
    ) external view returns (uint256 tvl, uint256 marketValue);

    function getTotalTVL() external view returns (uint256 totalTVL);

    function getPUSDMarketCap() external view returns (uint256 pusdMarketCap);

    function isValidAsset(address asset) external view returns (bool);

    function getTokenPUSDValue(
        address asset,
        uint256 amount
    ) external view returns (uint256 pusdAmount);

    function getPUSDAssetValue(
        address asset,
        uint256 pusdAmount
    ) external view returns (uint256 amount);
}

/**
 * @title FarmUpgradeable
 * @notice Core Farm contract of Phoenix DeFi system
 * @dev Mining contract specially designed for PUSD/rPUSD ecosystem
 *
 * Core design philosophy:
 * - Only PUSD ↔ rPUSD can be directly exchanged
 * - Other assets → PUSD → rPUSD unidirectional flow
 * - rPUSD yield handled within its own contract; Farm no longer queries dynamic APY for post-expiry stakes
 * - Multi-asset support but unified management
 *
 * Main functions:
 * 1. Multi-asset deposits (USDT/USDC → PUSD)
 * 2. PUSD ↔ rPUSD exchange
 * 3. Staking mining system
 * 4. Automatic yield reinvestment
 * 5. Flexible withdrawal mechanism
 */
contract FarmUpgradeable is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /* ========== Contract Dependencies ========== */

    IPUSD public pusdToken; // PUSD stablecoin contract
    IrPUSD public rpusdToken; // rPUSD yield token contract
    IVault public vault; // Fund vault contract

    /* ========== Permission Roles ========== */

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); // Operations admin role (APY/fees/configuration)

    /* ========== User Asset Information ========== */

    struct UserAssetInfo {
        uint256 totalDeposited; // User total deposited amount (USD denominated)
        uint256 lastActionTime; // Last action time
    }

    /* ========== DAO Staking Pool - Each stake recorded independently ========== */

    struct StakeRecord {
        uint256 amount; // Staking amount
        uint256 startTime; // Staking start time
        uint256 lockPeriod; // Lock period (seconds)
        uint256 lastClaimTime; // Last reward claim time
        uint16 rewardMultiplier; // Reward multiplier for this stake (max 65535)
        bool active; // Whether still active
    }

    // Stake detail structure for paginated queries
    struct StakeDetail {
        uint256 stakeId; // Stake record ID
        uint256 amount; // Staking amount
        uint256 startTime; // Staking start time
        uint256 lockPeriod; // Lock period (seconds)
        uint256 lastClaimTime; // Last claim time
        uint16 rewardMultiplier; // Reward multiplier (max 65535)
        bool active; // Whether still active
        uint256 currentReward; // Current pending reward
        uint256 unlockTime; // Unlock time
        bool isUnlocked; // Whether unlocked
        uint256 effectiveAPY; // Effective annual percentage yield (basis points)
    }

    // User address => Array of staking records
    mapping(address => StakeRecord[]) public userStakeRecords;

    mapping(address => UserAssetInfo) public userAssets;

    /* ========== Fee Settings ========== */

    uint16 public depositFeeRate = 0; // Deposit fee rate (basis points, 0 = 0%, max 65535)
    uint16 public withdrawFeeRate = 50; // Withdrawal fee rate (basis points, 50 = 0.5%, max 65535)

    uint256 public minDepositAmount = 10 * 10 ** 6; // Minimum deposit amount (USD, configurable)

    /* ========== Statistics ========== */

    uint256 public totalUsers; // Total number of users
    uint256 public totalVolumeUSD; // Total transaction volume (USD)

    mapping(address => uint256) public assetTotalDeposits; // Total deposits per asset

    /* ========== Staking Mining System ========== */

    uint256 public totalStaked; // Total staked amount
    uint256 public minLockAmount = 100; // Minimum staking amount (PUSD, configurable)

    /* ========== APY History System ========== */

    uint16 public currentAPY; // Current annual percentage yield (basis points, 2000 = 20%, max 65535)

    // APY history records for snapshot-style yield calculation
    struct APYRecord {
        uint16 apy; // APY value (basis points, max 65535)
        uint256 timestamp; // Effective time
    }

    APYRecord[] public apyHistory; // APY change history
    uint16 public maxAPYHistory = 1000; // Maximum history record count (configurable, max 65535)

    /* ========== Staking Multiplier Configuration System ========== */

    // Multiplier configuration for different lock periods (dynamically adjustable)
    mapping(uint256 => uint16) public lockPeriodMultipliers;

    // Array of supported lock periods
    uint256[] public supportedLockPeriods;

    /* ========== Storage Optimization Configuration ========== */
    uint16 public maxStakesPerUser = 1000; // Maximum stakes per user (configurable, max 65535)

    /* ========== Pool TVL Tracking ========== */
    mapping(uint256 => uint256) public poolTVL; // Total locked value per lock period

    // Reserved upgrade space
    uint256[39] private __gap;

    /* ========== Event Definitions ========== */

    // General asset operation events (deposit/withdraw)
    // true=deposit, false=withdraw
    event AssetOperation(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 netAmount,
        bool isDeposit
    );
    // Token exchange events (PUSD ↔ rPUSD)
    // true=PUSD→rPUSD, false=rPUSD→PUSD
    event TokenExchange(
        address indexed user,
        uint256 fromAmount,
        uint256 toAmount,
        bool isPUSDToRPUSD
    );

    // Fee rate update events
    event FeeRatesUpdated(uint256 depositFee, uint256 withdrawFee);
    // Staking operation events (stake/unstake)
    // true=stake, false=unstake
    event StakeOperation(
        address indexed user,
        uint256 stakeId,
        uint256 amount,
        uint256 lockPeriod,
        bool isStake
    );
    // Staking reward claim events
    event StakeRewardsClaimed(
        address indexed user,
        uint256 stakeId,
        uint256 amount
    );
    // Base APY update events
    event APYUpdated(uint256 oldAPY, uint256 newAPY, uint256 timestamp);
    // Staking renewal events (renewal/reinvestment)
    // true=compound rewards, false=claim rewards
    event StakeRenewal(
        address indexed user,
        uint256 stakeId,
        uint256 newLockPeriod,
        uint256 rewardAmount,
        uint256 newTotalAmount,
        bool isCompounded
    );

    // System configuration update events
    event SystemConfigUpdated(
        uint256 oldMinDeposit,
        uint256 newMinDeposit,
        uint256 oldMinLock,
        uint256 newMinLock,
        uint256 oldMaxStakes,
        uint256 newMaxStakes,
        uint256 oldMaxHistory,
        uint256 newMaxHistory
    );

    // Multiplier configuration events
    event MultiplierUpdated(
        uint256 indexed lockPeriod,
        uint16 oldMultiplier,
        uint16 newMultiplier
    );
    event LockPeriodAdded(uint256 indexed lockPeriod, uint16 multiplier);
    event LockPeriodRemoved(uint256 indexed lockPeriod);

    /* ========== Constructor and Initialization ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize Farm contract
     * @param admin Administrator address
     * @param _pusdToken PUSD token contract address
     * @param _rpusdToken rPUSD token contract address
     * @param _vault Vault contract address
     */
    function initialize(
        address admin,
        address _pusdToken,
        address _rpusdToken,
        address _vault
    ) public initializer {
        require(admin != address(0), "Invalid admin address");
        require(_pusdToken != address(0), "Invalid PUSD address");
        require(_rpusdToken != address(0), "Invalid rPUSD address");
        require(_vault != address(0), "Invalid vault address");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin); // Grant operations management permissions (APY/fees/configuration)

        pusdToken = IPUSD(_pusdToken);
        rpusdToken = IrPUSD(_rpusdToken);
        vault = IVault(_vault);

        // Initialize staking mining system
        currentAPY = 2000; // Initial APY 20% (2000 basis points)

        // Initialize APY history
        apyHistory.push(
            APYRecord({apy: currentAPY, timestamp: block.timestamp})
        );
    }

    /* ========== Core Business Functions ========== */

    /**
     * @notice Deposit assets to get PUSD
     * @dev Support multiple asset deposits, automatically convert to PUSD
     * @param asset Asset address
     * @param amount Deposit amount
     */
    function depositAsset(
        address asset,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        require(vault.isValidAsset(asset), "Unsupported asset");
        // Here amount is asset quantity, not USD, need to convert to pusd amount
        uint256 pusdAmount = vault.getTokenPUSDValue(asset, amount);
        require(pusdAmount > 0, "Invalid deposit amount");

        require(
            pusdAmount >= minDepositAmount * (10 ** pusdToken.decimals()),
            "Amount below minimum"
        );

        // Calculate fee
        uint256 fee = (amount * depositFeeRate) / 10000;
        uint256 netPUSD = pusdAmount - (pusdAmount * depositFeeRate) / 10000;

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
    function withdrawAsset(
        address asset,
        uint256 pusdAmount
    ) external nonReentrant whenNotPaused {
        require(vault.isValidAsset(asset), "Unsupported asset");
        require(pusdAmount > 0, "Amount must be greater than 0");

        // Check user PUSD balance
        require(
            pusdToken.balanceOf(msg.sender) >= pusdAmount,
            "Insufficient PUSD balance"
        );

        // Calculate required asset amount for withdrawal (reverse calculation through Oracle)
        uint256 assetAmount = vault.getPUSDAssetValue(asset, pusdAmount);
        require(assetAmount > 0, "Invalid withdrawal amount");

        // Check if Vault has sufficient asset balance
        (uint256 vaultBalance, ) = vault.getTVL(asset);
        require(vaultBalance >= assetAmount, "Insufficient vault balance");

        UserAssetInfo storage userInfo = userAssets[msg.sender];

        // Calculate withdrawal fee (based on PUSD amount)
        uint256 pusdFee = (pusdAmount * withdrawFeeRate) / 10000;
        uint256 assetFee = vault.getPUSDAssetValue(asset, pusdFee);
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
     * @notice Exchange PUSD to rPUSD
     * @dev 1:1 exchange, rPUSD automatically generates 8% APY yield
     * Farm contract directly handles exchange logic to avoid complex inter-contract calls
     * @param pusdAmount PUSD amount
     */
    function exchangePUSDToRPUSD(
        uint256 pusdAmount
    ) external nonReentrant whenNotPaused {
        require(pusdAmount > 0, "Amount must be greater than 0");

        // Check user PUSD balance
        require(
            pusdToken.balanceOf(msg.sender) >= pusdAmount,
            "Insufficient PUSD balance"
        );

        // Farm directly handles exchange: 1. Burn PUSD, 2. Mint rPUSD
        pusdToken.burn(msg.sender, pusdAmount);
        rpusdToken.mint(msg.sender, pusdAmount); // 1:1 exchange

        // Update user statistics
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        userInfo.lastActionTime = block.timestamp;

        // Update transaction volume statistics
        totalVolumeUSD += pusdAmount;

        emit TokenExchange(msg.sender, pusdAmount, pusdAmount, true);
    }

    /**
     * @notice Exchange rPUSD to PUSD
     * @dev Exchange rPUSD including yield back to PUSD
     * Farm contract directly handles exchange logic ensuring separation of responsibilities
     * @param rpusdAmount rPUSD amount
     */
    function exchangeRPUSDToPUSD(
        uint256 rpusdAmount
    ) external nonReentrant whenNotPaused {
        require(rpusdAmount > 0, "Amount must be greater than 0");

        // Check user rPUSD balance
        require(
            rpusdToken.balanceOf(msg.sender) >= rpusdAmount,
            "Insufficient rPUSD balance"
        );

        // Farm directly handles exchange: 1. Burn rPUSD, 2. Mint PUSD
        rpusdToken.burn(msg.sender, rpusdAmount);
        pusdToken.mint(msg.sender, rpusdAmount); // 1:1 exchange

        // Update user statistics
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        userInfo.lastActionTime = block.timestamp;

        // Update transaction volume statistics
        totalVolumeUSD += rpusdAmount;

        emit TokenExchange(msg.sender, rpusdAmount, rpusdAmount, false);
    }

    /**
     * @notice Stake PUSD to earn mining rewards (DAO pool mode)
     * @dev Each stake recorded independently; rewards accrue ONLY during the lock period (no post-expiry yield)
     * @param amount Amount of PUSD to stake
     * @param lockPeriod Lock period (5-180 days)
     * @return stakeId Record ID for this stake
     */
    function stakePUSD(
        uint256 amount,
        uint256 lockPeriod
    ) external nonReentrant whenNotPaused returns (uint256 stakeId) {
        require(
            amount >= minLockAmount * (10 ** pusdToken.decimals()),
            "Stake amount too small"
        );

        // Verify if lock period is supported
        require(
            lockPeriodMultipliers[lockPeriod] > 0,
            "Unsupported lock period"
        );

        // Check user PUSD balance
        require(
            pusdToken.balanceOf(msg.sender) >= amount,
            "Insufficient PUSD balance"
        );

        // Check if user has authorized sufficient PUSD to Farm contract
        require(
            IERC20(address(pusdToken)).allowance(msg.sender, address(this)) >=
                amount,
            "Insufficient PUSD allowance. Please approve Farm contract first"
        );

        // Directly burn PUSD from user address to avoid contract token holding risks
        pusdToken.burn(msg.sender, amount);

        // Set reward multiplier based on lock period
        uint16 multiplier = lockPeriodMultipliers[lockPeriod];

        // Try to reuse an inactive stake slot first
        StakeRecord[] storage stakes = userStakeRecords[msg.sender];
        stakeId = type(uint256).max; // Use max value to indicate not found

        for (uint256 i = 0; i < stakes.length; i++) {
            if (!stakes[i].active) {
                // Reuse this inactive slot
                stakes[i] = StakeRecord({
                    amount: amount,
                    startTime: block.timestamp,
                    lockPeriod: lockPeriod,
                    lastClaimTime: block.timestamp,
                    rewardMultiplier: multiplier,
                    active: true
                });
                stakeId = i;
                break;
            }
        }

        // If no inactive slot found, create new record
        if (stakeId == type(uint256).max) {
            // Check user stake quantity limit only when creating new slot
            require(
                stakes.length < maxStakesPerUser,
                "Maximum active stakes reached. Please unstake an existing position first or use a different address"
            );

            stakes.push(
                StakeRecord({
                    amount: amount,
                    startTime: block.timestamp,
                    lockPeriod: lockPeriod,
                    lastClaimTime: block.timestamp,
                    rewardMultiplier: multiplier,
                    active: true
                })
            );
            stakeId = stakes.length - 1;
        }

        // Update total staked amount
        totalStaked += amount;

        // Update pool TVL
        poolTVL[lockPeriod] += amount;

        // Update user operation time
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        userInfo.lastActionTime = block.timestamp;

        emit StakeOperation(msg.sender, stakeId, amount, lockPeriod, true);
    }

    /**
     * @notice Renew stake
     * @dev After stake unlock, can choose new lock period to continue staking
     * @param stakeId Stake record ID to renew
     * @param compoundRewards Whether to compound rewards into stake
     */
    function renewStake(
        uint256 stakeId,
        bool compoundRewards
    ) external nonReentrant whenNotPaused {
        require(
            stakeId < userStakeRecords[msg.sender].length,
            "Invalid stake ID"
        );

        StakeRecord storage stakeRecord = userStakeRecords[msg.sender][stakeId];
        require(stakeRecord.active, "Stake record not found or inactive");
        require(
            block.timestamp >= stakeRecord.startTime + stakeRecord.lockPeriod,
            "Still in lock period"
        );

        // Call internal function directly to avoid code duplication
        _executeRenewal(stakeId, compoundRewards);
    }

    /**
     * @notice Internal function to execute renewal
     * @dev Core logic extracted from renewStake to avoid code duplication
     */
    function _executeRenewal(uint256 stakeId, bool compoundRewards) internal {
        StakeRecord storage stakeRecord = userStakeRecords[msg.sender][stakeId];

        // Calculate rewards for this stake
        uint256 reward = _calculateStakeReward(stakeRecord);

        if (reward > 0) {
            if (compoundRewards) {
                // Compounding mode: directly add rewards to stake principal
                stakeRecord.amount += reward;
                emit StakeRenewal(
                    msg.sender,
                    stakeId,
                    stakeRecord.lockPeriod,
                    reward,
                    stakeRecord.amount,
                    true
                );
            } else {
                // Traditional mode: distribute rewards to user
                rpusdToken.mint(msg.sender, reward);
                emit StakeRewardsClaimed(msg.sender, stakeId, reward);
            }
        }

        // Reset stake record for new lock period
        stakeRecord.startTime = block.timestamp;
        stakeRecord.lastClaimTime = block.timestamp;
        stakeRecord.rewardMultiplier = lockPeriodMultipliers[
            stakeRecord.lockPeriod
        ];

        // Update user operation time
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        userInfo.lastActionTime = block.timestamp;

        emit StakeRenewal(
            msg.sender,
            stakeId,
            stakeRecord.lockPeriod,
            reward,
            stakeRecord.amount,
            false
        );
    }

    /**
     * @notice Cancel PUSD stake
     * @dev Can only unstake after lock period expires, zero fees
     * @param amount Amount of PUSD to unstake
     */
    /**
     * @notice Cancel PUSD stake (DAO pool mode)
     * @dev Cancel specific stake based on stake record ID
     * @param stakeId Stake record ID to cancel
     */
    function unstakePUSD(uint256 stakeId) external nonReentrant whenNotPaused {
        require(
            stakeId < userStakeRecords[msg.sender].length,
            "Invalid stake ID"
        );

        StakeRecord storage stakeRecord = userStakeRecords[msg.sender][stakeId];
        require(stakeRecord.active, "Stake record not found or inactive");
        require(
            block.timestamp >= stakeRecord.startTime + stakeRecord.lockPeriod,
            "Still in lock period"
        );

        uint256 amount = stakeRecord.amount;

        // Calculate and distribute rewards for this stake
        uint256 reward = _calculateStakeReward(stakeRecord);
        if (reward > 0) {
            // Directly mint rPUSD as rewards to user
            rpusdToken.mint(msg.sender, reward);
            emit StakeRewardsClaimed(msg.sender, stakeId, reward);
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

        // Directly mint full PUSD amount to user (zero fees)
        pusdToken.mint(msg.sender, amount);

        // Update user operation time
        UserAssetInfo storage userInfo = userAssets[msg.sender];
        userInfo.lastActionTime = block.timestamp;

        emit StakeOperation(msg.sender, stakeId, amount, 0, false);
    }

    /**
     * @notice Claim rewards for specific stake record
     * @dev Rewards accrue only until unlock; claiming after unlock does not add extra yield
     * @param stakeId Stake record ID
     */
    function claimStakeRewards(
        uint256 stakeId
    ) external nonReentrant whenNotPaused {
        require(
            stakeId < userStakeRecords[msg.sender].length,
            "Invalid stake ID"
        );

        StakeRecord storage stakeRecord = userStakeRecords[msg.sender][stakeId];
        require(stakeRecord.active, "Stake record not found or inactive");

        // Calculate rewards (from last claim time to now)
        uint256 pendingReward = _calculateStakeReward(stakeRecord);
        require(pendingReward > 0, "No rewards to claim");
        // Update last claim time
        stakeRecord.lastClaimTime = block.timestamp;

        // Directly mint rPUSD as rewards to user
        rpusdToken.mint(msg.sender, pendingReward);

        emit StakeRewardsClaimed(msg.sender, stakeId, pendingReward);
    }

    /**
     * @notice Claim rewards for all active stakes at once
     * @dev Batch claim current available rewards for all user's active stake records
     * @return totalReward Total amount of rewards claimed
     */
    function claimAllStakeRewards()
        external
        nonReentrant
        whenNotPaused
        returns (uint256 totalReward)
    {
        StakeRecord[] storage stakes = userStakeRecords[msg.sender];
        require(stakes.length > 0, "No stake records found");

        totalReward = 0;

        // Iterate through all stake records to claim rewards
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].active) {
                uint256 reward = _calculateStakeReward(stakes[i]);
                if (reward > 0) {
                    // Update last claim time
                    stakes[i].lastClaimTime = block.timestamp;
                    totalReward += reward;

                    emit StakeRewardsClaimed(msg.sender, i, reward);
                }
            }
        }

        require(totalReward > 0, "No rewards to claim");

        // Directly mint rPUSD as rewards to user
        rpusdToken.mint(msg.sender, totalReward);
    }

    /**
     * @notice Unified stake query function (merged version)
     * @param account User address
     * @param queryType Query type: 0-total rewards, 1-specific ID rewards, 2-allowance amount, 3-stake validation
     * @param stakeId Stake record ID (used when queryType=1)
     * @param amount Stake amount (used when queryType=3)
     * @return result Query result
     * @return reason Validation failure reason (used when queryType=3)
     */
    function getStakeInfo(
        address account,
        uint256 queryType,
        uint256 stakeId,
        uint256 amount
    ) external view returns (uint256 result, string memory reason) {
        if (queryType == 0) {
            // Get total rewards
            StakeRecord[] storage stakes = userStakeRecords[account];
            uint256 totalRewards = 0;
            for (uint256 i = 0; i < stakes.length; i++) {
                if (stakes[i].active) {
                    totalRewards += _calculateStakeReward(stakes[i]);
                }
            }
            return (totalRewards, "");
        } else if (queryType == 1) {
            // Get specific ID rewards
            StakeRecord storage stakeRecord = userStakeRecords[account][
                stakeId
            ];
            if (!stakeRecord.active) return (0, "");
            return (_calculateStakeReward(stakeRecord), "");
        } else if (queryType == 2) {
            // Get allowance amount
            return (
                IERC20(address(pusdToken)).allowance(account, address(this)),
                ""
            );
        } else if (queryType == 3) {
            // Validate if staking is possible
            if (amount < minLockAmount * (10 ** pusdToken.decimals())) {
                return (0, "Amount below minimum lock amount");
            }
            if (pusdToken.balanceOf(account) < amount) {
                return (0, "Insufficient PUSD balance");
            }
            if (
                IERC20(address(pusdToken)).allowance(account, address(this)) <
                amount
            ) {
                return (0, "Insufficient PUSD allowance");
            }
            return (1, "");
        }
        return (0, "Invalid query type");
    }

    /* ========== APY Management Functions ========== */

    /**
     * @notice Set new APY (supports historical records)
     * @param newAPY New annual percentage yield (basis points, 1500 = 15%)
     */
    function setAPY(uint256 newAPY) external onlyRole(OPERATOR_ROLE) {
        require(newAPY <= type(uint16).max, "APY exceeds uint16 max");
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
    function _calculateStakeReward(
        StakeRecord storage stakeRecord
    ) internal view returns (uint256) {
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

        return
            _calculateRewardWithHistory(
                stakeRecord.amount,
                stakeRecord.lastClaimTime,
                effectiveEnd,
                stakeRecord.rewardMultiplier
            );
    }

    /**
     * @notice Calculate yield for specified time period based on APY history (snapshot method, supports external data sources)
     * @param amount Stake amount
     * @param fromTime Start time
     * @param toTime End time
     * @param multiplier Reward multiplier
     * @return Calculated yield
     */
    function _calculateRewardWithHistory(
        uint256 amount,
        uint256 fromTime,
        uint256 toTime,
        uint16 multiplier
    ) internal view returns (uint256) {
        if (fromTime >= toTime || amount == 0) {
            return 0;
        }

        uint256 totalReward = 0;
        uint256 currentTime = fromTime;

        // Iterate through APY history records, calculate yield in segments
        for (
            uint256 i = 0;
            i < apyHistory.length && currentTime < toTime;
            i++
        ) {
            APYRecord memory record = apyHistory[i];

            // If this APY record is within our time range
            if (record.timestamp > currentTime) {
                // Calculate yield to next APY change point or end time
                uint256 segmentEndTime = record.timestamp > toTime
                    ? toTime
                    : record.timestamp;
                uint256 segmentDuration = segmentEndTime - currentTime;

                // Get APY effective for current time segment: if first record, use initial APY; otherwise use previous record's APY
                uint256 segmentAPY = (i == 0)
                    ? apyHistory[0].apy
                    : apyHistory[i - 1].apy;

                // Calculate yield for this segment
                uint256 segmentReward = _calculateSegmentReward(
                    amount,
                    segmentAPY,
                    segmentDuration,
                    multiplier
                );
                totalReward += segmentReward;
                currentTime = segmentEndTime;
            }
        }

        // Handle final segment (using current APY)
        if (currentTime < toTime) {
            uint256 finalDuration = toTime - currentTime;
            uint256 finalReward = _calculateSegmentReward(
                amount,
                currentAPY,
                finalDuration,
                multiplier
            );
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
    function _calculateSegmentReward(
        uint256 amount,
        uint256 apy,
        uint256 duration,
        uint16 multiplier
    ) internal pure returns (uint256) {
        if (duration == 0 || amount == 0) {
            return 0;
        }

        // Apply multiplier to get effective APY (cast to prevent overflow)
        uint256 effectiveAPY = (apy * uint256(multiplier)) / 10000;

        // Convert basis points to decimal with precision
        uint256 precision = 1e18;
        // percentage = effectiveAPY / 10000
        uint256 annualRate = (effectiveAPY * precision) / 10000;

        // Calculate hourly rate for better precision
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
    function getSupportedLockPeriodsWithMultipliers()
        external
        view
        returns (uint256[] memory lockPeriods, uint16[] memory multipliers)
    {
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
     * @return rpusdBalance User rPUSD balance
     * @return totalDeposited Total deposited amount
     * @return totalStakedAmount Total staked amount
     * @return totalStakeRewards Total pending rewards
     * @return activeStakeCount Active stake record count
     */
    function getUserInfo(
        address user
    )
        external
        view
        returns (
            uint256 pusdBalance,
            uint256 rpusdBalance,
            uint256 totalDeposited,
            uint256 totalStakedAmount,
            uint256 totalStakeRewards,
            uint256 activeStakeCount
        )
    {
        UserAssetInfo storage info = userAssets[user];

        // Calculate total amount and rewards for all active stakes
        StakeRecord[] storage stakes = userStakeRecords[user];
        uint256 _totalStakedAmount = 0;
        uint256 _totalStakeRewards = 0;
        uint256 _activeStakeCount = 0;

        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].active) {
                _totalStakedAmount += stakes[i].amount;
                _totalStakeRewards += _calculateStakeReward(stakes[i]);
                _activeStakeCount++;
            }
        }

        return (
            pusdToken.balanceOf(user), // Query real balance from PUSD contract
            rpusdToken.balanceOf(user), // Query real balance from rPUSD contract
            info.totalDeposited,
            _totalStakedAmount,
            _totalStakeRewards,
            _activeStakeCount
        );
    }

    /**
     * @notice Get detailed information for user's specific stake record
     * @param user User address
     * @param stakeId Stake record ID
     * @return stakeRecord Stake record details
     * @return pendingReward Pending rewards
     * @return unlockTime Unlock time
     * @return isUnlocked Whether already unlocked
     * @return remainingTime Remaining lock time
     */
    function getStakeDetails(
        address user,
        uint256 stakeId
    )
        external
        view
        returns (
            StakeRecord memory stakeRecord,
            uint256 pendingReward,
            uint256 unlockTime,
            bool isUnlocked,
            uint256 remainingTime
        )
    {
        stakeRecord = userStakeRecords[user][stakeId];
        require(stakeRecord.active, "Stake record not found or inactive");

        // Calculate rewards using snapshot method
        pendingReward = _calculateRewardWithHistory(
            stakeRecord.amount,
            stakeRecord.lastClaimTime,
            block.timestamp,
            stakeRecord.rewardMultiplier
        );

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
    function getUserStakeDetails(
        address user,
        uint256 offset,
        uint256 limit,
        bool activeOnly,
        uint256 lockPeriod
    )
        external
        view
        returns (
            StakeDetail[] memory stakeDetails,
            uint256 totalCount,
            bool hasMore
        )
    {
        StakeRecord[] storage stakes = userStakeRecords[user];

        // Limit single query quantity to prevent gas overflow
        if (limit > 50) limit = 50;

        // First calculate qualifying record count and positions
        uint256[] memory validIndices = new uint256[](stakes.length);
        uint256 validCount = 0;

        for (uint256 i = 0; i < stakes.length; i++) {
            // Apply filters: activeOnly and lockPeriod
            bool matchesActiveFilter = !activeOnly || stakes[i].active;
            bool matchesLockPeriodFilter = lockPeriod == 0 ||
                stakes[i].lockPeriod == lockPeriod;

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
            StakeRecord storage record = stakes[stakeIndex];

            stakeDetails[i] = StakeDetail({
                stakeId: stakeIndex,
                amount: record.amount,
                startTime: record.startTime,
                lockPeriod: record.lockPeriod,
                lastClaimTime: record.lastClaimTime,
                rewardMultiplier: record.rewardMultiplier,
                active: record.active,
                currentReward: record.active
                    ? _calculateStakeReward(record)
                    : 0,
                unlockTime: record.startTime + record.lockPeriod,
                isUnlocked: block.timestamp >=
                    record.startTime + record.lockPeriod,
                effectiveAPY: (uint256(currentAPY) *
                    uint256(record.rewardMultiplier)) / 10000
            });
        }

        hasMore = endIndex < totalCount;
    }

    /**
     * @notice Get system health status details
     * @return totalTVL Vault total locked value
     * @return totalPUSDMarketCap PUSD total market cap
     
     */
    //  * @return tvlUtilization TVL utilization (PUSD supply/TVL ratio)
    //  * @return avgDepositPerUser Average deposit per user
    //  * @return pusdSupply PUSD total supply
    //  * @return rpusdSupply rPUSD total supply
    function getSystemHealth()
        external
        view
        returns (uint256 totalTVL, uint256 totalPUSDMarketCap)
    {
        // Get basic data
        // Get Vault's total TVL
        try vault.getTotalTVL() returns (uint256 tvl) {
            totalTVL = tvl;
        } catch {
            totalTVL = 0;
        }

        // Get total PUSD market cap
        try vault.getPUSDMarketCap() returns (uint256 marketCap) {
            totalPUSDMarketCap = marketCap;
        } catch {
            totalPUSDMarketCap = 0;
        }

        return (totalTVL, totalPUSDMarketCap);
    }

    /* ========== Admin Functions ========== */

    /* ========== Multiplier Configuration Management ========== */
    /**
     * @notice Batch set lock period multipliers
     * @dev Multiplier is in basis points (10000 = 1.00x, 15000 = 1.50x, 50000 = 5.00x)
     *      The actual effective APY = base APY × (multiplier / 10000)
     *      For example: base APY 20% (2000 bps), multiplier 15000 (1.5x) → effective APY = 30%
     * @param lockPeriods Array of lock periods (in seconds)
     * @param multipliers Array of corresponding multipliers (basis points, range: 5000-50000, i.e., 0.5x-5.0x)
     */
    function batchSetLockPeriodMultipliers(
        uint256[] calldata lockPeriods,
        uint16[] calldata multipliers
    ) external onlyRole(OPERATOR_ROLE) {
        require(
            lockPeriods.length == multipliers.length,
            "Array length mismatch"
        );
        require(lockPeriods.length > 0, "Empty arrays");

        for (uint256 i = 0; i < lockPeriods.length; i++) {
            require(lockPeriods[i] > 0, "Invalid lock period");
            require(multipliers[i] >= 5000, "Multiplier out of range");

            uint16 oldMultiplier = lockPeriodMultipliers[lockPeriods[i]];

            if (oldMultiplier == 0) {
                supportedLockPeriods.push(lockPeriods[i]);
                emit LockPeriodAdded(lockPeriods[i], multipliers[i]);
            } else {
                emit MultiplierUpdated(
                    lockPeriods[i],
                    oldMultiplier,
                    multipliers[i]
                );
            }

            lockPeriodMultipliers[lockPeriods[i]] = multipliers[i];
        }
    }

    /**
     * @notice Remove lock period configuration
     * @param lockPeriod Lock period to remove
     */
    function removeLockPeriod(
        uint256 lockPeriod
    ) external onlyRole(OPERATOR_ROLE) {
        require(lockPeriodMultipliers[lockPeriod] > 0, "Lock period not found");

        // Remove from array
        for (uint256 i = 0; i < supportedLockPeriods.length; i++) {
            if (supportedLockPeriods[i] == lockPeriod) {
                // Move last element to current position, then delete last element
                supportedLockPeriods[i] = supportedLockPeriods[
                    supportedLockPeriods.length - 1
                ];
                supportedLockPeriods.pop();
                break;
            }
        }

        delete lockPeriodMultipliers[lockPeriod];
        emit LockPeriodRemoved(lockPeriod);
    }

    /* ========== System Configuration Management ========== */

    /**
     * @notice Unified configuration management function (merged version)
     * @param configType Configuration type: 0-minimum deposit, 1-minimum stake, 2-max stakes, 3-max APY history
     * @param newValue New value
     */
    function updateSystemConfig(
        uint256 configType,
        uint256 newValue
    ) external onlyRole(OPERATOR_ROLE) {
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
            require(
                newValue >= 10 && newValue <= 65535,
                "Invalid max stakes per user"
            );
            maxStakesPerUser = uint16(newValue);
        } else if (configType == 3) {
            require(
                newValue >= 50 && newValue <= 65535,
                "Invalid max APY history"
            );
            maxAPYHistory = uint16(newValue);
        } else {
            revert("Invalid config type");
        }
    }

    /* ========== Admin Functions ========== */

    /**
     * @notice Set fee rates
     * @param _depositFeeRate Deposit fee rate
     * @param _withdrawFeeRate Withdrawal fee rate
     */
    function setFeeRates(
        uint256 _depositFeeRate,
        uint256 _withdrawFeeRate
    ) external onlyRole(OPERATOR_ROLE) {
        require(
            _depositFeeRate <= type(uint16).max,
            "Deposit fee exceeds uint16 max"
        );
        require(
            _withdrawFeeRate <= type(uint16).max,
            "Withdraw fee exceeds uint16 max"
        );
        depositFeeRate = uint16(_depositFeeRate);
        withdrawFeeRate = uint16(_withdrawFeeRate);

        emit FeeRatesUpdated(_depositFeeRate, _withdrawFeeRate);
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
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin privileges are sufficient, no additional validation needed
    }
}
