// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPUSDOracle {
    /* ========== Structs ========== */

    // Token management
    struct TokenConfig {
        address usdFeed; // Chainlink Token/USD price source
        address pusdOracle; // Token/PUSD oracle address
        uint256 tokenPusdPrice; // Token/PUSD price (18 decimal places)
        uint256 lastUpdated; // Last update time
    }

    /* ========== Events ========== */

    event TokenAdded(address indexed token, address usdFeed);
    event DebugPriceCheck(int256 price, uint256 updatedAt, uint256 currentTime, uint256 maxAge);
    event TokenPUSDPriceUpdated(address indexed token, uint256 newPrice, uint256 oldPrice);
    event PUSDUSDPriceUpdated(uint256 pusdUsdPrice, uint256 timestamp);
    event PUSDDepegDetected(uint256 deviation, uint256 depegCount);
    event PUSDDepegPauseTriggered(uint256 deviation);
    event PUSDDepegRecovered();
    event HeartbeatSent(uint256 timestamp);

    /* ========== Core Functions ========== */

    // ----------- Token management -----------
    function addToken(address token, address usdFeed, address pusdOracle) external;

    // ----------- Price updates -----------
    function updateTokenPUSDPrice(address token) external;

    function batchUpdateTokenPUSDPrices(address[] calldata tokenList) external;

    // ----------- Price queries -----------
    function getPUSDUSDPrice() external view returns (uint256 price, uint256 timestamp);

    function getTokenPUSDPrice(address token) external view returns (uint256 price, uint256 timestamp);

    function getTokenUSDPrice(address token) external view returns (uint256 price, uint256 timestamp);

    function getSupportedTokens() external view returns (address[] memory);

    function getTokenInfo(address token) external view returns (address usdFeed, uint256 tokenPusdPrice, uint256 lastUpdated);

    // ----------- Depeg & maintenance -----------
    function checkPUSDDepeg() external;

    function updateSystemParameters(uint256 _maxPriceAge, uint256 _heartbeatInterval) external;

    function updateDepegThresholds(uint256 _depegThreshold, uint256 _recoveryThreshold) external;

    function emergencyDisableToken(address token) external;

    function resetDepegCount() external;

    // ----------- Version control -----------
    function getVersion() external pure returns (string memory);
}
