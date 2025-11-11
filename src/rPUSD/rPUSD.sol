// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title rPUSDUpgradeable - Shared Active Yield Token
 * @notice All users share the same active yield rate, implementing:
 *         - Auto-compounding yield token
 *         - Global unified active yield rate (e.g., 8% APY)
 *         - Auto-growing balance (no manual refresh needed)
 *         - Extremely low gas fees (lazy minting mode)
 *         - 6 decimal precision
 * @dev Uses global yield rate design:
 *      - All users enjoy the same globalActiveAPY
 *      - Virtual balance = Base balance + Time-based yield
 *      - Lazy minting: Only mint actual yields during transfers/exchanges
 */
contract rPUSDUpgradeable is
    Initializable,
    ERC20Upgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    /* ========== Role Definitions ========== */
    // Reward management role (mint/burn permissions)
    bytes32 public constant REWARD_MANAGER_ROLE =
        keccak256("REWARD_MANAGER_ROLE");
    // APY management role (only APY adjustment)
    bytes32 public constant APY_MANAGER_ROLE = keccak256("APY_MANAGER_ROLE");
    // Upgrade management role
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    // Pause management role
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /* ========== Constant Definitions ========== */
    uint256 private constant BASIS_POINTS = 10000; // APY basis points calculation
    uint256 private constant SECONDS_PER_YEAR = 365 days; // Seconds per year
    uint256 private constant MAX_TIME_SPAN = 3650 days; // Maximum time span (10 years)
    uint256 private constant MAX_APY = 5000; // Maximum APY: 50%

    /* ========== Core State Variables ========== */
    // Note: Storage slots are automatically allocated after all parent contracts (ERC20, AccessControl, etc.)

    mapping(address => uint64) private userAccountsLastUpdate; // User account mapping (internal use)

    // Global yield configuration
    uint16 public globalActiveAPY; // Global active annual percentage yield (1 basis point = 0.01%, max 65535 = 655.35%)

    // Statistics
    uint256 public totalRewardAccrued; // Total accrued rewards

    // Lock status for REWARD_MANAGER_ROLE: once set to true, can never be modified
    bool public rewardManagerRoleLocked;

    /**
     * @dev Reserve 49 storage slots for future upgrades (1 slot used by rewardManagerRoleLocked)
     *      This is a best practice for UUPS upgrade pattern to ensure no storage conflicts during upgrades
     */
    uint256[49] private __gap;

    /* ========== Event Definitions ========== */
    event RewardRealized(address indexed user, uint256 amount);
    event RewardSkipped(address indexed user, uint256 amount, string reason);
    event APYUpdated(uint256 indexed newActiveAPY);
    event RewardManagerRoleLocked(
        address indexed manager,
        address indexed admin
    );

    /* ========== Constructor ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== Initialization Function ========== */

    /**
     * @dev Initialization function
     * @param _admin Administrator address
     * @param _activeAPY Initial active annual percentage yield (basis points)
     */
    function initialize(
        address _admin,
        uint256 _activeAPY
    ) external initializer {
        require(_admin != address(0), "Invalid admin address");
        require(_activeAPY > 0, "APY must be positive"); // Prevent 0% initialization
        require(_activeAPY <= MAX_APY, "APY too high"); // Maximum 50%

        // Initialize parent contracts
        __ERC20_init("Reward PUSD", "rPUSD");
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Set state variables
        require(_activeAPY <= type(uint16).max, "APY exceeds uint16 max");
        globalActiveAPY = uint16(_activeAPY);
        totalRewardAccrued = 0; // Explicitly initialize statistics variables

        // Assign roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(APY_MANAGER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);
    }

    /**
     * @dev Override grantRole function to ensure REWARD_MANAGER_ROLE can only be granted once
     * Once REWARD_MANAGER_ROLE is granted, rewardManagerRoleLocked will be set to true,
     * after which no one (including DEFAULT_ADMIN_ROLE) can grant or revoke REWARD_MANAGER_ROLE again
     */
    function grantRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (role == REWARD_MANAGER_ROLE) {
            require(
                !rewardManagerRoleLocked,
                "rPUSD: REWARD_MANAGER_ROLE permanently locked"
            );

            // Check if role is already granted (for upgrade compatibility)
            bool alreadyHasRole = hasRole(role, account);

            if (!alreadyHasRole) {
                // Execute normal role granting
                super.grantRole(role, account);
            }

            // Permanently lock REWARD_MANAGER_ROLE, cannot be modified thereafter
            rewardManagerRoleLocked = true;
            emit RewardManagerRoleLocked(account, msg.sender);
        } else {
            // Handle other roles normally
            super.grantRole(role, account);
        }
    }

    /**
     * @dev Override revokeRole function to prevent revoking locked REWARD_MANAGER_ROLE
     * Even DEFAULT_ADMIN_ROLE cannot revoke a locked REWARD_MANAGER_ROLE
     */
    function revokeRole(
        bytes32 role,
        address account
    ) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (role == REWARD_MANAGER_ROLE && rewardManagerRoleLocked) {
            revert("rPUSD: Cannot revoke locked REWARD_MANAGER_ROLE");
        }

        super.revokeRole(role, account);
    }

    /**
     * @dev Override renounceRole function to prevent holders from renouncing locked REWARD_MANAGER_ROLE
     * Even the REWARD_MANAGER_ROLE holder cannot voluntarily renounce the role
     */
    function renounceRole(bytes32 role, address account) public override {
        if (role == REWARD_MANAGER_ROLE && rewardManagerRoleLocked) {
            revert("rPUSD: Cannot renounce locked REWARD_MANAGER_ROLE");
        }

        super.renounceRole(role, account);
    }

    /**
     * @dev Upgrade authorization check
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    /**
     * @dev Override decimals function, fixed to 6 decimal places
     * @return Token decimal places (6 digits, consistent with PUSD)
     */
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    /* ========== Core Virtual Balance System ========== */

    /**
     * @notice Get user balance (standard ERC20 balance + accrued rewards)
     * @dev User-visible balance grows automatically without manual refresh
     * @param account User address
     * @return Total balance (minted tokens + accrued rewards)
     */
    function balanceOf(address account) public view override returns (uint256) {
        // Get minted token balance
        uint256 mintedBalance = super.balanceOf(account);
        if (mintedBalance == 0) return 0;

        // Calculate active rewards
        uint256 activeReward = _calculateActiveReward(account);

        // Return total balance (minted tokens + active rewards)
        return mintedBalance + activeReward;
    }

    /**
     * @dev Internal function: Calculate user active rewards
     * @dev Calculate rewards based on user's minted token balance
     */
    function _calculateActiveReward(
        address user
    ) internal view returns (uint256) {
        // Get user's actual minted token balance
        uint256 userBalance = super.balanceOf(user);
        if (userBalance == 0) return 0;

        uint64 lastUpdateTime = userAccountsLastUpdate[user];
        // Defense: If user timestamp is uninitialized, return 0 rewards
        if (lastUpdateTime == 0) return 0;

        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        if (timeElapsed == 0) return 0; // Avoid meaningless calculations

        // If contract is currently paused, do not accumulate rewards
        if (paused()) return 0;

        // Prevent overflow from excessive time (maximum calculation 10 years)
        if (timeElapsed > MAX_TIME_SPAN) {
            timeElapsed = MAX_TIME_SPAN;
        }

        // Optimized calculation: Reduce division operations, improve precision
        // reward = balance * APY% * timeElapsed / (365 days * 10000)
        uint256 reward = (userBalance * globalActiveAPY * timeElapsed) /
            (SECONDS_PER_YEAR * BASIS_POINTS);

        return reward;
    }

    /* ========== External mint/burn interfaces ========== */

    /**
     * @notice Mint rPUSD tokens (only authorized contracts can call)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(
        address to,
        uint256 amount
    ) external onlyRole(REWARD_MANAGER_ROLE) {
        require(amount > 0, "Amount must be positive");
        _mint(to, amount);
    }

    /**
     * @notice Burn rPUSD tokens (only authorized contracts can call)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(
        address from,
        uint256 amount
    ) external onlyRole(REWARD_MANAGER_ROLE) {
        require(amount > 0, "Amount must be positive");
        _burn(from, amount);
    }

    /**
     * @notice Get current active APY
     * @return Current active annual percentage yield (basis points)
     */
    function getCurrentAPY() external view returns (uint256) {
        return globalActiveAPY;
    }

    /* ========== Lazy Minting System ========== */

    /**
     * @dev Internal function: Realize user accrued rewards (only call when necessary)
     * @param user User address
     */
    function _realizeRewards(address user) internal {
        // Ensure user has initial timestamp to prevent uninitialized users from getting huge rewards
        if (userAccountsLastUpdate[user] == 0) {
            userAccountsLastUpdate[user] = uint64(block.timestamp);
            return; // New user has no rewards, return directly
        }

        uint256 activeReward = _calculateActiveReward(user);

        // Always update timestamp regardless of rewards to prevent duplicate calculations
        // This update ensures activeReward=0 in recursive calls, naturally terminating recursion
        userAccountsLastUpdate[user] = uint64(block.timestamp);
        if (activeReward > 0) {
            // Safety check: Prevent contract accounts from earning interest rewards
            // If it's REWARD_MANAGER (like Farm contract), should not earn interest
            if (hasRole(REWARD_MANAGER_ROLE, user)) {
                // Log warning event but don't mint interest
                emit RewardSkipped(
                    user,
                    activeReward,
                    "Contract account interest blocked"
                );
            } else {
                // Give user full rewards directly, no fees!
                _mint(user, activeReward);
                totalRewardAccrued += activeReward;
                emit RewardRealized(user, activeReward);
            }
        }
    }

    /**
     * @dev Automatically realize rewards during token transfers (modern version)
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        // Realize sender and receiver rewards before transfer
        // Exclude zero addresses in mint/burn operations to avoid unnecessary calls
        if (from != address(0) && from != address(this)) {
            _realizeRewards(from);
        }

        if (to != address(0) && to != address(this)) {
            _realizeRewards(to);
        }

        super._update(from, to, value);
    }

    /* ========== Query Functions ========== */

    /**
     * @notice Get user actual balance (excluding accrued rewards)
     */
    function getBaseBalance(address account) external view returns (uint256) {
        return super.balanceOf(account);
    }

    /**
     * @notice Get user pending rewards
     */
    function getPendingRewards(
        address account
    ) external view returns (uint256 activeReward) {
        activeReward = _calculateActiveReward(account);
    }

    /**
     * @notice Get user account last update time
     */
    function getUserAccountLastUpdate(
        address account
    ) external view returns (uint64 lastUpdateTime) {
        return userAccountsLastUpdate[account];
    }

    /**
     * @notice Get contract overall statistics
     */
    function getContractStats()
        external
        view
        returns (
            uint256 _totalRealSupply,
            uint256 _globalActiveAPY,
            uint256 _totalRewardAccrued
        )
    {
        return (
            totalSupply(), // Actual minted token total supply
            globalActiveAPY,
            totalRewardAccrued
        );
    }

    /* ========== Management Functions ========== */

    /**
     * @notice Manually realize user rewards (user can choose to call)
     * @dev Most of the time this is not needed, transfers will automatically realize rewards
     */
    function realizeMyRewards() external nonReentrant {
        _realizeRewards(msg.sender);
    }

    /**
     * @notice Update global active yield rate (only APY_MANAGER_ROLE)
     * @dev This yield rate will apply to all rPUSD holders, ensuring fair uniformity
     * @param newActiveAPY New active annual percentage yield (basis points, e.g., 800 represents 8%)
     */
    function updateAPYParameters(
        uint256 newActiveAPY
    ) external onlyRole(APY_MANAGER_ROLE) {
        require(newActiveAPY <= type(uint16).max, "APY exceeds uint16 max");
        require(newActiveAPY <= MAX_APY, "APY too high"); // Maximum 50%, allows 0% to pause rewards
        require(newActiveAPY != globalActiveAPY, "APY unchanged"); // Avoid meaningless updates

        // Update global active APY - shared by all users
        globalActiveAPY = uint16(newActiveAPY);

        emit APYUpdated(newActiveAPY);
    }

    /**
     * @notice Emergency pause (only PAUSER_ROLE)
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause (only PAUSER_ROLE)
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
