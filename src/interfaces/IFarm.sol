// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFarm {
    /* ========== Custom Errors ========== */
    error PoolNotExists();
    error PoolNotEnabled();
    error PoolFull();
    error LowPUSD();
    error InactiveStake();
    error ZeroAmount();
    error StillLocked();
    error NotOwner();
    error MaxStakesReached();
    error LowReserve();
    error LengthMismatch();
    error FeeOverflow();
    error BadMultiplier();
    error NameExists();
    error InvalidPeriod();
    error InvalidFeeType();
    error InvalidChain();
    error InvalidAmount();
    error FeeTooHigh();
    error EmptyName();
    error EmptyArrays();
    error BadRecipient();
    error BadAsset();
    error TooSmall();
    error StakeNotActive();
    error PeriodNotFound();
    error OnlyNFTManager();
    error NoStakes();
    error Unauthorized();
    error InvalidConfig();
    error AlreadyActioned();
    error NotEnoughBalance();
    error InvalidIndex();
    error ZeroAddress();
    error CapExceeded();

    /* ========== Structs ========== */

    /* ========== Pool Configuration ========== */
    struct Pool {
        string name;             // Pool name, e.g. "2026Q1-30D"
        uint256 lockPeriod;      // Lock duration in seconds
        uint256 cap;             // Maximum capacity
        uint256 used;            // Cumulative used quota (never decreases)
        uint256 tvl;             // Current total value locked
        uint16 rewardMultiplier; // Reward multiplier (basis points, 10000 = 1.0x)
        bool enabled;            // Whether new stakes are allowed
        uint256 createdAt;       // Creation timestamp (>0 means exists)
    }

    /* ========== User Asset Information ========== */
    struct UserAssetInfo {
        uint256 lastActionTime;
        uint256[] tokenIds;
    }

    /* ========== DAO Staking Pool - Each stake recorded independently ========== */
    struct StakeRecord {
        uint256 poolId;          // Pool ID
        uint256 amount;
        uint256 startTime;
        uint256 lockPeriod;      // Lock duration (redundant for Vault/NFT display)
        uint256 lastClaimTime;
        uint16 rewardMultiplier;
        bool active;
        uint256 pendingReward;
    }

    // Stake detail structure for paginated queries
    struct StakeDetail {
        uint256 tokenId;
        uint256 poolId;          // Pool ID
        string poolName;         // Pool name
        uint256 amount;
        uint256 startTime;
        uint256 lockPeriod;
        uint256 lastClaimTime;
        uint16 rewardMultiplier;
        bool active;
        uint256 currentReward;
        uint256 pendingReward;
        uint256 unlockTime;
        bool isUnlocked;
        uint256 effectiveAPY;
    }

    struct APYRecord {
        uint16 apy;
        uint256 timestamp;
    }
    /* ========== Event Definitions ========== */

    // General asset operation events (deposit/withdraw)
    // true=deposit, false=withdraw
    event AssetOperation(address indexed user, address indexed asset, uint256 amount, uint256 netAmount, bool isDeposit);

    // Fee rate update events
    event FeeRatesUpdated(uint256 depositFee, uint256 withdrawFee, uint256 _bridgeFeeRate);
    // Staking operation events (stake/unstake)
    // true=stake, false=unstake
    event StakeOperation(address indexed user, uint256 tokenId, uint256 amount, uint256 lockPeriod, bool isStake);
    // Staking reward claim events
    event StakeRewardsClaimed(address indexed user, uint256 tokenId, uint256 amount);
    // Base APY update events
    event APYUpdated(uint256 oldAPY, uint256 newAPY, uint256 timestamp);
    // Staking renewal events (renewal/reinvestment)
    // true=compound rewards, false=claim rewards
    event StakeRenewal(address indexed user, uint256 tokenId, uint256 newLockPeriod, uint256 rewardAmount, uint256 newTotalAmount, bool isCompounded);

    // System configuration update events
    event SystemConfigUpdated(uint256 oldMinDeposit, uint256 newMinDeposit, uint256 oldMinLock, uint256 newMinLock, uint256 oldMaxStakes, uint256 newMaxStakes, uint256 oldMaxHistory, uint256 newMaxHistory);

    event NFTManagerUpdated(address indexed nftManager);
    event StakingVaultUpdated(address indexed stakingVault);

    // Pool management events
    event PoolCreated(uint256 indexed poolId, string name, uint256 lockPeriod, uint256 cap);
    event PoolEnabledChanged(uint256 indexed poolId, bool enabled);
    event PoolCapUpdated(uint256 indexed poolId, uint256 oldCap, uint256 newCap);
    event PoolNameUpdated(uint256 indexed poolId, string oldName, string newName);

    // Bridge events
    event BridgePUSDInitiated(uint256 indexed sourceChainId, uint256 indexed destChainId, address indexed from, address to, uint256 totalAmount, uint256 netAmount, uint256 fee);
    event BridgePUSDFinalized(uint256 indexed sourceChainId, uint256 indexed destChainId, address indexed from, address to, uint256 amount, uint256 fee, uint256 nonce);
    event BridgeMessengerUpdated(address indexed oldMessenger, address indexed newMessenger);
    event BridgeChainSupportUpdated(uint256[] chainIds, bool[] isSupported);

    // NFT transfer tracking event
    event StakeNFTTransferred(address indexed from, address indexed to, uint256 indexed tokenId);

    /* ========== Core External Functions ========== */

    function depositAsset(address asset, uint256 amount) external;

    function withdrawAsset(address asset, uint256 pusdAmount) external;

    function stakePUSD(uint256 poolId, uint256 amount) external returns (uint256 tokenId);

    function renewStake(uint256 tokenId, uint256 newPoolId) external;

    function unstakePUSD(uint256 tokenId) external;

    function getStakeInfo(address account, uint256 queryType, uint256 tokenId, uint256 amount) external view returns (uint256 result, string memory reason);

    function setAPY(uint256 newAPY) external;

    function getUserInfo(address user) external view returns (uint256 pusdBalance, uint256 ypusdBalance, uint256 totalStakedAmount, uint256 totalStakeRewards, uint256 activeStakeCount);

    function getStakeDetails(address user, uint256 tokenId) external view returns (StakeRecord memory stakeRecord, uint256 pendingReward, uint256 unlockTime, bool isUnlocked, uint256 remainingTime);

    function getUserStakeDetails(address user, uint256 offset, uint256 limit, bool activeOnly, uint256 lockPeriod) external view returns (StakeDetail[] memory stakeDetails, uint256 totalCount, bool hasMore);

    // Pool management functions
    function createPool(string calldata name, uint256 lockPeriod, uint256 cap, uint16 multiplier) external returns (uint256 poolId);
    function updatePool(uint256 poolId, uint8 fieldType, uint256 value) external;
    function setPoolName(uint256 poolId, string calldata newName) external;

    function updateSystemConfig(uint256 configType, uint256 newValue) external;

    function setFeeRates(uint256 _depositFeeRate, uint256 _withdrawFeeRate, uint256 _bridgeFeeRate) external;

    function onNFTTransfer(address from, address to, uint256 tokenId) external;

    /// @notice Get current base APY in basis points
    function currentAPY() external view returns (uint16);

    function pause() external;

    function unpause() external;
}
