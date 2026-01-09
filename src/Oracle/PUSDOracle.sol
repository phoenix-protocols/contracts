// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import "../interfaces/IVault.sol";
import "../interfaces/IPUSDOracle.sol";
import "./PUSDOracleStorage.sol";

/**
 * @title PUSDOracleUpgradeable
 * @notice Simplified PUSD price oracle - Primary Market Design
 * @dev 
 * Core Design Philosophy:
 * - PRIMARY MARKET: PUSD/USD = 1 (constant, by definition)
 * - SECONDARY MARKET: DEX prices are independent, handled by arbitrage
 * 
 * Price Logic:
 * - Token/USD: Retrieved from Chainlink (real-time)
 * - PUSD/USD: Always $1.00 (constant)
 * - Token/PUSD: Equals Token/USD (since PUSD = $1)
 * 
 * This design eliminates:
 * - TWAP dependency and Keeper requirements for price updates
 * - Complex depeg detection (primary market cannot depeg)
 * - Bootstrap mode (not needed when PUSD = $1 by definition)
 * 
 * Heartbeat mechanism retained for Vault health checks
 */
contract PUSDOracleUpgradeable is 
    Initializable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable, 
    PUSDOracleStorage 
{
    /* ========== Initialize ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _vault, address _pusdToken, address admin) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_vault != address(0), "Invalid vault");
        require(_pusdToken != address(0), "Invalid PUSD");

        vault = IVault(_vault);
        pusdToken = _pusdToken;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        // Initialize parameters
        heartbeatInterval = DEFAULT_HEARTBEAT_INTERVAL;
        lastHeartbeat = block.timestamp;
    }

    /* ========== Token Management ========== */

    /**
     * @notice Add supported token with Chainlink price feed
     * @param token Token address
     * @param usdFeed Chainlink Token/USD price feed address
     * @param _maxPriceAge Maximum price age for this token (seconds)
     */
    function addToken(address token, address usdFeed, uint256 _maxPriceAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Invalid token");
        require(usdFeed != address(0), "Invalid feed");
        require(tokens[token].usdFeed == address(0), "Token exists");
        require(_maxPriceAge > 0 && _maxPriceAge <= 3600 * 48, "Invalid max price age");

        // Verify Chainlink feed is working
        AggregatorV3Interface feed = AggregatorV3Interface(usdFeed);
        (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();
        
        require(price > 0, "Invalid price");
        require(block.timestamp >= updatedAt, "Future timestamp");
        require(block.timestamp - updatedAt <= _maxPriceAge, "Stale price");

        tokens[token] = TokenConfig({
            usdFeed: usdFeed,
            maxPriceAge: _maxPriceAge
        });
        supportedTokens.push(token);

        emit TokenAdded(token, usdFeed);
    }

    /**
     * @notice Remove a supported token
     * @param token Token address to remove
     */
    function removeToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tokens[token].usdFeed != address(0), "Token not found");
        
        delete tokens[token];
        
        // Remove from array
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == token) {
                supportedTokens[i] = supportedTokens[supportedTokens.length - 1];
                supportedTokens.pop();
                break;
            }
        }

        emit TokenRemoved(token);
    }

    /* ========== Price Queries ========== */

    /**
     * @notice Get PUSD/USD price
     * @dev Primary market price - PUSD is always worth $1 by definition
     * @return price Always 1e18 ($1.00)
     * @return timestamp Current block timestamp
     */
    function getPUSDUSDPrice() external view returns (uint256 price, uint256 timestamp) {
        return (PUSD_USD_PRICE, block.timestamp);
    }

    /**
     * @notice Get Token/USD price from Chainlink
     * @param token Token address
     * @return price Token price in USD (18 decimals)
     * @return timestamp Chainlink price update timestamp
     */
    function getTokenUSDPrice(address token) public view returns (uint256 price, uint256 timestamp) {
        TokenConfig storage config = tokens[token];
        require(config.usdFeed != address(0), "Token not supported");

        AggregatorV3Interface feed = AggregatorV3Interface(config.usdFeed);
        (, int256 priceInt, , uint256 updatedAt, ) = feed.latestRoundData();

        require(priceInt > 0, "Invalid price");
        require(block.timestamp - updatedAt <= config.maxPriceAge, "Stale price");

        // Normalize to 18 decimals
        uint256 tokenPrice = uint256(priceInt);
        uint8 decimals = feed.decimals();
        
        if (decimals < 18) {
            tokenPrice = tokenPrice * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            tokenPrice = tokenPrice / (10 ** (decimals - 18));
        }

        return (tokenPrice, updatedAt);
    }

    /**
     * @notice Get Token/PUSD price
     * @dev Since PUSD = $1 in primary market, Token/PUSD equals Token/USD
     * @param token Token address
     * @return price Token price in PUSD (18 decimals)
     * @return timestamp Chainlink price update timestamp
     */
    function getTokenPUSDPrice(address token) external view returns (uint256 price, uint256 timestamp) {
        // Token/PUSD = Token/USD ÷ PUSD/USD = Token/USD ÷ 1 = Token/USD
        return getTokenUSDPrice(token);
    }

    /* ========== Query Functions ========== */

    /**
     * @notice Get all supported tokens
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    /**
     * @notice Get token configuration
     * @param token Token address
     * @return usdFeed Chainlink price feed address
     * @return maxPriceAge Maximum price age for this token
     */
    function getTokenInfo(address token) external view returns (address usdFeed, uint256 maxPriceAge) {
        TokenConfig storage config = tokens[token];
        return (config.usdFeed, config.maxPriceAge);
    }

    /* ========== Heartbeat ========== */

    /**
     * @notice Send heartbeat to Vault
     * @dev Can be called by anyone - no permission required
     */
    function sendHeartbeat() external {
        _sendHeartbeat();
    }

    /**
     * @notice Internal heartbeat function
     */
    function _sendHeartbeat() internal {
        vault.heartbeat();
        lastHeartbeat = block.timestamp;
        emit HeartbeatSent(block.timestamp);
    }

    /* ========== System Parameters ========== */

    /**
     * @notice Update heartbeat interval
     * @param _heartbeatInterval Heartbeat interval (seconds)
     */
    function updateHeartbeatInterval(uint256 _heartbeatInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_heartbeatInterval > 0 && _heartbeatInterval <= 86400, "Invalid interval");
        heartbeatInterval = _heartbeatInterval;
        emit HeartbeatIntervalUpdated(_heartbeatInterval);
    }

    /**
     * @notice Update max price age for a specific token
     * @param token Token address
     * @param _maxPriceAge New max price age (seconds)
     */
    function updateTokenMaxPriceAge(address token, uint256 _maxPriceAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(tokens[token].usdFeed != address(0), "Token not supported");
        require(_maxPriceAge > 0 && _maxPriceAge <= 3600 * 48, "Invalid price age");
        
        tokens[token].maxPriceAge = _maxPriceAge;
        emit TokenMaxPriceAgeUpdated(token, _maxPriceAge);
    }

    /* ========== Pause Control ========== */

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /* ========== Upgrade Control ========== */

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function getVersion() external pure returns (string memory) {
        return "2.0.0";
    }
}
