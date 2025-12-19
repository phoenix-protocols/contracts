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
import "../interfaces/IUniswapOracle.sol";

/**
 * @title PUSDOracleUpgradeable
 * @notice Optimized PUSD price oracle management contract
 * @dev Balance function completeness and code simplicity
 *
 * Core design principles：
 * - Maintain original OracleManager simplicity
 * - Add necessary Token/PUSD price management functions
 *
 * Main features:
 * - Token/USD price: Get from Chainlink
 * - Token/PUSD price: Get from Uniswap Oracle
 * - PUSD/USD price: Calculated result
 * - Depeg detection and automatic pause
 */
contract PUSDOracleUpgradeable is Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, IPUSDOracle, PUSDOracleStorage {
    /* ========== initialize ========== */

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
        _grantRole(PRICE_UPDATER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        // Initialize parameters
        maxPriceAge = DEFAULT_MAX_PRICE_AGE;
        heartbeatInterval = DEFAULT_HEARTBEAT_INTERVAL;
        // Default initial price
        pusdUsdPrice = DEFAULT_PUSDUSD_PRICE;
        pusdDepegThreshold = DEFAULT_DEPEG_THRESHOLD;
        pusdRecoveryThreshold = DEFAULT_RECOVERY_THRESHOLD;
        lastHeartbeat = block.timestamp;
    }

    /* ========== Token management ========== */

    /**
     * @notice Add supported Token
     */
    function addToken(address token, address usdFeed, address pusdOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0) && usdFeed != address(0) && pusdOracle != address(0), "Invalid addresses");
        require(tokens[token].usdFeed == address(0), "Token already exists");

        // Verify USD price source
        AggregatorV3Interface feed = AggregatorV3Interface(usdFeed);
        (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();

        IUniswapOracle pusdPairOracle = IUniswapOracle(pusdOracle);
        (uint256 pusdPrice, uint256 timestamp) = pusdPairOracle.twapPrice1e18(token);
        require(pusdPrice > 0, "Invalid PUSD oracle");

        // Emit debug event to record all key values
        emit DebugPriceCheck(price, updatedAt, block.timestamp, maxPriceAge);

        // Separate checks to provide clearer error messages
        require(price > 0, "Price must be positive");
        require(block.timestamp >= updatedAt && block.timestamp >= timestamp, "Price timestamp in future");
        require(block.timestamp - updatedAt <= maxPriceAge, "Price data too old");
        require(block.timestamp - timestamp <= maxPriceAge, "PUSD price too old");

        tokens[token] = TokenConfig({usdFeed: usdFeed, pusdOracle: pusdOracle, tokenPusdPrice: pusdPrice, lastUpdated: block.timestamp});

        supportedTokens.push(token);

        // Recalculate PUSD/USD global price
        _updatePUSDUSDPrice();

        // Automatic depeg check
        _checkDepegInternal();

        emit TokenPUSDPriceUpdated(token, pusdPrice, 0);
        emit TokenAdded(token, usdFeed, pusdOracle);
    }

    /**
     * @notice Add DEX-only token support (no Chainlink feed needed, only Uniswap Token/PUSD pair)
     * @param token Token address (e.g., yPUSD)
     * @param pusdOracle Token/PUSD Uniswap oracle address
     * @dev For tokens without Chainlink USD feed, only need Uniswap Token/PUSD pair
     *      Price represents: 1 Token = X PUSD (e.g., 1.05e18 means 1 Token = 1.05 PUSD)
     */
    function addDexOnlyToken(address token, address pusdOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Invalid token address");
        require(pusdOracle != address(0), "Invalid oracle address");
        require(supportedDexOnlyTokens[token].pusdOracle == address(0), "Token already configured");
        require(tokens[token].usdFeed == address(0), "Token already has Chainlink feed, use addToken instead");

        // Verify oracle returns valid price
        IUniswapOracle oracle = IUniswapOracle(pusdOracle);
        (uint256 price, uint256 timestamp) = oracle.twapPrice1e18(token);
        require(price > 0, "Invalid oracle price");
        require(block.timestamp >= timestamp, "Price timestamp in future");
        require(block.timestamp - timestamp <= maxPriceAge, "Price too old");

        supportedDexOnlyTokens[token] = DexOnlyTokenConfig({
            pusdOracle: pusdOracle,
            tokenPusdPrice: price,
            lastUpdated: block.timestamp
        });

        supportedDexOnlyTokenList.push(token);

        emit DexOnlyTokenAdded(token, pusdOracle, price);
    }

    /**
     * @notice Update DEX-only token price from Uniswap oracle
     * @param token Token address to update
     */
    function updateDexOnlyTokenPrice(address token) external onlyRole(PRICE_UPDATER_ROLE) nonReentrant {
        DexOnlyTokenConfig storage config = supportedDexOnlyTokens[token];
        require(config.pusdOracle != address(0), "Token not configured as DEX-only");

        IUniswapOracle oracle = IUniswapOracle(config.pusdOracle);
        (uint256 price, uint256 timestamp) = oracle.twapPrice1e18(token);
        require(price > 0, "Invalid price");
        require(block.timestamp >= timestamp, "Price timestamp in future");
        require(block.timestamp - timestamp <= maxPriceAge, "Price too old");

        uint256 oldPrice = config.tokenPusdPrice;
        config.tokenPusdPrice = price;
        config.lastUpdated = block.timestamp;

        emit DexOnlyTokenPriceUpdated(token, price, oldPrice);
    }

    /**
     * @notice Batch update DEX-only token prices
     * @param tokenList Array of token addresses to update
     */
    function batchUpdateDexOnlyTokenPrices(address[] calldata tokenList) external onlyRole(PRICE_UPDATER_ROLE) nonReentrant {
        for (uint256 i = 0; i < tokenList.length; i++) {
            DexOnlyTokenConfig storage config = supportedDexOnlyTokens[tokenList[i]];
            if (config.pusdOracle != address(0)) {
                IUniswapOracle oracle = IUniswapOracle(config.pusdOracle);
                (uint256 price, uint256 timestamp) = oracle.twapPrice1e18(tokenList[i]);
                if (price > 0 && block.timestamp >= timestamp && block.timestamp - timestamp <= maxPriceAge) {
                    uint256 oldPrice = config.tokenPusdPrice;
                    config.tokenPusdPrice = price;
                    config.lastUpdated = block.timestamp;
                    emit DexOnlyTokenPriceUpdated(tokenList[i], price, oldPrice);
                }
            }
        }
    }

    /* ========== Price updates and calculations ========== */

    /**
     * @notice Update Token/PUSD price and recalculate PUSD/USD price
     * @param token Token contract address
     * @dev Example parameters:
     *      - 1 USDT = 2 PUSD, input: 2000000000000000000
     *      - 1 USDT = 1.5 PUSD, input: 1500000000000000000
     *      - In JavaScript: ethers.parseEther("2") or ethers.parseEther("1.5")
     */
    function updateTokenPUSDPrice(address token) external onlyRole(PRICE_UPDATER_ROLE) nonReentrant {
        TokenConfig storage config = tokens[token];
        require(config.usdFeed != address(0), "Token not supported");
        IUniswapOracle pusdPairOracle = IUniswapOracle(config.pusdOracle);
        (uint256 tokenPusdPrice, uint256 timestamp) = pusdPairOracle.twapPrice1e18(token);
        require(tokenPusdPrice > 0, "Invalid price");
        require(block.timestamp >= timestamp, "Price timestamp in future");
        require(block.timestamp - timestamp <= maxPriceAge, "PUSD price too old");

        uint256 oldPrice = config.tokenPusdPrice;
        config.tokenPusdPrice = tokenPusdPrice;
        config.lastUpdated = block.timestamp;

        // Recalculate PUSD/USD global price
        _updatePUSDUSDPrice();

        // Automatic depeg check
        _checkDepegInternal();

        emit TokenPUSDPriceUpdated(token, tokenPusdPrice, oldPrice);
    }

    /**
     * @notice Batch update prices and recalculate PUSD/USD price
     * @param tokenList Array of token contract addresses
     * @dev Example parameters:
     *      - prices = ["2000000000000000000", "1500000000000000000"]
     *      - In JavaScript: [ethers.parseEther("2"), ethers.parseEther("1.5")]
     */
    function batchUpdateTokenPUSDPrices(address[] calldata tokenList) external onlyRole(PRICE_UPDATER_ROLE) nonReentrant {
        require(tokenList.length > 0, "Invalid input");

        for (uint256 i = 0; i < tokenList.length; i++) {
            TokenConfig storage config = tokens[tokenList[i]];
            if (config.usdFeed != address(0)) {
                IUniswapOracle pusdPairOracle = IUniswapOracle(config.pusdOracle);
                (uint256 tokenPusdPrice, uint256 timestamp) = pusdPairOracle.twapPrice1e18(tokenList[i]);
                require(tokenPusdPrice > 0, "Invalid price");
                require(block.timestamp >= timestamp, "Price timestamp in future");
                require(block.timestamp - timestamp <= maxPriceAge, "PUSD price too old");
                uint256 oldPrice = config.tokenPusdPrice;
                config.tokenPusdPrice = tokenPusdPrice;
                config.lastUpdated = block.timestamp;

                emit TokenPUSDPriceUpdated(tokenList[i], tokenPusdPrice, oldPrice);
            }
        }

        // Recalculate PUSD/USD price after batch update
        _updatePUSDUSDPrice();

        // Automatic depeg check
        _checkDepegInternal();
    }

    /**
     * @notice Internal function: Calculate PUSD/USD weighted average price
     */
    function _updatePUSDUSDPrice() internal {
        uint256 totalWeight = 0;
        uint256 weightedSum = 0;
        uint256 earliestTimestamp = block.timestamp; // Initialize to current time, find earliest

        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            TokenConfig storage config = tokens[token];

            // Skip tokens without price or with expired price
            if (config.tokenPusdPrice == 0 || block.timestamp - config.lastUpdated > maxPriceAge) {
                continue;
            }

            // Get Token/USD price
            AggregatorV3Interface usdFeed = AggregatorV3Interface(config.usdFeed);
            (, int256 tokenUsdPriceInt, , uint256 usdTimestamp, ) = usdFeed.latestRoundData();

            // Skip invalid or expired USD price
            if (tokenUsdPriceInt <= 0 || block.timestamp - usdTimestamp > maxPriceAge) {
                continue;
            }

            // Normalize to 18 decimal places
            uint256 tokenUsdPrice = uint256(tokenUsdPriceInt);
            uint8 decimals = usdFeed.decimals();
            if (decimals < 18) {
                tokenUsdPrice = tokenUsdPrice * (10 ** (18 - decimals));
            } else if (decimals > 18) {
                tokenUsdPrice = tokenUsdPrice / (10 ** (decimals - 18));
            }

            // Calculate single Token's PUSD/USD price
            // tokenUsdPrice and config.tokenPusdPrice are both 18 decimal places
            // PUSD/USD = (Token/USD) ÷ (Token/PUSD)
            // To avoid precision loss, multiply by 1e18 first then divide
            uint256 singlePusdUsdPrice = (tokenUsdPrice * 1e18) / config.tokenPusdPrice;

            // Remove price range restrictions! Let system see real market conditions
            // No matter how abnormal the price, it should participate in calculation to make depeg detection work properly
            uint256 weight = _calculateSmartWeight(token, singlePusdUsdPrice, config);

            weightedSum += singlePusdUsdPrice * weight;
            totalWeight += weight;

            // Record earliest timestamp (aggregated price validity determined by oldest data)
            uint256 effectiveTimestamp = usdTimestamp < config.lastUpdated ? usdTimestamp : config.lastUpdated;
            if (effectiveTimestamp < earliestTimestamp) {
                earliestTimestamp = effectiveTimestamp;
            }
        }

        // Calculate weighted average price
        if (totalWeight > 0) {
            pusdUsdPrice = weightedSum / totalWeight;
            pusdPriceUpdated = earliestTimestamp; // Use earliest timestamp

            emit PUSDUSDPriceUpdated(pusdUsdPrice, pusdPriceUpdated);
        } else {
            // Use last valid price or default price
            revert("No valid price sources available");
        }
    }

    /* ========== Price queries ========== */

    /**
     * @notice Get PUSD/USD global price
     */
    function getPUSDUSDPrice() external view returns (uint256 price, uint256 timestamp) {
        require(pusdUsdPrice > 0, "PUSD price not available");
        require(block.timestamp - pusdPriceUpdated <= maxPriceAge, "PUSD price too old");

        price = pusdUsdPrice;
        timestamp = pusdPriceUpdated;
    }

    /**
     * @notice Get Token/PUSD price
     * @dev For DEX-only tokens (like yPUSD), returns price from Uniswap Token/PUSD oracle
     *      For other tokens, returns Token/PUSD price from configured Chainlink + Uniswap oracle
     *      In bootstrap mode, returns 1:1 price for whitelisted tokens
     */
    function getTokenPUSDPrice(address token) external view returns (uint256 price, uint256 timestamp) {
        // Bootstrap mode: return 1:1 price for whitelisted tokens (1 Token = 1e18 PUSD value)
        if (bootstrapMode && bootstrapTokens[token]) {
            return (1e18, block.timestamp);
        }

        // Check if it's a DEX-only token (no Chainlink feed)
        DexOnlyTokenConfig storage dexOnlyConfig = supportedDexOnlyTokens[token];
        if (dexOnlyConfig.pusdOracle != address(0)) {
            require(dexOnlyConfig.tokenPusdPrice > 0, "DEX-only token price not available");
            require(block.timestamp - dexOnlyConfig.lastUpdated <= maxPriceAge, "DEX-only token price too old");
            return (dexOnlyConfig.tokenPusdPrice, dexOnlyConfig.lastUpdated);
        }

        // Normal token handling (with Chainlink feed)
        TokenConfig storage config = tokens[token];
        require(config.usdFeed != address(0) && config.tokenPusdPrice > 0, "No price available");

        price = config.tokenPusdPrice;
        timestamp = config.lastUpdated;
    }

    /**
     * @notice Get Token/USD price
     * @param token Token contract address
     * @return price Token/USD price in 18 decimal format
     * @return timestamp Price update timestamp
     * @dev For tokens with Chainlink feed: Get directly from Chainlink and normalize to 18 decimals
     *      For DEX-only tokens: Calculate as Token/PUSD * PUSD/USD
     */
    function getTokenUSDPrice(address token) external view returns (uint256 price, uint256 timestamp) {
        // Check if it's a DEX-only token
        DexOnlyTokenConfig storage dexOnlyConfig = supportedDexOnlyTokens[token];
        if (dexOnlyConfig.pusdOracle != address(0)) {
            // DEX-only token: Token/USD = Token/PUSD * PUSD/USD
            require(dexOnlyConfig.tokenPusdPrice > 0, "DEX-only token price not available");
            require(block.timestamp - dexOnlyConfig.lastUpdated <= maxPriceAge, "DEX-only token price too old");
            require(pusdUsdPrice > 0, "PUSD/USD price not available");
            require(block.timestamp - pusdPriceUpdated <= maxPriceAge, "PUSD/USD price too old");

            // Token/USD = Token/PUSD * PUSD/USD / 1e18 (both are 18 decimals)
            price = (dexOnlyConfig.tokenPusdPrice * pusdUsdPrice) / 1e18;
            // Use the older timestamp for safety
            timestamp = dexOnlyConfig.lastUpdated < pusdPriceUpdated ? dexOnlyConfig.lastUpdated : pusdPriceUpdated;
            return (price, timestamp);
        }

        // Normal token: Get from Chainlink
        TokenConfig storage config = tokens[token];
        require(config.usdFeed != address(0), "Token not supported");

        // Get price from Chainlink
        AggregatorV3Interface usdFeed = AggregatorV3Interface(config.usdFeed);
        (, int256 tokenUsdPriceInt, , uint256 usdTimestamp, ) = usdFeed.latestRoundData();

        require(tokenUsdPriceInt > 0, "Invalid USD price");
        require(block.timestamp - usdTimestamp <= maxPriceAge, "USD price too old");

        // Normalize to 18 decimal places
        uint256 tokenUsdPrice = uint256(tokenUsdPriceInt);
        uint8 decimals = usdFeed.decimals();
        if (decimals < 18) {
            tokenUsdPrice = tokenUsdPrice * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            tokenUsdPrice = tokenUsdPrice / (10 ** (decimals - 18));
        }

        price = tokenUsdPrice;
        timestamp = usdTimestamp;
    }

    /* ========== PUSD depeg detection ========== */

    /**
     * @notice Manually check PUSD depeg (using global price)
     * @dev Keeper can manually call this function for depeg check
     */
    function checkPUSDDepeg() external onlyRole(PRICE_UPDATER_ROLE) nonReentrant {
        require(pusdUsdPrice > 0, "PUSD price not available");
        require(block.timestamp - pusdPriceUpdated <= maxPriceAge, "PUSD price too old");

        // Call internal check function
        _checkDepegInternal();
    }

    /* ========== Internal functions ========== */

    /**
     * @notice Simplified smart weight calculation
     * @param pusdPrice Currently calculated PUSD price
     * @return Calculated weight
     */
    function _calculateSmartWeight(
        address, // token - currently unused, reserved for future extension
        uint256 pusdPrice,
        TokenConfig storage
    ) internal pure returns (uint256) {
        // Calculate price deviation (deviation from $1.00)
        uint256 pegPrice = 1e18; // $1.00
        uint256 deviation;
        if (pusdPrice > pegPrice) {
            deviation = ((pusdPrice - pegPrice) * 10000) / pegPrice; // basis points
        } else {
            deviation = ((pegPrice - pusdPrice) * 10000) / pegPrice; // basis points
        }

        // Optimized weight calculation: More fine-grained weight allocation
        if (deviation <= 100) {
            // Deviation <= 1%
            return 10; // Maximum weight - very trusted
        } else if (deviation <= 200) {
            // Deviation <= 2%
            return 8; // High weight - very trusted
        } else if (deviation <= 300) {
            // Deviation <= 3%
            return 5; // Medium weight - generally trusted
        } else if (deviation <= 500) {
            // Deviation <= 5%
            return 3; // Low weight - less trusted
        } else if (deviation <= 1000) {
            // Deviation <= 10%
            return 2; // Very low weight - but still meaningful
        } else {
            // Deviation > 10%
            return 1; // Minimum weight - possibly abnormal but don't ignore
        }
    }

    /**
     * @notice Internal depeg check function
     * @dev Automatically called after price updates, no permission check needed
     */
    function _checkDepegInternal() internal {
        // Check if there's valid PUSD price
        if (pusdUsdPrice == 0 || block.timestamp - pusdPriceUpdated > maxPriceAge) {
            return; // No valid price, skip check
        }

        // Calculate deviation from $1.00
        uint256 pegPrice = 1e18; // $1.00
        uint256 deviation;
        if (pusdUsdPrice > pegPrice) {
            deviation = ((pusdUsdPrice - pegPrice) * 10000) / pegPrice;
        } else {
            deviation = ((pegPrice - pusdUsdPrice) * 10000) / pegPrice;
        }

        if (deviation > pusdDepegThreshold) {
            pusdDepegCount++;
            emit PUSDDepegDetected(deviation, pusdDepegCount);

            if (pusdDepegCount >= MAX_DEPEG_COUNT && !vault.paused()) {
                vault.pause();
                emit PUSDDepegPauseTriggered(deviation);
            }
        } else if (deviation <= pusdRecoveryThreshold && pusdDepegCount > 0) {
            pusdDepegCount = 0;
            emit PUSDDepegRecovered();

            if (vault.paused()) {
                vault.unpause();
            }
        }

        // Send heartbeat
        _sendHeartbeat();
    }

    function _sendHeartbeat() internal {
        vault.heartbeat();
        lastHeartbeat = block.timestamp;
        emit HeartbeatSent(block.timestamp);
    }

    /**
     * @notice Send heartbeat to Vault (for bootstrap mode or manual refresh)
     * @dev Allows PRICE_UPDATER_ROLE to send heartbeat without updating prices
     */
    function sendHeartbeat() external onlyRole(PRICE_UPDATER_ROLE) {
        _sendHeartbeat();
    }

    /* ========== Query functions ========== */

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    function getTokenInfo(address token) external view returns (address usdFeed, uint256 tokenPusdPrice, uint256 lastUpdated) {
        TokenConfig storage config = tokens[token];
        return (config.usdFeed, config.tokenPusdPrice, config.lastUpdated);
    }

    /**
     * @notice Get all DEX-only tokens (tokens without Chainlink feed)
     */
    function getSupportedDexOnlyTokens() external view returns (address[] memory) {
        return supportedDexOnlyTokenList;
    }

    /**
     * @notice Get DEX-only token info
     * @param token Token address
     * @return pusdOracle Oracle address
     * @return tokenPusdPrice Current Token/PUSD price
     * @return lastUpdated Last update timestamp
     */
    function getDexOnlyTokenInfo(address token) external view returns (
        address pusdOracle,
        uint256 tokenPusdPrice,
        uint256 lastUpdated
    ) {
        DexOnlyTokenConfig storage config = supportedDexOnlyTokens[token];
        return (config.pusdOracle, config.tokenPusdPrice, config.lastUpdated);
    }

    /**
     * @notice Check if a token is a DEX-only token
     */
    function isDexOnlyToken(address token) external view returns (bool) {
        return supportedDexOnlyTokens[token].pusdOracle != address(0);
    }

    /* ========== Management functions ========== */

    // Update system parameters
    function updateSystemParameters(uint256 _maxPriceAge, uint256 _heartbeatInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxPriceAge > 0 && _maxPriceAge <= 3600 * 48, "Invalid price age"); // Maximum 48 hours
        require(_heartbeatInterval > 0 && _heartbeatInterval <= 86400, "Invalid interval"); // Maximum 1 day

        maxPriceAge = _maxPriceAge;
        heartbeatInterval = _heartbeatInterval;
    }

    // Update depeg thresholds
    function updateDepegThresholds(uint256 _depegThreshold, uint256 _recoveryThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_depegThreshold > _recoveryThreshold, "Invalid thresholds");
        require(_depegThreshold <= 2000, "Depeg threshold too high"); // Maximum 20%

        pusdDepegThreshold = _depegThreshold;
        pusdRecoveryThreshold = _recoveryThreshold;
    }

    function emergencyDisableToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokens[token].usdFeed = address(0); // Disable by clearing usdFeed
    }

    /**
     * @notice Remove a DEX-only token (set oracle to zero address)
     */
    function removeDexOnlyToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(supportedDexOnlyTokens[token].pusdOracle != address(0), "Token not configured");
        delete supportedDexOnlyTokens[token];
        emit DexOnlyTokenRemoved(token);
    }

    function resetDepegCount() external onlyRole(DEFAULT_ADMIN_ROLE) {
        pusdDepegCount = 0;
    }

    /* ========== Bootstrap Mode ========== */

    /**
     * @notice Enable bootstrap mode for system initialization
     * @dev In bootstrap mode, whitelisted tokens return 1:1 pricing
     *      This allows initial PUSD minting before DEX liquidity exists
     */
    function enableBootstrapMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        bootstrapMode = true;
        emit BootstrapModeEnabled();
    }

    /**
     * @notice Disable bootstrap mode after DEX liquidity is established
     * @dev Should be called after initial PUSD is minted and DEX pairs are created
     */
    function disableBootstrapMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        bootstrapMode = false;
        emit BootstrapModeDisabled();
    }

    /**
     * @notice Add a token to the bootstrap whitelist
     * @param token Token address to allow 1:1 pricing in bootstrap mode
     */
    function addBootstrapToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Invalid token");
        bootstrapTokens[token] = true;
        emit BootstrapTokenAdded(token);
    }

    /**
     * @notice Remove a token from the bootstrap whitelist
     * @param token Token address to remove from bootstrap pricing
     */
    function removeBootstrapToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bootstrapTokens[token] = false;
        emit BootstrapTokenRemoved(token);
    }

    /**
     * @notice Check if a token can use bootstrap pricing
     */
    function isBootstrapToken(address token) external view returns (bool) {
        return bootstrapMode && bootstrapTokens[token];
    }

    /* ========== Upgrade control ========== */

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function getVersion() external pure returns (string memory) {
        return "1.0.0";
    }
}
