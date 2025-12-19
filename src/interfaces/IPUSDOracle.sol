// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPUSDOracle {
    /* ========== Structs ========== */

    // Token with Chainlink feed
    struct TokenConfig {
        address usdFeed; // Chainlink Token/USD price source
        address pusdOracle; // Token/PUSD oracle address
        uint256 tokenPusdPrice; // Token/PUSD price (18 decimal places)
        uint256 lastUpdated; // Last update time
    }

    // DEX-only token (no Chainlink feed, only Uniswap Token/PUSD pair)
    // For tokens like yPUSD that don't have Chainlink USD feed
    struct DexOnlyTokenConfig {
        address pusdOracle;      // Uniswap Token/PUSD oracle address
        uint256 tokenPusdPrice;  // Token/PUSD price (18 decimals), e.g. 1.05e18 means 1 Token = 1.05 PUSD
        uint256 lastUpdated;     // Price last update time
    }

    /* ========== Events ========== */

    event TokenAdded(address indexed token, address usdFeed, address pusdOracle);
    event DebugPriceCheck(int256 price, uint256 updatedAt, uint256 currentTime, uint256 maxAge);
    event TokenPUSDPriceUpdated(address indexed token, uint256 newPrice, uint256 oldPrice);
    event PUSDUSDPriceUpdated(uint256 pusdUsdPrice, uint256 timestamp);
    event PUSDDepegDetected(uint256 deviation, uint256 depegCount);
    event PUSDDepegPauseTriggered(uint256 deviation);
    event PUSDDepegRecovered();
    event HeartbeatSent(uint256 timestamp);
    // DEX-only token events (tokens without Chainlink feed, only Uniswap Token/PUSD pair)
    event DexOnlyTokenAdded(address indexed token, address oracle, uint256 initialPrice);
    event DexOnlyTokenPriceUpdated(address indexed token, uint256 newPrice, uint256 oldPrice);
    event DexOnlyTokenRemoved(address indexed token);
    // Bootstrap mode events
    event BootstrapModeEnabled();
    event BootstrapModeDisabled();
    event BootstrapTokenAdded(address indexed token);
    event BootstrapTokenRemoved(address indexed token);

    /* ========== Core Functions ========== */

    // ----------- Token management -----------
    function addToken(address token, address usdFeed, address pusdOracle) external;

    // ----------- DEX-only token management (no Chainlink feed) -----------
    function addDexOnlyToken(address token, address pusdOracle) external;

    function updateDexOnlyTokenPrice(address token) external;

    function batchUpdateDexOnlyTokenPrices(address[] calldata tokenList) external;

    // ----------- Price updates -----------
    function updateTokenPUSDPrice(address token) external;

    function batchUpdateTokenPUSDPrices(address[] calldata tokenList) external;

    // ----------- Price queries -----------
    function getPUSDUSDPrice() external view returns (uint256 price, uint256 timestamp);

    function getTokenPUSDPrice(address token) external view returns (uint256 price, uint256 timestamp);

    function getTokenUSDPrice(address token) external view returns (uint256 price, uint256 timestamp);

    function getSupportedTokens() external view returns (address[] memory);

    function getTokenInfo(address token) external view returns (address usdFeed, uint256 tokenPusdPrice, uint256 lastUpdated);

    // ----------- DEX-only token queries -----------
    function getSupportedDexOnlyTokens() external view returns (address[] memory);

    function getDexOnlyTokenInfo(address token) external view returns (
        address pusdOracle,
        uint256 tokenPusdPrice,
        uint256 lastUpdated
    );

    function isDexOnlyToken(address token) external view returns (bool);

    // ----------- Depeg & maintenance -----------
    function checkPUSDDepeg() external;

    function updateSystemParameters(uint256 _maxPriceAge, uint256 _heartbeatInterval) external;

    function updateDepegThresholds(uint256 _depegThreshold, uint256 _recoveryThreshold) external;

    function emergencyDisableToken(address token) external;

    function removeDexOnlyToken(address token) external;

    function resetDepegCount() external;

    // ----------- Bootstrap mode -----------
    function enableBootstrapMode() external;

    function disableBootstrapMode() external;

    function addBootstrapToken(address token) external;

    function removeBootstrapToken(address token) external;

    function isBootstrapToken(address token) external view returns (bool);

    // ----------- Version control -----------
    function getVersion() external pure returns (string memory);
}