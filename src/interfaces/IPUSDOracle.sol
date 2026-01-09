// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPUSDOracle
 * @notice Simplified PUSD Oracle interface
 * @dev Primary market design: PUSD/USD = 1 (constant)
 *      Only uses Chainlink feeds for Token/USD pricing
 *      Secondary market (DEX) prices are independent and handled by arbitrage
 */
interface IPUSDOracle {
    /* ========== Structs ========== */

    // Token config with per-token price age setting
    struct TokenConfig {
        address usdFeed;      // Chainlink Token/USD price source
        uint256 maxPriceAge;  // Max price age for this token (seconds)
    }

    /* ========== Events ========== */

    event TokenAdded(address indexed token, address usdFeed);
    event TokenRemoved(address indexed token);
    event HeartbeatSent(uint256 timestamp);
    event HeartbeatIntervalUpdated(uint256 heartbeatInterval);
    event TokenMaxPriceAgeUpdated(address indexed token, uint256 maxPriceAge);

    /* ========== Core Functions ========== */

    // ----------- Token management -----------
    function addToken(address token, address usdFeed, uint256 maxPriceAge) external;

    function removeToken(address token) external;

    // ----------- Price queries -----------
    
    /**
     * @notice Get PUSD/USD price (always returns $1.00)
     * @dev Primary market price - PUSD is always worth $1 within the protocol
     * @return price Always 1e18 (representing $1.00)
     * @return timestamp Current block timestamp
     */
    function getPUSDUSDPrice() external view returns (uint256 price, uint256 timestamp);

    /**
     * @notice Get Token/PUSD price
     * @dev Since PUSD = $1 in primary market, Token/PUSD = Token/USD
     * @param token Token address
     * @return price Token price in PUSD (18 decimals)
     * @return timestamp Chainlink price update timestamp
     */
    function getTokenPUSDPrice(address token) external view returns (uint256 price, uint256 timestamp);

    /**
     * @notice Get Token/USD price from Chainlink
     * @param token Token address
     * @return price Token price in USD (18 decimals)
     * @return timestamp Chainlink price update timestamp
     */
    function getTokenUSDPrice(address token) external view returns (uint256 price, uint256 timestamp);

    function getSupportedTokens() external view returns (address[] memory);

    function getTokenInfo(address token) external view returns (address usdFeed, uint256 maxPriceAge);

    // ----------- Heartbeat -----------
    function sendHeartbeat() external;

    // ----------- System parameters -----------
    function updateHeartbeatInterval(uint256 _heartbeatInterval) external;
    function updateTokenMaxPriceAge(address token, uint256 _maxPriceAge) external;

    // ----------- Version control -----------
    function getVersion() external pure returns (string memory);
}