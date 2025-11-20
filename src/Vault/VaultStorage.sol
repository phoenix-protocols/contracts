// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract VaultStorage {
    /* ========== Struct Definitions ========== */
    struct WithdrawalRequest {
        address assetToken; // Asset address
        uint256 amount; // Withdrawal amount
    }

    uint64 public constant MAX_DELAY_PERIOD = 7 days;
    address public _nftManager; // NFT Manager contract address

    /* ========== Event Definitions ========== */

    event FarmAddressSet(address indexed farm); // Farm contract address setting event
    event OracleManagerSet(address indexed oracleManager); // Oracle manager address setting event
    event WithdrawalProposed(address indexed to, address[] assets, uint256[] amounts, uint256 unlockTime); // Withdrawal proposal event
    event WithdrawalExecuted(address indexed to, address[] assets, uint256[] amounts); // Withdrawal execution event
    event FeesClaimed(address indexed to, address indexed asset, uint256 amount); // Fee withdrawal event
    event AdminTransferred(address indexed from, address indexed to); // Admin transfer event
    event TVLChanged(address indexed asset, uint256 tvl); // TVL change event
    event Deposited(address indexed user, address indexed asset, uint256 amount); // User deposit event
    event Withdrawn(address indexed user, address indexed asset, uint256 amount); // User withdrawal event
    event AssetAdded(address indexed asset, string name); // Asset addition event
    event AssetRemoved(address indexed asset, string name); // Asset removal event
    // Emergency pause and unpause events are inherited from PausableUpgradeable
    event EmergencySwept(address indexed token, address indexed to, uint256 amount);
    // New event for withdrawal cancellation
    event WithdrawalCancelled(address indexed by, address[] assets, uint256[] amounts);

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
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE"); // Asset admin role
    uint256 public constant HEALTH_CHECK_TIMEOUT = 1 hours; // Oracle health check timeout
    uint256 public constant TIMELOCK_DELAY = 48 hours; // Large amount withdrawal timelock delay

    /* ========== Timelock withdrawal related ========== */

    WithdrawalRequest[] public pendingWithdrawalRequests; // Pending withdrawal requests
    address public pendingWithdrawalTo; // Pending withdrawal target address
    uint256 public withdrawalUnlockTime; // Withdrawal unlock time

    /* ========== System monitoring ========== */

    uint256 public lastHealthCheck; // Last health check time

    /* ========== Single Admin Management ========== */

    address public singleAdmin; // Single admin address for vault management

    /* ========== Temporary storage ========== */
    mapping(address => bool) internal _tempAssetCheck; // Temporary asset check mapping

    // PlaceHolder
    uint256[50] private __gap;
}
