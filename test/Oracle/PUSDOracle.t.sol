// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/Oracle/PUSDOracle.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ==================== Mock Contracts ====================

contract MockChainlinkFeed {
    int256 private _price;
    uint8 private _decimals;
    uint256 private _updatedAt;

    constructor(int256 price_, uint8 decimals_) {
        _price = price_;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _price, 0, _updatedAt, 0);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function setPrice(int256 price_) external {
        _price = price_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }
}

contract MockVault {
    bool public isPaused;
    uint256 public lastHeartbeat;

    function pause() external {
        isPaused = true;
    }

    function unpause() external {
        isPaused = false;
    }

    // This is the function Oracle calls
    function heartbeat() external {
        lastHeartbeat = block.timestamp;
    }
}

// ==================== Test Contract ====================

contract PUSDOracleTest is Test {
    PUSDOracleUpgradeable public oracle;
    MockVault public vault;
    
    MockChainlinkFeed public usdtFeed;
    MockChainlinkFeed public usdcFeed;

    address public admin = address(0x1);
    address public upgrader = address(0x3);
    address public pusdToken = address(0x4);
    address public usdtToken = address(0x10);
    address public usdcToken = address(0x11);

    // Events (matching actual contract)
    event TokenAdded(address indexed token, address usdFeed);
    event TokenRemoved(address indexed token);
    event HeartbeatSent(uint256 timestamp);
    event SystemParametersUpdated(uint256 maxPriceAge, uint256 heartbeatInterval);

    function setUp() public {
        vault = new MockVault();

        // Create price feeds (8 decimals, $1.00)
        usdtFeed = new MockChainlinkFeed(1e8, 8);
        usdcFeed = new MockChainlinkFeed(1e8, 8);

        // Deploy oracle
        PUSDOracleUpgradeable impl = new PUSDOracleUpgradeable();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (address(vault), pusdToken, admin))
        );
        oracle = PUSDOracleUpgradeable(address(proxy));

        // Setup roles
        vm.startPrank(admin);
        oracle.grantRole(oracle.UPGRADER_ROLE(), upgrader);
        vm.stopPrank();
    }

    // ==================== Initialization Tests ====================

    function test_Initialize() public view {
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(address(oracle.vault()), address(vault));
        assertEq(oracle.pusdToken(), pusdToken);
        assertEq(oracle.maxPriceAge(), 24 hours);
        assertEq(oracle.heartbeatInterval(), 1 hours);
    }

    function test_Initialize_RevertZeroVault() public {
        PUSDOracleUpgradeable impl = new PUSDOracleUpgradeable();
        vm.expectRevert("Invalid vault");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (address(0), pusdToken, admin))
        );
    }

    // ==================== Add Token Tests ====================

    function test_AddToken() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit TokenAdded(usdtToken, address(usdtFeed));
        oracle.addToken(usdtToken, address(usdtFeed));

        address[] memory tokens = oracle.getSupportedTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], usdtToken);

        address usdFeed = oracle.getTokenInfo(usdtToken);
        assertEq(usdFeed, address(usdtFeed));
    }

    function test_AddToken_RevertInvalidToken() public {
        vm.prank(admin);
        vm.expectRevert("Invalid token");
        oracle.addToken(address(0), address(usdtFeed));
    }

    function test_AddToken_RevertInvalidFeed() public {
        vm.prank(admin);
        vm.expectRevert("Invalid feed");
        oracle.addToken(usdtToken, address(0));
    }

    function test_AddToken_RevertAlreadyExists() public {
        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed));

        vm.expectRevert("Token exists");
        oracle.addToken(usdtToken, address(usdtFeed));
        vm.stopPrank();
    }

    function test_AddToken_RevertInvalidPrice() public {
        MockChainlinkFeed badFeed = new MockChainlinkFeed(0, 8);

        vm.prank(admin);
        vm.expectRevert("Invalid price");
        oracle.addToken(usdtToken, address(badFeed));
    }

    function test_AddToken_RevertPriceTooOld() public {
        vm.warp(block.timestamp + 30 hours);
        usdtFeed.setUpdatedAt(block.timestamp - 25 hours);

        vm.prank(admin);
        vm.expectRevert("Stale price");
        oracle.addToken(usdtToken, address(usdtFeed));
    }

    function test_AddToken_RevertUnauthorized() public {
        vm.prank(address(0x9999));
        vm.expectRevert();
        oracle.addToken(usdtToken, address(usdtFeed));
    }

    // ==================== Remove Token Tests ====================

    function test_RemoveToken() public {
        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed));

        vm.expectEmit(true, false, false, true);
        emit TokenRemoved(usdtToken);
        oracle.removeToken(usdtToken);
        vm.stopPrank();

        address[] memory tokens = oracle.getSupportedTokens();
        assertEq(tokens.length, 0);
    }

    function test_RemoveToken_RevertNotExists() public {
        vm.prank(admin);
        vm.expectRevert("Token not found");
        oracle.removeToken(usdtToken);
    }

    // ==================== PUSD/USD Price Tests ====================

    function test_GetPUSDUSDPrice() public view {
        // PUSD/USD is always 1.0 in simplified model
        (uint256 price, uint256 timestamp) = oracle.getPUSDUSDPrice();
        assertEq(price, 1e18);
        assertGt(timestamp, 0);
    }

    // ==================== Token/PUSD Price Tests ====================

    function test_GetTokenPUSDPrice() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed));

        // Token/PUSD = Token/USD since PUSD/USD = 1
        (uint256 price, uint256 timestamp) = oracle.getTokenPUSDPrice(usdtToken);
        assertEq(price, 1e18);
        assertGt(timestamp, 0);
    }

    function test_GetTokenPUSDPrice_RevertNotSupported() public {
        vm.expectRevert("Token not supported");
        oracle.getTokenPUSDPrice(usdtToken);
    }

    function test_GetTokenPUSDPrice_RevertPriceTooOld() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed));

        vm.warp(block.timestamp + 25 hours);

        vm.expectRevert("Stale price");
        oracle.getTokenPUSDPrice(usdtToken);
    }

    // ==================== Token/USD Price Tests ====================

    function test_GetTokenUSDPrice() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed));

        (uint256 price, uint256 timestamp) = oracle.getTokenUSDPrice(usdtToken);
        assertEq(price, 1e18);
        assertGt(timestamp, 0);
    }

    function test_GetTokenUSDPrice_DifferentDecimals() public {
        // Test with 18 decimals feed
        MockChainlinkFeed feed18 = new MockChainlinkFeed(1e18, 18);

        vm.prank(admin);
        oracle.addToken(usdtToken, address(feed18));

        (uint256 price, ) = oracle.getTokenUSDPrice(usdtToken);
        assertEq(price, 1e18);
    }

    function test_GetTokenUSDPrice_RevertNotSupported() public {
        vm.expectRevert("Token not supported");
        oracle.getTokenUSDPrice(usdtToken);
    }

    function test_GetTokenUSDPrice_RevertInvalidPrice() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed));

        usdtFeed.setPrice(0);

        vm.expectRevert("Invalid price");
        oracle.getTokenUSDPrice(usdtToken);
    }

    function test_GetTokenUSDPrice_RevertPriceTooOld() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed));

        vm.warp(block.timestamp + 25 hours);

        vm.expectRevert("Stale price");
        oracle.getTokenUSDPrice(usdtToken);
    }

    // ==================== Heartbeat Tests ====================

    function test_SendHeartbeat_ByAnyone() public {
        address randomUser = address(0x9999);
        vm.prank(randomUser);
        vm.expectEmit(false, false, false, false);
        emit HeartbeatSent(block.timestamp);
        oracle.sendHeartbeat();

        assertEq(vault.lastHeartbeat(), block.timestamp);
    }

    // ==================== System Parameters Tests ====================

    function test_UpdateSystemParameters() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit SystemParametersUpdated(7200, 1800);
        oracle.updateSystemParameters(7200, 1800);

        assertEq(oracle.maxPriceAge(), 7200);
        assertEq(oracle.heartbeatInterval(), 1800);
    }

    function test_UpdateSystemParameters_RevertInvalidPriceAge() public {
        vm.startPrank(admin);

        vm.expectRevert("Invalid price age");
        oracle.updateSystemParameters(0, 1800);

        vm.expectRevert("Invalid price age");
        oracle.updateSystemParameters(3600 * 49, 1800);

        vm.stopPrank();
    }

    function test_UpdateSystemParameters_RevertInvalidInterval() public {
        vm.startPrank(admin);

        vm.expectRevert("Invalid interval");
        oracle.updateSystemParameters(7200, 0);

        vm.expectRevert("Invalid interval");
        oracle.updateSystemParameters(7200, 86401);

        vm.stopPrank();
    }

    function test_UpdateSystemParameters_RevertUnauthorized() public {
        vm.prank(address(0x9999));
        vm.expectRevert();
        oracle.updateSystemParameters(7200, 1800);
    }

    // ==================== Query Functions Tests ====================

    function test_GetSupportedTokens() public {
        vm.startPrank(admin);
        oracle.addToken(usdtToken, address(usdtFeed));
        oracle.addToken(usdcToken, address(usdcFeed));
        vm.stopPrank();

        address[] memory tokens = oracle.getSupportedTokens();
        assertEq(tokens.length, 2);
    }

    function test_GetTokenInfo() public {
        vm.prank(admin);
        oracle.addToken(usdtToken, address(usdtFeed));

        address usdFeed = oracle.getTokenInfo(usdtToken);
        assertEq(usdFeed, address(usdtFeed));
    }

    function test_GetVersion() public view {
        assertEq(oracle.getVersion(), "2.0.0");
    }

    // ==================== Upgrade Tests ====================

    function test_UpgradeAuthorization() public {
        PUSDOracleUpgradeable newImpl = new PUSDOracleUpgradeable();

        vm.prank(address(0x9999));
        vm.expectRevert();
        oracle.upgradeToAndCall(address(newImpl), "");

        vm.prank(upgrader);
        oracle.upgradeToAndCall(address(newImpl), "");
    }

    // ==================== Fuzz Tests ====================

    function testFuzz_ChainlinkPriceNormalization(int256 price, uint8 decimals) public {
        vm.assume(price > 0 && price < type(int128).max);
        vm.assume(decimals >= 6 && decimals <= 18);

        MockChainlinkFeed feed = new MockChainlinkFeed(price, decimals);

        vm.prank(admin);
        oracle.addToken(usdtToken, address(feed));

        (uint256 normalizedPrice, ) = oracle.getTokenUSDPrice(usdtToken);

        // Verify normalization to 18 decimals
        uint256 expectedPrice = uint256(price) * 10**(18 - decimals);
        assertEq(normalizedPrice, expectedPrice);
    }
}
