// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Oracle interface
interface IPUSDOracle {
    function getTokenUSDPrice(
        address token
    ) external view returns (uint256 price, uint256 timestamp);

    function getPUSDUSDPrice()
        external
        view
        returns (uint256 price, uint256 timestamp);

    function getTokenPUSDPrice(
        address token
    ) external view returns (uint256 price, uint256 timestamp);
}

/**
 * @title VaultUpgradeable
 * @notice Core asset vault contract of Phoenix DeFi system
 * @dev Upgradeable multi-asset vault supporting dynamic addition/removal of stablecoin assets
 *
 * Main features:
 * - Multi-asset support (USDT, USDC and other stablecoins)
 * - Fund deposit/withdrawal management (only callable by Farm contract)
 * - Fee collection and distribution
 * - 48-hour timelock secure withdrawal mechanism
 * - Oracle system health check
 * - Emergency pause functionality
 * - UUPS upgradeable proxy pattern
 *
 * securityfeatures：
 * - Multiple permissions control (admin, asset admin, pauser)
 * - Reentrancy attack protection
 * - Timelock large amount withdrawal protection
 * - Oracle offline detection and automatic pause
 */
contract VaultUpgradeable is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /* ========== State Variables ========== */

    // Dynamic asset management
    mapping(address => bool) public supportedAssets; // Supported asset mapping table
    address[] public assetList; // Supported asset list array
    mapping(address => string) public assetNames; // Asset address to name mapping

    // System contract addresses
    address public farm; // Farm contract address, the only contract that can call deposit/withdrawal functions
    address public oracleManager; // Oracle management contract address, responsible for price feeds and health checks
    address public pusdToken; // PUSD token contract address, prohibited from being added as collateral

    // Fee management - record separately by asset
    mapping(address => uint256) public accumulatedFees; // Accumulated fees for each asset

    /* ========== Constants and roles ========== */

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE"); // Pauser role
    bytes32 public constant ASSET_MANAGER_ROLE =
        keccak256("ASSET_MANAGER_ROLE"); // Asset admin role
    uint256 public constant HEALTH_CHECK_TIMEOUT = 1 hours; // Oracle health check timeout
    uint256 public constant TIMELOCK_DELAY = 48 hours; // Large amount withdrawal timelock delay

    /* ========== Timelock withdrawal related ========== */

    uint256 public pendingWithdrawalAmount; // Pending withdrawal amount
    address public pendingWithdrawalAsset; // Pending withdrawal asset address
    address public pendingWithdrawalTo; // Pending withdrawal target address
    uint256 public withdrawalUnlockTime; // Withdrawal unlock time

    /* ========== System monitoring ========== */

    uint256 public lastHealthCheck; // Last health check time

    /* ========== Single Admin Management ========== */

    address public singleAdmin; // Single admin address for vault management

    // Reserved upgrade space - Ensure storage layout compatibility (reduced from 37 to 36 due to singleAdmin)
    uint256[36] private __gap;

    /* ========== Event Definitions ========== */

    event FarmAddressSet(address indexed farm); // Farm contract address setting event
    event OracleManagerSet(address indexed oracleManager); // Oracle manager address setting event
    event WithdrawalProposed(
        address indexed to,
        address indexed asset,
        uint256 amount,
        uint256 unlockTime
    ); // Withdrawal proposal event
    event WithdrawalExecuted(
        address indexed to,
        address indexed asset,
        uint256 amount
    ); // Withdrawal execution event
    event FeesClaimed(
        address indexed to,
        address indexed asset,
        uint256 amount
    ); // Fee withdrawal event
    event AdminTransferred(address indexed from, address indexed to); // Admin transfer event
    event TVLChanged(address indexed asset, uint256 tvl); // TVL change event
    event Deposited(
        address indexed user,
        address indexed asset,
        uint256 amount
    ); // User deposit event
    event Withdrawn(
        address indexed user,
        address indexed asset,
        uint256 amount
    ); // User withdrawal event
    event AssetAdded(address indexed asset, string name); // Asset addition event
    event AssetRemoved(address indexed asset, string name); // Asset removal event
    // Emergency pause and unpause events are inherited from PausableUpgradeable
    event EmergencySwept(
        address indexed token,
        address indexed to,
        uint256 amount
    );
    // New event for withdrawal cancellation
    event WithdrawalCancelled(
        address indexed by,
        address indexed asset,
        uint256 amount
    );

    /* ========== Constructor and Initialization ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize vault contract
     * @dev Can only be called once, sets admin and assigns initial roles
     *      Assets like USDT and USDC need to be manually added after deployment via addAsset()
     * @param admin Admin address, will receive all management permissions
     * @param _pusdToken PUSD token contract address (for protection, prohibited from being added as collateral)
     */
    function initialize(address admin, address _pusdToken) public initializer {
        require(admin != address(0), "Vault: Invalid admin address");
        require(_pusdToken != address(0), "Vault: Invalid PUSD address");

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin); // Highest management permissions
        _grantRole(PAUSER_ROLE, admin); // Pause permissions
        _grantRole(ASSET_MANAGER_ROLE, admin); // Asset management permissions
        lastHealthCheck = block.timestamp; // Initialize health check time

        // Set PUSD token address (for protection)
        pusdToken = _pusdToken;

        // Initialize single admin
        singleAdmin = admin;

        // Note: USDT and USDC assets need to be manually added after deployment
        // Use addAsset() function to add supported assets
    }

    /* ========== System configuration functions ========== */

    /**
     * @notice Set Farm contract address
     * @dev Can only be set once to ensure system security
     * @param _farm Farm contract address
     */
    function setFarmAddress(
        address _farm
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(farm == address(0), "Vault: Farm address already set");
        require(_farm != address(0), "Vault: Invalid farm address");
        farm = _farm;
        emit FarmAddressSet(_farm);
    }

    /**
     * @notice Set Oracle manager contract address
     * @dev Can only be set once, responsible for system health checks and price feeds
     * @param _oracleManager Oracle manager contract address
     */
    function setOracleManager(
        address _oracleManager
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            oracleManager == address(0),
            "Vault: Oracle Manager already set"
        );
        require(
            _oracleManager != address(0),
            "Vault: Invalid Oracle Manager address"
        );
        oracleManager = _oracleManager;
        emit OracleManagerSet(_oracleManager);
    }

    /* ========== Asset management functions ========== */

    /**
     * @notice Add supported asset
     * @dev Asset admin can dynamically add new stablecoin assets
     * @param asset Asset contract address
     * @param name Asset name (e.g., "Tether USD", "USD Coin")
     */
    function addAsset(
        address asset,
        string memory name
    ) external onlyRole(ASSET_MANAGER_ROLE) {
        // 🔒 Security check: PUSD cannot be a collateral asset
        require(asset != pusdToken, "Vault: PUSD cannot be collateral asset");
        _addAssetInternal(asset, name);
    }

    /**
     * @notice Internal function: Add asset support (no permission check, for initialization use only)
     * @param asset Asset contract address
     * @param name Asset name
     */
    function _addAssetInternal(address asset, string memory name) internal {
        require(asset != address(0), "Vault: Invalid asset address");
        require(!supportedAssets[asset], "Vault: Asset already supported");
        require(bytes(name).length > 0, "Vault: Asset name cannot be empty");

        supportedAssets[asset] = true;
        assetList.push(asset);
        assetNames[asset] = name;

        emit AssetAdded(asset, name);
    }

    /**
     * @notice Remove supported asset
     * @dev Use with caution! Can only remove when asset balance and fees are both 0
     * @param asset Asset contract address to remove
     */
    function removeAsset(address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(supportedAssets[asset], "Vault: Asset not supported");
        require(
            IERC20(asset).balanceOf(address(this)) == 0,
            "Vault: Asset has balance"
        );
        require(accumulatedFees[asset] == 0, "Vault: Asset has unclaimed fees");

        supportedAssets[asset] = false;
        string memory name = assetNames[asset];
        delete assetNames[asset];

        // Remove from array (using swap-delete method to optimize gas consumption)
        for (uint256 i = 0; i < assetList.length; i++) {
            if (assetList[i] == asset) {
                assetList[i] = assetList[assetList.length - 1];
                assetList.pop();
                break;
            }
        }

        emit AssetRemoved(asset, name);
    }

    /* ========== Core fund operation functions ========== */

    /**
     * @notice User deposit function
     * @dev Only Farm contract can call, includes Oracle health check
     * @param user Depositing user address
     * @param asset Deposit asset address
     * @param amount Deposit amount
     */
    function depositFor(
        address user,
        address asset,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        require(
            block.timestamp - lastHealthCheck < HEALTH_CHECK_TIMEOUT,
            "Vault: Oracle system offline"
        );
        require(msg.sender == farm, "Vault: Caller is not the farm");
        require(supportedAssets[asset], "Vault: Unsupported asset");

        // Check allowance amount, provide friendly error message
        uint256 allowance = IERC20(asset).allowance(user, address(this));
        require(allowance >= amount, "Vault: Please approve tokens first");

        IERC20(asset).safeTransferFrom(user, address(this), amount);
        emit Deposited(user, asset, amount);
        emit TVLChanged(asset, IERC20(asset).balanceOf(address(this)));
    }

    /**
     * @notice User withdrawal function
     * @dev Only Farm contract can call, includes Oracle health check
     * @param user Withdrawing user address
     * @param asset Withdrawal asset address
     * @param amount Withdrawal amount
     */
    function withdrawTo(
        address user,
        address asset,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        require(
            block.timestamp - lastHealthCheck < HEALTH_CHECK_TIMEOUT,
            "Vault: Oracle system offline"
        );
        require(msg.sender == farm, "Vault: Caller is not the farm");
        require(supportedAssets[asset], "Vault: Unsupported asset");

        IERC20(asset).safeTransfer(user, amount);
        emit Withdrawn(user, asset, amount);
        emit TVLChanged(asset, IERC20(asset).balanceOf(address(this)));
    }

    /**
     * @notice Add fee
     * @dev Called by Farm contract to record transaction fees
     * @param asset Fee asset address
     * @param amount Fee amount
     */
    function addFee(address asset, uint256 amount) external {
        require(msg.sender == farm, "Vault: Caller is not the farm");
        require(supportedAssets[asset], "Vault: Unsupported asset");
        require(amount > 0, "Vault: Invalid fee amount");
        accumulatedFees[asset] += amount;
    }

    /* ========== Admin operation functions ========== */

    /**
     * @notice Withdraw fees
     * @dev Admin can withdraw accumulated fees to specified address
     * @param asset Asset contract address to withdraw fees from
     * @param to Fee recipient address
     */
    function claimFees(
        address asset,
        address to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(supportedAssets[asset], "Vault: Unsupported asset");
        uint256 feesToClaim = accumulatedFees[asset];
        require(feesToClaim > 0, "Vault: No fees to claim");

        uint256 balance = IERC20(asset).balanceOf(address(this));
        require(balance >= feesToClaim, "Vault: Insufficient balance for fees");

        accumulatedFees[asset] = 0;
        IERC20(asset).safeTransfer(to, feesToClaim);
        emit FeesClaimed(to, asset, feesToClaim);
    }

    /**
     * @notice Propose large amount withdrawal
     * @dev Start 48-hour timelock protection mechanism for emergency or large fund allocation
     * @param to Withdrawal target address
     * @param asset Withdrawal asset address
     * @param amount Withdrawal amount
     */
    function proposeWithdrawal(
        address to,
        address asset,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Vault: Cannot withdraw to zero address");
        require(supportedAssets[asset], "Vault: Unsupported asset");
        require(
            IERC20(asset).balanceOf(address(this)) >= amount,
            "Vault: Insufficient funds for proposal"
        );
        require(
            pendingWithdrawalAmount == 0,
            "Vault: Pending withdrawal exists"
        );

        pendingWithdrawalAmount = amount;
        pendingWithdrawalAsset = asset;
        pendingWithdrawalTo = to;
        withdrawalUnlockTime = block.timestamp + TIMELOCK_DELAY;
        emit WithdrawalProposed(to, asset, amount, withdrawalUnlockTime);
    }

    /**
     * @notice Execute large amount withdrawal
     * @dev Execute withdrawal operation after timelock expires
     */
    function executeWithdrawal()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(
            block.timestamp >= withdrawalUnlockTime,
            "Vault: Timelock has not expired"
        );
        require(
            pendingWithdrawalAmount > 0,
            "Vault: No pending withdrawal to execute"
        );

        uint256 amount = pendingWithdrawalAmount;
        address asset = pendingWithdrawalAsset;
        address to = pendingWithdrawalTo;

        // Clear pending withdrawal state
        pendingWithdrawalAmount = 0;
        pendingWithdrawalAsset = address(0);
        pendingWithdrawalTo = address(0);
        withdrawalUnlockTime = 0;

        IERC20(asset).safeTransfer(to, amount);
        emit WithdrawalExecuted(to, asset, amount);
        emit TVLChanged(asset, IERC20(asset).balanceOf(address(this)));
    }

    /**
     * @notice Cancel pending withdrawal
     * @dev Admin can cancel a pending withdrawal before it unlocks
     */
    function cancelWithdrawal() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pendingWithdrawalAmount > 0, "Vault: No pending withdrawal");

        address asset = pendingWithdrawalAsset;
        uint256 amount = pendingWithdrawalAmount;

        pendingWithdrawalAmount = 0;
        pendingWithdrawalAsset = address(0);
        pendingWithdrawalTo = address(0);
        withdrawalUnlockTime = 0;

        emit WithdrawalCancelled(msg.sender, asset, amount);
    }

    /**
     * @notice Emergency rescue for non-supported tokens mistakenly sent to the vault
     * @dev Only for NON-supported assets. Supported assets must use timelock withdrawal.
     */
    function emergencySweep(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(token != address(0) && to != address(0), "Vault: Zero address");
        require(
            !supportedAssets[token],
            "Vault: Use timelock for supported asset"
        );
        require(token != pusdToken, "Vault: Cannot sweep PUSD");
        IERC20(token).safeTransfer(to, amount);
    }

    /* ========== System monitoring and control functions ========== */

    /**
     * @notice Oracle system heartbeat check
     * @dev Oracle manager calls regularly to prove system is functioning normally
     */
    function heartbeat() external {
        require(
            msg.sender == oracleManager,
            "Vault: Only Oracle Manager can send heartbeat"
        );
        lastHealthCheck = block.timestamp;
    }

    /**
     * @notice Pause contract
     * @dev Pause all deposit/withdrawal operations in emergency
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract
     * @dev Remove pause state and resume normal operations
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /* ========== Query functions ========== */

    // 📋 Frontend call format specification:
    //
    // 🔢 Values that need to be divided by asset decimals (raw token amount):
    //   - getTVL(address).tvl          → tvl / (10 ** tokenDecimals)
    //   - getFormattedTVL().assetAmount → amount / (10 ** assetDecimals)
    //   - getPUSDMarketCap()           → marketCap / (10 ** pusdDecimals) [PUSD decimals]
    //
    // 💰 USD values that need to be divided by 10^18 (standard 18 decimal places):
    //   - getTVL(address).marketValue   → value / 1e18
    //   - getTotalTVL()                → value / 1e18
    //   - getTotalMarketValue()        → value / 1e18
    //   - getFormattedTVL().usdAmount  → value / 1e18
    //
    // ✅ Final values (no processing needed):
    //   - getFormattedTVL().assetDecimals → use directly
    //   - getFormattedTVL().assetSymbol   → use directly
    //   - getClaimableFees()             → fees / (10 ** tokenDecimals)

    /**
     * @notice Get vault total value locked (TVL) and market value for specific asset
     * @param asset Asset contract address
     * @return tvl Asset balance in vault (raw amount, needs to be divided by tokenDecimals)
     * @return marketValue Market value of the asset (USD denominated, 18 decimal places, needs to be divided by 1e18)
     */
    function getTVL(
        address asset
    ) external view returns (uint256 tvl, uint256 marketValue) {
        require(supportedAssets[asset], "Vault: Unsupported asset");

        // Get asset balance
        tvl = IERC20(asset).balanceOf(address(this));

        // If Oracle is set, calculate real market value
        if (oracleManager != address(0)) {
            try IPUSDOracle(oracleManager).getTokenUSDPrice(asset) returns (
                uint256 price,
                uint256
            ) {
                // Get asset decimal places
                uint8 decimals = IERC20Metadata(asset).decimals();

                // Calculate market value: tvl * price / (10 ** decimals)
                // price is already 18 decimal USD price, tvl is raw asset amount
                marketValue = (tvl * price) / (10 ** decimals);
            } catch {
                // Oracle call failed, use fallback logic
                marketValue = tvl; // Assume 1:1 USD value
            }
        } else {
            // Oracle not set, use fallback logic
            marketValue = tvl; // Assume 1:1 USD value
        }
    }

    /**
     * @notice Get system total TVL (sum of USD market values of all assets)
     * @return totalTVL System total TVL, USD denominated, 18 decimal places (frontend needs to divide by 1e18)
     * @dev Iterate through all supported assets and calculate their total USD value
     */
    function getTotalTVL() external view returns (uint256 totalTVL) {
        for (uint256 i = 0; i < assetList.length; i++) {
            address asset = assetList[i];
            try this.getTVL(asset) returns (uint256, uint256 marketValue) {
                totalTVL += marketValue;
            } catch {
                // If price retrieval fails for an asset, skip that asset
                continue;
            }
        }
    }

    /**
     * @notice Get PUSD market capitalization (another representation of total market TVL)
     * @return pusdMarketCap PUSD circulating market cap (raw amount, needs to be divided by pusd decimals)
     * @dev Directly use contract stored pusdToken address for better security and reliability
     */
    function getPUSDMarketCap() external view returns (uint256 pusdMarketCap) {
        require(pusdToken != address(0), "Vault: PUSD token not set");

        uint256 pusdTotalSupply = IERC20(pusdToken).totalSupply();

        if (oracleManager != address(0)) {
            try IPUSDOracle(oracleManager).getPUSDUSDPrice() returns (
                uint256 pusdPrice,
                uint256
            ) {
                // PUSD market cap = circulation * PUSD/USD price
                pusdMarketCap = (pusdTotalSupply * pusdPrice) / 1e18;
            } catch {
                // Oracle call failed, assume PUSD=$1.00
                pusdMarketCap = pusdTotalSupply;
            }
        } else {
            // Oracle not set, assume PUSD=$1.00
            pusdMarketCap = pusdTotalSupply;
        }
    }

    /**
     * @notice Get PUSD value corresponding to specified asset amount
     * @param asset Asset contract address
     * @param amount Asset amount (raw units, including decimal places)
     * @return pusdAmount Corresponding PUSD amount (6 decimal places)
     * @dev Directly obtain Token/PUSD price through Oracle for conversion, transaction fails if price retrieval fails
     */
    function getTokenPUSDValue(
        address asset,
        uint256 amount
    ) external view returns (uint256 pusdAmount) {
        require(supportedAssets[asset], "Vault: Unsupported asset");
        require(amount > 0, "Vault: Amount must be greater than 0");
        require(oracleManager != address(0), "Vault: Oracle not set");

        // Must get price from Oracle, fail if no price
        (uint256 tokenPusdPrice, ) = IPUSDOracle(oracleManager)
            .getTokenPUSDPrice(asset);
        require(tokenPusdPrice > 0, "Vault: Invalid token price");

        // Get asset decimal places
        uint8 assetDecimals = IERC20Metadata(asset).decimals();

        // Calculate PUSD amount: amount * tokenPusdPrice / (10 ** assetDecimals)
        // tokenPusdPrice is 18 decimal places, amount is raw asset amount, result converted to 6 decimal places
        pusdAmount = (amount * tokenPusdPrice) / (10 ** (assetDecimals + 12));
    }

    /**
     * @notice Convert PUSD amount to corresponding asset amount
     * @param asset Asset contract address
     * @param pusdAmount PUSD amount (6 decimal places)
     * @return amount Corresponding asset amount
     */
    function getPUSDAssetValue(
        address asset,
        uint256 pusdAmount
    ) external view returns (uint256 amount) {
        require(supportedAssets[asset], "Vault: Unsupported asset");
        require(pusdAmount >= 0, "Vault: Amount must be greater than 0");
        require(oracleManager != address(0), "Vault: Oracle not set");

        // Must get price from Oracle, fail if no price
        (uint256 tokenPusdPrice, ) = IPUSDOracle(oracleManager)
            .getTokenPUSDPrice(asset);
        require(tokenPusdPrice > 0, "Vault: Invalid token price");

        // Get asset decimal places
        uint8 assetDecimals = IERC20Metadata(asset).decimals();

        // Calculate asset amount: pusdAmount * (10 ** (assetDecimals + 12)) / tokenPusdPrice
        // This is the reverse calculation of getTokenPUSDValue
        amount = (pusdAmount * (10 ** (assetDecimals + 12))) / tokenPusdPrice;
    }

    /**
     * @notice Get simplified formatted TVL information (convenient for frontend display)
     * @param asset Asset contract address
     * @return assetAmount Asset amount (without decimal places, e.g.: 1000500 represents 1000.5)
     * @return usdAmount USD value (without decimal places, e.g.: 1000500 represents $1000.5)
     * @return assetDecimals Asset decimal places (for frontend formatting display)
     * @return assetSymbol Asset symbol
     * @dev Frontend usage: assetAmount / (10 ** assetDecimals) to get real amount
     *      Frontend usage: usdAmount / 1e18 to get real USD value
     */
    function getFormattedTVL(
        address asset
    )
        external
        view
        returns (
            uint256 assetAmount,
            uint256 usdAmount,
            uint8 assetDecimals,
            string memory assetSymbol
        )
    {
        require(supportedAssets[asset], "Vault: Unsupported asset");

        (uint256 tvl, uint256 marketValue) = this.getTVL(asset);

        // Get asset information
        assetDecimals = IERC20Metadata(asset).decimals();
        assetSymbol = IERC20Metadata(asset).symbol();

        // Return raw data, let frontend format it
        assetAmount = tvl; // Keep asset raw decimal format
        usdAmount = marketValue; // 18 decimal USD value
    }

    /**
     * @notice Get claimable fees for specific asset
     * @param asset Asset contract address
     * @return Accumulated fee amount for that asset
     */
    function getClaimableFees(address asset) external view returns (uint256) {
        require(supportedAssets[asset], "Vault: Unsupported asset");
        return accumulatedFees[asset];
    }

    /**
     * @notice Check system health status
     * @return true if Oracle system is online and functioning normally
     */
    function isHealthy() external view returns (bool) {
        return block.timestamp - lastHealthCheck < HEALTH_CHECK_TIMEOUT;
    }

    /**
     * @notice Check if it's a supported asset
     * @param asset Asset contract address
     * @return true if the asset is supported by the vault
     */
    function isValidAsset(address asset) external view returns (bool) {
        return supportedAssets[asset];
    }

    /**
     * @notice Get list of all supported assets
     * @return Array of supported asset addresses
     */
    function getSupportedAssets() external view returns (address[] memory) {
        return assetList;
    }

    /**
     * @notice Get asset name
     * @param asset Asset contract address
     * @return Readable name of the asset
     */
    function getAssetName(address asset) external view returns (string memory) {
        require(supportedAssets[asset], "Vault: Unsupported asset");
        return assetNames[asset];
    }

    /**
     * @notice Get asset symbol (abbreviation)
     * @dev Read symbol directly from ERC20 contract
     * @param asset Asset contract address
     * @return Asset symbol (e.g., USDT, USDC)
     */
    function getAssetSymbol(
        address asset
    ) external view returns (string memory) {
        require(supportedAssets[asset], "Vault: Unsupported asset");
        return IERC20Metadata(asset).symbol();
    }

    /**
     * @notice Get asset decimal places
     * @dev Read decimals directly from ERC20 contract
     * @param asset Asset contract address
     * @return Asset decimal places (e.g., 6 for USDT/USDC, 18 for most ERC20)
     */
    function getTokenDecimals(address asset) external view returns (uint8) {
        require(supportedAssets[asset], "Vault: Unsupported asset");
        return IERC20Metadata(asset).decimals();
    }

    /**
     * @notice Get remaining time for pending withdrawal
     * @dev Return how many seconds until withdrawal unlock, return 0 if already unlocked
     * @return remainingTime Remaining time (seconds), 0 means ready to execute or no pending withdrawal
     */
    function getRemainingWithdrawalTime()
        external
        view
        returns (uint256 remainingTime)
    {
        if (pendingWithdrawalAmount == 0 || withdrawalUnlockTime == 0) {
            return 0; // No pending withdrawal or unlock time not set
        }

        if (block.timestamp >= withdrawalUnlockTime) {
            return 0; // Already ready to execute
        }

        return withdrawalUnlockTime - block.timestamp; // Remaining seconds
    }

    /**
     * @notice Get pending withdrawal status details
     * @dev Return complete information about current pending withdrawal
     * @return to Withdrawal target address
     * @return asset Withdrawal asset address
     * @return assetName Withdrawal asset name
     * @return amount Withdrawal amount
     * @return unlockTime Unlock timestamp
     * @return remainingTime Remaining time (seconds)
     * @return canExecute Whether it can be executed
     */
    function getPendingWithdrawalInfo()
        external
        view
        returns (
            address to,
            address asset,
            string memory assetName,
            uint256 amount,
            uint256 unlockTime,
            uint256 remainingTime,
            bool canExecute
        )
    {
        to = pendingWithdrawalTo;
        asset = pendingWithdrawalAsset;
        assetName = assetNames[asset];
        amount = pendingWithdrawalAmount;
        unlockTime = withdrawalUnlockTime;

        if (amount == 0 || unlockTime == 0) {
            remainingTime = 0;
            canExecute = false;
        } else if (block.timestamp >= unlockTime) {
            remainingTime = 0;
            canExecute = true;
        } else {
            remainingTime = unlockTime - block.timestamp;
            canExecute = false;
        }
    }

    /* ========== Upgrade control functions ========== */

    /**
     * @notice Authorize contract upgrade
     * @dev Only admin can upgrade contract
     * @param newImplementation New implementation contract address
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin privileges are sufficient, no additional validation needed
    }

    /* ========== Single Admin Management ========== */

    /**
     * @notice Override grantRole function to prevent external DEFAULT_ADMIN_ROLE assignment
     * @dev Force use of transferAdmin() for admin role management
     */
    function grantRole(bytes32 role, address account) public override {
        if (role == DEFAULT_ADMIN_ROLE) {
            revert("Vault: Use transferAdmin() instead");
        }
        super.grantRole(role, account);
    }

    /**
     * @notice Override revokeRole function to prevent external DEFAULT_ADMIN_ROLE revocation
     * @dev Force use of transferAdmin() for admin role management
     */
    function revokeRole(bytes32 role, address account) public override {
        if (role == DEFAULT_ADMIN_ROLE) {
            revert("Vault: Use transferAdmin() instead");
        }
        super.revokeRole(role, account);
    }

    /**
     * @notice Transfer admin role to new address
     * @dev Only current admin can transfer, ensures single admin at all times
     * @param newAdmin New admin address
     */
    function transferAdmin(
        address newAdmin
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAdmin != address(0), "Vault: Invalid admin address");
        require(newAdmin != singleAdmin, "Vault: Already the admin");

        address oldAdmin = singleAdmin;

        super.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        singleAdmin = newAdmin;
        // Revoke old admin and grant to new admin
        super.revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);

        emit AdminTransferred(oldAdmin, newAdmin);
    }

    /**
     * @notice Get current admin address
     * @return Current single admin address
     */
    function getCurrentAdmin() external view returns (address) {
        return singleAdmin;
    }
}
