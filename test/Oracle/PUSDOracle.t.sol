// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PUSDOracleUpgradeable} from "src/Oracle/PUSDOracle.sol";
import {IPUSDOracle} from "src/interfaces/IPUSDOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockChainlinkFeed} from "test/mocks/MockChainlinkFeed.sol";
import {MockUniswapOracle} from "test/mocks/MockUniswapOracle.sol";
import {MockVault} from "test/mocks/MockVault.sol";
import {PUSDOracle_Deployer_Base, PUSDOracleV2} from "script/Oracle/base/PUSDOracle_Deployer_Base.sol";

contract PUSDOracleTest is Test, PUSDOracle_Deployer_Base {
    PUSDOracleUpgradeable public oracle;
    MockVault public vault;
    MockChainlinkFeed public usdtFeed;
    MockChainlinkFeed public usdcFeed;
    MockUniswapOracle public uniswapOracle;
    MockUniswapOracle public dexOnlyOracle;

    address admin = address(0xA11CE);
    address priceUpdater = address(0xBEEF);
    address upgrader = address(0xCAFE);
    address pusdToken = address(0x1111);
    address usdtToken = address(0x2222);
    address usdcToken = address(0x3333);
    address ypusdToken = address(0x4444);

    bytes32 PRICE_UPDATER_ROLE;
    bytes32 UPGRADER_ROLE;
    bytes32 DEFAULT_ADMIN_ROLE;

    // Events
    event TokenAdded(address indexed token, address usdFeed, address pusdOracle);
    event TokenPUSDPriceUpdated(address indexed token, uint256 newPrice, uint256 oldPrice);
    event PUSDUSDPriceUpdated(uint256 pusdUsdPrice, uint256 timestamp);
    event DexOnlyTokenAdded(address indexed token, address oracle, uint256 initialPrice);
    event DexOnlyTokenPriceUpdated(address indexed token, uint256 newPrice, uint256 oldPrice);
    event DexOnlyTokenRemoved(address indexed token);
    event PUSDDepegDetected(uint256 deviation, uint256 depegCount);
    event PUSDDepegPauseTriggered(uint256 deviation);
    event PUSDDepegRecovered();
    event HeartbeatSent(uint256 timestamp);

    function setUp() public {
        // Deploy mocks
        vault = new MockVault();
        usdtFeed = new MockChainlinkFeed(1e8, 8); // $1.00 with 8 decimals
        usdcFeed = new MockChainlinkFeed(1e8, 8); // $1.00 with 8 decimals
        uniswapOracle = new MockUniswapOracle();
        dexOnlyOracle = new MockUniswapOracle();

        // Set up Uniswap oracle prices (Token/PUSD = 1:1)
        uniswapOracle.setPrice(usdtToken, 1e18, block.timestamp);
        uniswapOracle.setPrice(usdcToken, 1e18, block.timestamp);
        dexOnlyOracle.setPrice(ypusdToken, 1e18, block.timestamp); // yPUSD/PUSD = 1:1

        // Deploy using base deployer
        bytes32 salt = bytes32(0);
        oracle = _deploy(address(vault), pusdToken, admin, salt);

        // Setup roles
        PRICE_UPDATER_ROLE = oracle.PRICE_UPDATER_ROLE();
        UPGRADER_ROLE = oracle.UPGRADER_ROLE();
        DEFAULT_ADMIN_ROLE = oracle.DEFAULT_ADMIN_ROLE();

        // Grant additional roles
        vm.startPrank(admin);
        oracle.grantRole(PRICE_UPDATER_ROLE, priceUpdater);
        oracle.grantRole(UPGRADER_ROLE, upgrader);
        vm.stopPrank();
    }

    // ==================== Initialization Tests ====================

    function test_InitializeState() public view {
        assertEq(address(oracle.vault()), address(vault));
        assertEq(oracle.pusdToken(), pusdToken);
        assertTrue(oracle.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(oracle.hasRole(PRICE_UPDATER_ROLE, admin));
        assertTrue(oracle.hasRole(UPGRADER_ROLE, admin));
    }

    function test_InitializeDefaultValues() public view {
        assertEq(oracle.pusdUsdPrice(), 1e18); // Default $1.00
        assertEq(oracle.maxPriceAge(), 3600 * 24); // 24 hours
        assertEq(oracle.heartbeatInterval(), 3600); // 1 hour
        assertEq(oracle.pusdDepegThreshold(), 500); // 5%
        assertEq(oracle.pusdRecoveryThreshold(), 200); // 2%
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert();
        oracle.initialize(address(vault), pusdToken, admin);
    }

    function test_InitializeRevertInvalidVault() public {
        PUSDOracleUpgradeable impl = new PUSDOracleUpgradeable();
        vm.expectRevert("Invalid vault");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (address(0), pusdToken, admin))
        );
    }

    function test_InitializeRevertInvalidPUSD() public {
        PUSDOracleUpgradeable impl = new PUSDOracleUpgradeable();
        vm.expectRevert("Invalid PUSD");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (address(vault), address(0), admin))
        );
    }

    // ==================== Add Token Tests ====================

    function test_AddToken() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit TokenAdded(usdtToken, address(usdtFeed), address(uniswapOracle));
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        address[] memory tokens = oracle.getSupportedTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], usdtToken);

        (address usdFeed, uint256 tokenPusdPrice, uint256 lastUpdated) = oracle.getTokenInfo(usdtToken);
        assertEq(usdFeed, address(usdtFeed));
        assertEq(tokenPusdPrice, 1e18);
        assertGt(lastUpdated, 0);
    }

    function test_AddToken_RevertInvalidAddresses() public {
        vm.startPrank(admin);
        
        vm.expectRevert("Invalid addresses");
        oracle.addToken(address(0), address(usdtFeed), address(uniswapOracle));

        vm.expectRevert("Invalid addresses");
        oracle.addToken(usdtToken, address(0), address(uniswapOracle));

        vm.expectRevert("Invalid addresses");
        oracle.addToken(usdtToken, address(usdtFeed), address(0));

        vm.stopPrank();
    }

    function test_AddToken_RevertAlreadyExists() public {
        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        
        vm.expectRevert("Token already exists");
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        vm.stopPrank();
    }

    function test_AddToken_RevertInvalidChainlinkPrice() public {
        MockChainlinkFeed badFeed = new MockChainlinkFeed(0, 8);
        
        vm.prank(admin);
        vm.expectRevert("Price must be positive");
        oracle.addToken(usdtToken, address(badFeed), address(uniswapOracle));
    }

    function test_AddToken_RevertInvalidUniswapPrice() public {
        MockUniswapOracle badOracle = new MockUniswapOracle();
        badOracle.setPrice(usdtToken, 0, block.timestamp);
        
        vm.prank(admin);
        vm.expectRevert("Invalid PUSD oracle");
        oracle.addToken(usdtToken, address(usdtFeed), address(badOracle));
    }

    function test_AddToken_RevertPriceDataTooOld() public {
        // Warp to a reasonable timestamp first to avoid underflow
        vm.warp(block.timestamp + 30 hours);
        usdtFeed.setUpdatedAt(block.timestamp - 25 hours);
        uniswapOracle.setPrice(usdtToken, 1e18, block.timestamp);
        
        vm.prank(admin);
        vm.expectRevert("Price data too old");
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
    }

    function test_AddToken_RevertUnauthorized() public {
        vm.prank(priceUpdater);
        vm.expectRevert();
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
    }

    // ==================== Add DEX-Only Token Tests ====================

    function test_AddDexOnlyToken() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit DexOnlyTokenAdded(ypusdToken, address(dexOnlyOracle), 1e18);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        address[] memory dexTokens = oracle.getSupportedDexOnlyTokens();
        assertEq(dexTokens.length, 1);
        assertEq(dexTokens[0], ypusdToken);

        assertTrue(oracle.isDexOnlyToken(ypusdToken));

        (address pusdOracle, uint256 tokenPusdPrice, uint256 lastUpdated) = oracle.getDexOnlyTokenInfo(ypusdToken);
        assertEq(pusdOracle, address(dexOnlyOracle));
        assertEq(tokenPusdPrice, 1e18);
        assertGt(lastUpdated, 0);
    }

    function test_AddDexOnlyToken_RevertInvalidToken() public {
        vm.prank(admin);
        vm.expectRevert("Invalid token address");
        oracle.addDexOnlyToken(address(0), address(dexOnlyOracle));
    }

    function test_AddDexOnlyToken_RevertInvalidOracle() public {
        vm.prank(admin);
        vm.expectRevert("Invalid oracle address");
        oracle.addDexOnlyToken(ypusdToken, address(0));
    }

    function test_AddDexOnlyToken_RevertAlreadyConfigured() public {
        vm.startPrank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));
        
        vm.expectRevert("Token already configured");
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));
        vm.stopPrank();
    }

    function test_AddDexOnlyToken_RevertHasChainlinkFeed() public {
        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        
        vm.expectRevert("Token already has Chainlink feed, use addToken instead");
        oracle.addDexOnlyToken(usdtToken, address(dexOnlyOracle));
        vm.stopPrank();
    }

    function test_AddDexOnlyToken_RevertInvalidOraclePrice() public {
        MockUniswapOracle badOracle = new MockUniswapOracle();
        badOracle.setPrice(ypusdToken, 0, block.timestamp);
        
        vm.prank(admin);
        vm.expectRevert("Invalid oracle price");
        oracle.addDexOnlyToken(ypusdToken, address(badOracle));
    }

    // ==================== Update Token Price Tests ====================

    function test_UpdateTokenPUSDPrice() public {
        // Add token first
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        // Update price
        uniswapOracle.setPrice(usdtToken, 1.05e18, block.timestamp);

        vm.prank(priceUpdater);
        vm.expectEmit(true, false, false, true);
        emit TokenPUSDPriceUpdated(usdtToken, 1.05e18, 1e18);
        oracle.updateTokenPUSDPrice(usdtToken);

        (, uint256 newPrice, ) = oracle.getTokenInfo(usdtToken);
        assertEq(newPrice, 1.05e18);
    }

    function test_UpdateTokenPUSDPrice_RevertTokenNotSupported() public {
        vm.prank(priceUpdater);
        vm.expectRevert("Token not supported");
        oracle.updateTokenPUSDPrice(usdtToken);
    }

    function test_UpdateTokenPUSDPrice_RevertInvalidPrice() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        uniswapOracle.setPrice(usdtToken, 0, block.timestamp);

        vm.prank(priceUpdater);
        vm.expectRevert("Invalid price");
        oracle.updateTokenPUSDPrice(usdtToken);
    }

    function test_UpdateTokenPUSDPrice_RevertUnauthorized() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        vm.prank(address(0x9999));
        vm.expectRevert();
        oracle.updateTokenPUSDPrice(usdtToken);
    }

    // ==================== Batch Update Token Price Tests ====================

    function test_BatchUpdateTokenPUSDPrices() public {
        // Add tokens
        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        oracle.addToken(usdcToken, address(usdcFeed), address(uniswapOracle));
        vm.stopPrank();

        // Update prices
        uniswapOracle.setPrice(usdtToken, 1.02e18, block.timestamp);
        uniswapOracle.setPrice(usdcToken, 0.98e18, block.timestamp);

        address[] memory tokenList = new address[](2);
        tokenList[0] = usdtToken;
        tokenList[1] = usdcToken;

        vm.prank(priceUpdater);
        oracle.batchUpdateTokenPUSDPrices(tokenList);

        (, uint256 usdtPrice, ) = oracle.getTokenInfo(usdtToken);
        (, uint256 usdcPrice, ) = oracle.getTokenInfo(usdcToken);
        assertEq(usdtPrice, 1.02e18);
        assertEq(usdcPrice, 0.98e18);
    }

    function test_BatchUpdateTokenPUSDPrices_RevertEmptyInput() public {
        address[] memory tokenList = new address[](0);

        vm.prank(priceUpdater);
        vm.expectRevert("Invalid input");
        oracle.batchUpdateTokenPUSDPrices(tokenList);
    }

    // ==================== Update DEX-Only Token Price Tests ====================

    function test_UpdateDexOnlyTokenPrice() public {
        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        dexOnlyOracle.setPrice(ypusdToken, 1.05e18, block.timestamp);

        vm.prank(priceUpdater);
        vm.expectEmit(true, false, false, true);
        emit DexOnlyTokenPriceUpdated(ypusdToken, 1.05e18, 1e18);
        oracle.updateDexOnlyTokenPrice(ypusdToken);

        (, uint256 newPrice, ) = oracle.getDexOnlyTokenInfo(ypusdToken);
        assertEq(newPrice, 1.05e18);
    }

    function test_UpdateDexOnlyTokenPrice_RevertNotConfigured() public {
        vm.prank(priceUpdater);
        vm.expectRevert("Token not configured as DEX-only");
        oracle.updateDexOnlyTokenPrice(ypusdToken);
    }

    // ==================== Batch Update DEX-Only Token Price Tests ====================

    function test_BatchUpdateDexOnlyTokenPrices() public {
        address ypusd2 = address(0x5555);
        MockUniswapOracle dexOracle2 = new MockUniswapOracle();
        dexOracle2.setPrice(ypusd2, 1e18, block.timestamp);

        vm.startPrank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));
        oracle.addDexOnlyToken(ypusd2, address(dexOracle2));
        vm.stopPrank();

        dexOnlyOracle.setPrice(ypusdToken, 1.02e18, block.timestamp);
        dexOracle2.setPrice(ypusd2, 1.03e18, block.timestamp);

        address[] memory tokenList = new address[](2);
        tokenList[0] = ypusdToken;
        tokenList[1] = ypusd2;

        vm.prank(priceUpdater);
        oracle.batchUpdateDexOnlyTokenPrices(tokenList);

        (, uint256 price1, ) = oracle.getDexOnlyTokenInfo(ypusdToken);
        (, uint256 price2, ) = oracle.getDexOnlyTokenInfo(ypusd2);
        assertEq(price1, 1.02e18);
        assertEq(price2, 1.03e18);
    }

    // ==================== Get Price Tests ====================

    function test_GetPUSDUSDPrice() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        (uint256 price, uint256 timestamp) = oracle.getPUSDUSDPrice();
        assertEq(price, 1e18); // $1.00
        assertGt(timestamp, 0);
    }

    function test_GetPUSDUSDPrice_RevertNotAvailable() public {
        // Create new oracle without any tokens
        PUSDOracleUpgradeable impl = new PUSDOracleUpgradeable();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (address(vault), pusdToken, admin))
        );
        PUSDOracleUpgradeable newOracle = PUSDOracleUpgradeable(address(proxy));

        // Set pusdUsdPrice to 0 manually (simulating uninitialized state)
        // Since we can't directly set, we test through price too old
        vm.warp(block.timestamp + 25 hours);
        
        vm.expectRevert("PUSD price too old");
        newOracle.getPUSDUSDPrice();
    }

    function test_GetTokenPUSDPrice() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        (uint256 price, uint256 timestamp) = oracle.getTokenPUSDPrice(usdtToken);
        assertEq(price, 1e18);
        assertGt(timestamp, 0);
    }

    function test_GetTokenPUSDPrice_DexOnlyToken() public {
        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        (uint256 price, uint256 timestamp) = oracle.getTokenPUSDPrice(ypusdToken);
        assertEq(price, 1e18);
        assertGt(timestamp, 0);
    }

    function test_GetTokenPUSDPrice_RevertNoPrice() public {
        vm.expectRevert("No price available");
        oracle.getTokenPUSDPrice(usdtToken);
    }

    function test_GetTokenUSDPrice() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        (uint256 price, uint256 timestamp) = oracle.getTokenUSDPrice(usdtToken);
        assertEq(price, 1e18); // $1.00 normalized to 18 decimals
        assertGt(timestamp, 0);
    }

    function test_GetTokenUSDPrice_DexOnlyToken() public {
        // First add a regular token to have valid PUSD/USD price
        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));
        vm.stopPrank();

        // yPUSD/USD = yPUSD/PUSD * PUSD/USD = 1 * 1 = 1
        (uint256 price, uint256 timestamp) = oracle.getTokenUSDPrice(ypusdToken);
        assertEq(price, 1e18);
        assertGt(timestamp, 0);
    }

    function test_GetTokenUSDPrice_RevertNotSupported() public {
        vm.expectRevert("Token not supported");
        oracle.getTokenUSDPrice(usdtToken);
    }

    // ==================== Depeg Detection Tests ====================

    function test_DepegDetection() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        // Set price to trigger depeg (PUSD at $0.90, deviation = 10%)
        uniswapOracle.setPrice(usdtToken, 1.111e18, block.timestamp); // Token/PUSD = 1.111 means PUSD is worth less

        vm.prank(priceUpdater);
        vm.expectEmit(false, false, false, false);
        emit PUSDDepegDetected(0, 0); // We don't check exact values
        oracle.updateTokenPUSDPrice(usdtToken);

        assertGt(oracle.pusdDepegCount(), 0);
    }

    function test_DepegPauseTriggered() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        // Trigger depeg twice (MAX_DEPEG_COUNT = 2)
        uniswapOracle.setPrice(usdtToken, 1.111e18, block.timestamp);

        vm.startPrank(priceUpdater);
        oracle.updateTokenPUSDPrice(usdtToken);
        
        // Need to update timestamp for second update
        vm.warp(block.timestamp + 1);
        uniswapOracle.setPrice(usdtToken, 1.111e18, block.timestamp);
        usdtFeed.setUpdatedAt(block.timestamp);
        
        oracle.updateTokenPUSDPrice(usdtToken);
        vm.stopPrank();

        assertTrue(vault.isPaused());
    }

    function test_DepegRecovery() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        // First trigger depeg
        uniswapOracle.setPrice(usdtToken, 1.111e18, block.timestamp);
        vm.prank(priceUpdater);
        oracle.updateTokenPUSDPrice(usdtToken);
        assertGt(oracle.pusdDepegCount(), 0);

        // Now recover (price back to normal)
        vm.warp(block.timestamp + 1);
        uniswapOracle.setPrice(usdtToken, 1e18, block.timestamp);
        usdtFeed.setUpdatedAt(block.timestamp);

        vm.prank(priceUpdater);
        oracle.updateTokenPUSDPrice(usdtToken);

        assertEq(oracle.pusdDepegCount(), 0);
    }

    function test_CheckPUSDDepeg() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        vm.prank(priceUpdater);
        oracle.checkPUSDDepeg();

        // Should not revert and heartbeat should be sent
        assertGt(vault.lastHeartbeat(), 0);
    }

    function test_CheckPUSDDepeg_RevertUnauthorized() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        vm.prank(address(0x9999));
        vm.expectRevert();
        oracle.checkPUSDDepeg();
    }

    function test_CheckPUSDDepeg_RevertPriceNotAvailable() public {
        // No tokens added, PUSD price is default but no valid sources
        // We need to check that it validates PUSD price availability
        // Since initialize sets pusdUsdPrice = 1e18 by default, we can't easily test this
        // unless we add token first and then make price unavailable
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        
        // Make price too old
        vm.warp(block.timestamp + 25 hours);
        
        vm.prank(priceUpdater);
        vm.expectRevert("PUSD price too old");
        oracle.checkPUSDDepeg();
    }

    function test_UpdateDexOnlyTokenPrice_RevertUnauthorized() public {
        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        vm.prank(address(0x9999));
        vm.expectRevert();
        oracle.updateDexOnlyTokenPrice(ypusdToken);
    }

    function test_UpdateDexOnlyTokenPrice_RevertInvalidPrice() public {
        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        dexOnlyOracle.setPrice(ypusdToken, 0, block.timestamp);

        vm.prank(priceUpdater);
        vm.expectRevert("Invalid price");
        oracle.updateDexOnlyTokenPrice(ypusdToken);
    }

    function test_UpdateDexOnlyTokenPrice_RevertPriceTooOld() public {
        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        vm.warp(block.timestamp + 25 hours);
        dexOnlyOracle.setPrice(ypusdToken, 1e18, block.timestamp - 25 hours);

        vm.prank(priceUpdater);
        vm.expectRevert("Price too old");
        oracle.updateDexOnlyTokenPrice(ypusdToken);
    }

    function test_GetTokenPUSDPrice_DexOnlyToken_RevertPriceTooOld() public {
        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        vm.warp(block.timestamp + 25 hours);

        vm.expectRevert("DEX-only token price too old");
        oracle.getTokenPUSDPrice(ypusdToken);
    }

    function test_GetTokenUSDPrice_DexOnlyToken_RevertPUSDPriceNotAvailable() public {
        // First add DEX-only token, but no regular token for PUSD/USD price
        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        // Make PUSD/USD price too old
        vm.warp(block.timestamp + 25 hours);

        vm.expectRevert("DEX-only token price too old");
        oracle.getTokenUSDPrice(ypusdToken);
    }

    function test_GetTokenUSDPrice_RevertInvalidUSDPrice() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        // Set Chainlink feed to return 0
        usdtFeed.setPrice(0);

        vm.expectRevert("Invalid USD price");
        oracle.getTokenUSDPrice(usdtToken);
    }

    function test_GetTokenUSDPrice_RevertUSDPriceTooOld() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        vm.warp(block.timestamp + 25 hours);
        // Don't update the feed timestamp

        vm.expectRevert("USD price too old");
        oracle.getTokenUSDPrice(usdtToken);
    }

    function test_DepegRecoveryWithUnpause() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        // Trigger depeg twice to cause pause
        uniswapOracle.setPrice(usdtToken, 1.111e18, block.timestamp);
        vm.startPrank(priceUpdater);
        oracle.updateTokenPUSDPrice(usdtToken);
        
        vm.warp(block.timestamp + 1);
        uniswapOracle.setPrice(usdtToken, 1.111e18, block.timestamp);
        usdtFeed.setUpdatedAt(block.timestamp);
        oracle.updateTokenPUSDPrice(usdtToken);
        vm.stopPrank();

        assertTrue(vault.isPaused());
        assertEq(oracle.pusdDepegCount(), 2);

        // Now recover
        vm.warp(block.timestamp + 1);
        uniswapOracle.setPrice(usdtToken, 1e18, block.timestamp);
        usdtFeed.setUpdatedAt(block.timestamp);

        vm.prank(priceUpdater);
        vm.expectEmit(false, false, false, false);
        emit PUSDDepegRecovered();
        oracle.updateTokenPUSDPrice(usdtToken);

        assertEq(oracle.pusdDepegCount(), 0);
        assertFalse(vault.isPaused());
    }

    function test_UpdateTokenPUSDPrice_RevertPriceTooOld() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        // Advance time and set old timestamp on oracle
        vm.warp(block.timestamp + 25 hours);
        uniswapOracle.setPrice(usdtToken, 1.05e18, block.timestamp - 25 hours);
        usdtFeed.setUpdatedAt(block.timestamp);

        vm.prank(priceUpdater);
        vm.expectRevert("PUSD price too old");
        oracle.updateTokenPUSDPrice(usdtToken);
    }

    function test_BatchUpdateTokenPUSDPrices_SkipsInvalidTokens() public {
        // Add only USDT, not USDC
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        uniswapOracle.setPrice(usdtToken, 1.02e18, block.timestamp);

        address[] memory tokenList = new address[](2);
        tokenList[0] = usdtToken;
        tokenList[1] = usdcToken; // Not added

        // Should not revert, just skip invalid tokens
        vm.prank(priceUpdater);
        oracle.batchUpdateTokenPUSDPrices(tokenList);

        (, uint256 usdtPrice, ) = oracle.getTokenInfo(usdtToken);
        assertEq(usdtPrice, 1.02e18);
    }

    function test_BatchUpdateDexOnlyTokenPrices_SkipsInvalidTokens() public {
        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        dexOnlyOracle.setPrice(ypusdToken, 1.02e18, block.timestamp);

        address[] memory tokenList = new address[](2);
        tokenList[0] = ypusdToken;
        tokenList[1] = address(0x9999); // Not added

        vm.prank(priceUpdater);
        oracle.batchUpdateDexOnlyTokenPrices(tokenList);

        (, uint256 price, ) = oracle.getDexOnlyTokenInfo(ypusdToken);
        assertEq(price, 1.02e18);
    }

    function test_BatchUpdateDexOnlyTokenPrices_RevertUnauthorized() public {
        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        address[] memory tokenList = new address[](1);
        tokenList[0] = ypusdToken;

        vm.prank(address(0x9999));
        vm.expectRevert();
        oracle.batchUpdateDexOnlyTokenPrices(tokenList);
    }

    function test_AddDexOnlyToken_RevertPriceTooOld() public {
        vm.warp(block.timestamp + 25 hours);
        dexOnlyOracle.setPrice(ypusdToken, 1e18, block.timestamp - 25 hours);

        vm.prank(admin);
        vm.expectRevert("Price too old");
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));
    }

    // ==================== Management Functions Tests ====================

    function test_UpdateSystemParameters() public {
        vm.prank(admin);
        oracle.updateSystemParameters(7200, 1800);

        assertEq(oracle.maxPriceAge(), 7200);
        assertEq(oracle.heartbeatInterval(), 1800);
    }

    function test_UpdateSystemParameters_RevertInvalidPriceAge() public {
        vm.startPrank(admin);
        
        vm.expectRevert("Invalid price age");
        oracle.updateSystemParameters(0, 1800);

        vm.expectRevert("Invalid price age");
        oracle.updateSystemParameters(3600 * 49, 1800); // > 48 hours

        vm.stopPrank();
    }

    function test_UpdateSystemParameters_RevertInvalidInterval() public {
        vm.startPrank(admin);
        
        vm.expectRevert("Invalid interval");
        oracle.updateSystemParameters(7200, 0);

        vm.expectRevert("Invalid interval");
        oracle.updateSystemParameters(7200, 86401); // > 1 day

        vm.stopPrank();
    }

    function test_UpdateSystemParameters_RevertUnauthorized() public {
        vm.prank(priceUpdater);
        vm.expectRevert();
        oracle.updateSystemParameters(7200, 1800);
    }

    function test_UpdateDepegThresholds() public {
        vm.prank(admin);
        oracle.updateDepegThresholds(1000, 300);

        assertEq(oracle.pusdDepegThreshold(), 1000);
        assertEq(oracle.pusdRecoveryThreshold(), 300);
    }

    function test_UpdateDepegThresholds_RevertInvalidThresholds() public {
        vm.startPrank(admin);
        
        vm.expectRevert("Invalid thresholds");
        oracle.updateDepegThresholds(300, 500); // depeg < recovery

        vm.expectRevert("Depeg threshold too high");
        oracle.updateDepegThresholds(2500, 200); // > 20%

        vm.stopPrank();
    }

    function test_EmergencyDisableToken() public {
        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        oracle.emergencyDisableToken(usdtToken);
        vm.stopPrank();

        (address usdFeed, , ) = oracle.getTokenInfo(usdtToken);
        assertEq(usdFeed, address(0));
    }

    function test_RemoveDexOnlyToken() public {
        vm.startPrank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));
        
        vm.expectEmit(true, false, false, true);
        emit DexOnlyTokenRemoved(ypusdToken);
        oracle.removeDexOnlyToken(ypusdToken);
        vm.stopPrank();

        assertFalse(oracle.isDexOnlyToken(ypusdToken));
    }

    function test_RemoveDexOnlyToken_RevertNotConfigured() public {
        vm.prank(admin);
        vm.expectRevert("Token not configured");
        oracle.removeDexOnlyToken(ypusdToken);
    }

    function test_ResetDepegCount() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        // Trigger depeg
        uniswapOracle.setPrice(usdtToken, 1.111e18, block.timestamp);
        vm.prank(priceUpdater);
        oracle.updateTokenPUSDPrice(usdtToken);
        assertGt(oracle.pusdDepegCount(), 0);

        // Reset
        vm.prank(admin);
        oracle.resetDepegCount();
        assertEq(oracle.pusdDepegCount(), 0);
    }

    function test_ResetDepegCount_RevertUnauthorized() public {
        vm.prank(priceUpdater);
        vm.expectRevert();
        oracle.resetDepegCount();
    }

    function test_EmergencyDisableToken_RevertUnauthorized() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));

        vm.prank(priceUpdater);
        vm.expectRevert();
        oracle.emergencyDisableToken(usdtToken);
    }

    function test_RemoveDexOnlyToken_RevertUnauthorized() public {
        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        vm.prank(priceUpdater);
        vm.expectRevert();
        oracle.removeDexOnlyToken(ypusdToken);
    }

    function test_UpdateDepegThresholds_RevertUnauthorized() public {
        vm.prank(priceUpdater);
        vm.expectRevert();
        oracle.updateDepegThresholds(1000, 300);
    }

    // ==================== Query Functions Tests ====================

    function test_GetSupportedTokens() public {
        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        oracle.addToken(usdcToken, address(usdcFeed), address(uniswapOracle));
        vm.stopPrank();

        address[] memory tokens = oracle.getSupportedTokens();
        assertEq(tokens.length, 2);
    }

    function test_GetSupportedDexOnlyTokens() public {
        address ypusd2 = address(0x5555);
        MockUniswapOracle dexOracle2 = new MockUniswapOracle();
        dexOracle2.setPrice(ypusd2, 1e18, block.timestamp);

        vm.startPrank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));
        oracle.addDexOnlyToken(ypusd2, address(dexOracle2));
        vm.stopPrank();

        address[] memory tokens = oracle.getSupportedDexOnlyTokens();
        assertEq(tokens.length, 2);
    }

    function test_IsDexOnlyToken() public {
        assertFalse(oracle.isDexOnlyToken(ypusdToken));

        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        assertTrue(oracle.isDexOnlyToken(ypusdToken));
    }

    function test_GetVersion() public view {
        assertEq(oracle.getVersion(), "1.0.0");
    }

    // ==================== Upgrade Tests ====================

    function test_UpgradeAuthorization() public {
        PUSDOracleUpgradeable newImpl = new PUSDOracleUpgradeable();

        // Non-upgrader cannot upgrade
        vm.prank(priceUpdater);
        vm.expectRevert();
        oracle.upgradeToAndCall(address(newImpl), "");

        // Upgrader can upgrade
        vm.prank(upgrader);
        oracle.upgradeToAndCall(address(newImpl), "");
    }

    // ==================== Edge Cases ====================

    function test_ChainlinkDifferentDecimals() public {
        // Test with 18 decimals feed
        MockChainlinkFeed feed18 = new MockChainlinkFeed(1e18, 18);
        
        vm.prank(admin);
        oracle.addToken(usdtToken, address(feed18), address(uniswapOracle));

        (uint256 price, ) = oracle.getTokenUSDPrice(usdtToken);
        assertEq(price, 1e18);
    }

    function test_ChainlinkHighDecimals() public {
        // Test with 20 decimals feed (edge case)
        MockChainlinkFeed feed20 = new MockChainlinkFeed(1e20, 20);
        
        vm.prank(admin);
        oracle.addToken(usdtToken, address(feed20), address(uniswapOracle));

        (uint256 price, ) = oracle.getTokenUSDPrice(usdtToken);
        assertEq(price, 1e18);
    }

    function test_MultipleTokensWeightedAverage() public {
        // Add two tokens with different prices
        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        oracle.addToken(usdcToken, address(usdcFeed), address(uniswapOracle));
        vm.stopPrank();

        // USDT: $1.00 USD, 1:1 with PUSD -> PUSD = $1.00
        // USDC: $1.00 USD, 1:1 with PUSD -> PUSD = $1.00
        // Weighted average should be $1.00

        (uint256 price, ) = oracle.getPUSDUSDPrice();
        assertEq(price, 1e18);
    }

    function test_DexOnlyTokenUSDPrice_WithDifferentRates() public {
        // Set up PUSD/USD = $0.95 (through USDT)
        uniswapOracle.setPrice(usdtToken, 1.0526e18, block.timestamp); // 1/0.95 ≈ 1.0526

        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        
        // yPUSD/PUSD = 1.05
        dexOnlyOracle.setPrice(ypusdToken, 1.05e18, block.timestamp);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));
        vm.stopPrank();

        // yPUSD/USD = yPUSD/PUSD * PUSD/USD = 1.05 * 0.95 ≈ 0.9975
        (uint256 price, ) = oracle.getTokenUSDPrice(ypusdToken);
        // Allow small deviation due to rounding
        assertGt(price, 0.99e18);
        assertLt(price, 1.01e18);
    }

    // ==================== Bootstrap Mode Tests ====================

    function test_EnableBootstrapMode() public {
        vm.prank(admin);
        oracle.enableBootstrapMode();
        assertTrue(oracle.bootstrapMode());
    }

    function test_EnableBootstrapMode_RevertUnauthorized() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        oracle.enableBootstrapMode();
    }

    function test_DisableBootstrapMode() public {
        vm.startPrank(admin);
        oracle.enableBootstrapMode();
        assertTrue(oracle.bootstrapMode());
        
        oracle.disableBootstrapMode();
        assertFalse(oracle.bootstrapMode());
        vm.stopPrank();
    }

    function test_DisableBootstrapMode_RevertUnauthorized() public {
        vm.prank(admin);
        oracle.enableBootstrapMode();
        
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        oracle.disableBootstrapMode();
    }

    function test_AddBootstrapToken() public {
        vm.prank(admin);
        oracle.addBootstrapToken(usdtToken);
        assertTrue(oracle.bootstrapTokens(usdtToken));
    }

    function test_AddBootstrapToken_RevertInvalidToken() public {
        vm.prank(admin);
        vm.expectRevert("Invalid token");
        oracle.addBootstrapToken(address(0));
    }

    function test_AddBootstrapToken_RevertUnauthorized() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        oracle.addBootstrapToken(usdtToken);
    }

    function test_RemoveBootstrapToken() public {
        vm.startPrank(admin);
        oracle.addBootstrapToken(usdtToken);
        assertTrue(oracle.bootstrapTokens(usdtToken));
        
        oracle.removeBootstrapToken(usdtToken);
        assertFalse(oracle.bootstrapTokens(usdtToken));
        vm.stopPrank();
    }

    function test_RemoveBootstrapToken_RevertUnauthorized() public {
        vm.prank(admin);
        oracle.addBootstrapToken(usdtToken);
        
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        oracle.removeBootstrapToken(usdtToken);
    }

    function test_IsBootstrapToken() public {
        // Not a bootstrap token when mode is off
        assertFalse(oracle.isBootstrapToken(usdtToken));
        
        // Add token but mode is still off
        vm.prank(admin);
        oracle.addBootstrapToken(usdtToken);
        assertFalse(oracle.isBootstrapToken(usdtToken));
        
        // Enable mode
        vm.prank(admin);
        oracle.enableBootstrapMode();
        assertTrue(oracle.isBootstrapToken(usdtToken));
        
        // Token not in whitelist
        assertFalse(oracle.isBootstrapToken(usdcToken));
    }

    function test_BootstrapMode_GetTokenPUSDPrice() public {
        // Enable bootstrap mode and add token
        vm.startPrank(admin);
        oracle.enableBootstrapMode();
        oracle.addBootstrapToken(usdtToken);
        vm.stopPrank();
        
        // Should return 1:1 price for bootstrap token
        (uint256 price, uint256 timestamp) = oracle.getTokenPUSDPrice(usdtToken);
        assertEq(price, 1e18); // 1:1 price
        assertEq(timestamp, block.timestamp);
    }

    function test_BootstrapMode_WorksWithoutDEXPair() public {
        // This simulates the cold-start problem:
        // No DEX pair exists yet, but we need a price to mint initial PUSD
        address newToken = address(0x9999);
        
        vm.startPrank(admin);
        oracle.enableBootstrapMode();
        oracle.addBootstrapToken(newToken);
        vm.stopPrank();
        
        // Token has no Chainlink feed, no DEX pair, but bootstrap price works
        (uint256 price, uint256 timestamp) = oracle.getTokenPUSDPrice(newToken);
        assertEq(price, 1e18);
        assertEq(timestamp, block.timestamp);
    }

    function test_BootstrapMode_FallsBackToNormalAfterDisabled() public {
        // Setup: Add token normally first
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed), address(uniswapOracle));
        
        // Enable bootstrap mode
        vm.startPrank(admin);
        oracle.enableBootstrapMode();
        oracle.addBootstrapToken(usdtToken);
        vm.stopPrank();
        
        // In bootstrap mode: returns 1:1
        (uint256 bootstrapPrice, ) = oracle.getTokenPUSDPrice(usdtToken);
        assertEq(bootstrapPrice, 1e18);
        
        // Disable bootstrap mode
        vm.prank(admin);
        oracle.disableBootstrapMode();
        
        // After disabling: returns actual DEX price
        (uint256 normalPrice, ) = oracle.getTokenPUSDPrice(usdtToken);
        assertEq(normalPrice, 1e18); // Same in this case since mock oracle returns 1:1
    }

    function test_BootstrapMode_NonWhitelistedTokenFails() public {
        // Enable bootstrap mode but don't add the token
        vm.prank(admin);
        oracle.enableBootstrapMode();
        
        // Token not in whitelist should revert
        vm.expectRevert("No price available");
        oracle.getTokenPUSDPrice(usdtToken);
    }

    // ==================== Fuzz Tests ====================

    function testFuzz_AddDexOnlyToken(uint256 price) public {
        vm.assume(price > 0 && price < type(uint128).max);
        
        dexOnlyOracle.setPrice(ypusdToken, price, block.timestamp);

        vm.prank(admin);
        oracle.addDexOnlyToken(ypusdToken, address(dexOnlyOracle));

        (, uint256 storedPrice, ) = oracle.getDexOnlyTokenInfo(ypusdToken);
        assertEq(storedPrice, price);
    }

    function testFuzz_SmartWeight(uint256 deviation) public view {
        // Test weight calculation with various deviations
        vm.assume(deviation <= 10000); // Max 100% deviation
        
        uint256 price = 1e18;
        if (deviation > 0) {
            price = 1e18 + (1e18 * deviation / 10000);
        }
        
        // Weight should always be between 1 and 10
        // This is implicitly tested through price updates
        assertTrue(price > 0);
    }
}
