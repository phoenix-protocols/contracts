// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IVault.sol";
import "../interfaces/IPUSDOracle.sol";

/**
 * @title PUSDOracleStorage
 * @notice Simplified storage for PUSD Oracle
 * @dev Primary market design: PUSD/USD = 1 (constant)
 */
abstract contract PUSDOracleStorage is IPUSDOracle {
    /* ========== State Variables ========== */

    // System contracts
    IVault public vault;
    address public pusdToken;

    // Token configs (simplified - only Chainlink feed)
    mapping(address => TokenConfig) public tokens;
    address[] public supportedTokens;

    // System parameters
    uint256 public maxPriceAge; // Chainlink price validity period
    uint256 public heartbeatInterval; // Heartbeat interval for Vault
    uint256 public lastHeartbeat; // Last heartbeat time

    /* ========== Constants ========== */

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PUSD_USD_PRICE = 1e18; // 1 PUSD = 1 USD (constant, primary market)
    uint256 public constant DEFAULT_MAX_PRICE_AGE = 3600 * 24; // 24 hours
    uint256 public constant DEFAULT_HEARTBEAT_INTERVAL = 3600; // 1 hour

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
