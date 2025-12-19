// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "../interfaces/IVault.sol";
import "../interfaces/IPUSDOracle.sol";

abstract contract PUSDOracleStorage is IPUSDOracle {
    /* ========== State Variables ========== */

    // System contracts
    IVault public vault;
    address public pusdToken;

    mapping(address => TokenConfig) public tokens;
    address[] public supportedTokens;

    // System parameters
    uint256 public maxPriceAge; // Price validity period
    uint256 public heartbeatInterval; // Heartbeat interval
    uint256 public lastHeartbeat; // Last heartbeat time

    // PUSD global price
    uint256 public pusdUsdPrice; // Current PUSD/USD price
    uint256 public pusdPriceUpdated; // PUSD price last update time

    // PUSD depeg detection
    uint256 public pusdDepegThreshold; // Depeg threshold (basis points)
    uint256 public pusdRecoveryThreshold; // Unpause threshold (basis points)
    uint256 public pusdDepegCount; // Depeg count

    // DEX-only tokens (no Chainlink feed needed, only Uniswap Token/PUSD pair)
    mapping(address => DexOnlyTokenConfig) public supportedDexOnlyTokens; // Token => Config
    address[] public supportedDexOnlyTokenList; // List of all DEX-only tokens

    // Bootstrap mode - allows 1:1 pricing during system initialization
    bool public bootstrapMode; // If true, use fixed 1:1 pricing for supported tokens
    mapping(address => bool) public bootstrapTokens; // Tokens that can use bootstrap pricing

    /* ========== Constants ========== */

    bytes32 public constant PRICE_UPDATER_ROLE = keccak256("PRICE_UPDATER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant DEFAULT_PUSDUSD_PRICE = 1e18; // 1 PUSD = 1 USD
    uint256 public constant DEFAULT_MAX_PRICE_AGE = 3600 * 24; // 24 hours
    uint256 public constant DEFAULT_HEARTBEAT_INTERVAL = 3600; // 1 hour
    uint256 public constant DEFAULT_DEPEG_THRESHOLD = 500; // 5%
    uint256 public constant DEFAULT_RECOVERY_THRESHOLD = 200; // 2%
    uint256 public constant MAX_DEPEG_COUNT = 2; // Maximum depeg count

    // PlaceHolder
    uint256[48] private __gap; // Reduced from 50 to 48 due to new state variables
}
