// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {yPUSD} from "src/token/yPUSD/yPUSD.sol";
import {yPUSDStorage} from "src/token/yPUSD/yPUSDStorage.sol";
import {yPUSD_Deployer_Base} from "script/token/base/yPUSD_Deployer_Base.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Test-only V2 contract for upgrade testing
contract yPUSDV2Test is yPUSD {
    uint256 public version;

    function setVersion(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        version = v;
    }
}

contract yPUSDTest is Test, yPUSD_Deployer_Base {
    bytes32 salt;

    yPUSD token;
    yPUSDV2Test tokenV2;
    ERC20Mock pusd;

    address admin = address(0xA11CE);
    address user = address(0xCAFE);
    address yieldInjector = address(0xBEEF);

    uint256 constant CAP = 1_000_000_000 * 1e6;
    uint256 constant INITIAL_BALANCE = 10_000 * 1e6;
    uint256 constant DEFAULT_VESTING_DURATION = 7 days;
    uint256 constant BOOTSTRAP_AMOUNT = 1000 * 1e6; // Initial deposit to stabilize share/asset ratio

    bytes32 YIELD_INJECTOR_ROLE;

    function setUp() public {
        // Use default salt for testing (vm.envOr to avoid CI failures)
        salt = vm.envOr("SALT", bytes32(uint256(0x10100)));
        
        // Deploy mock PUSD
        pusd = new ERC20Mock("Phoenix USD", "PUSD", 6);
        
        // Deploy yPUSD with PUSD as underlying
        token = _deploy(IERC20(address(pusd)), CAP, admin, salt);

        YIELD_INJECTOR_ROLE = token.YIELD_INJECTOR_ROLE();
        
        // Grant yield injector role
        vm.prank(admin);
        token.grantRole(YIELD_INJECTOR_ROLE, yieldInjector);

        // Initial deposit by admin to stabilize share/asset ratio
        // This prevents decimalsOffset from dominating the conversion
        pusd.mint(admin, 1000 * 1e6);
        vm.startPrank(admin);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, admin);
        vm.stopPrank();

        // Mint PUSD to user for testing
        pusd.mint(user, INITIAL_BALANCE);
        pusd.mint(yieldInjector, INITIAL_BALANCE);
    }

    // ---------- Initialization ----------

    function test_InitializeState() public view {
        assertEq(token.name(), "Yield Phoenix USD Token");
        assertEq(token.symbol(), "yPUSD");
        assertEq(token.decimals(), 6);
        assertEq(token.cap(), CAP);
        assertEq(token.asset(), address(pusd));
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert();
        token.initialize(IERC20(address(pusd)), CAP, admin);
    }

    // ---------- ERC-4626: Deposit ----------

    function test_Deposit() public {
        uint256 depositAmount = 1000 * 1e6;
        
        vm.startPrank(user);
        pusd.approve(address(token), depositAmount);
        uint256 shares = token.deposit(depositAmount, user);
        vm.stopPrank();

        // With _decimalsOffset()=3, shares = assets * 1000
        assertApproxEqRel(shares, depositAmount * 1000, 1e15); // 0.1% tolerance
        assertApproxEqRel(token.balanceOf(user), depositAmount * 1000, 1e15);
        assertEq(token.totalAssets(), BOOTSTRAP_AMOUNT + depositAmount);
    }

    function test_DepositToOther() public {
        uint256 depositAmount = 500 * 1e6;
        address receiver = address(0x1234);

        vm.startPrank(user);
        pusd.approve(address(token), depositAmount);
        uint256 shares = token.deposit(depositAmount, receiver);
        vm.stopPrank();

        assertEq(token.balanceOf(receiver), shares);
        assertEq(token.balanceOf(user), 0);
    }

    function test_DepositRespectsCap() public {
        // Cap is 1B * 1e6 = 1e15 (in shares with decimals=6)
        // With decimalsOffset=3, initial supply after bootstrap = 1000e6 * 1000 = 1e12 shares
        // But cap is checked against totalSupply (in 6-decimal shares)
        
        // Get max deposit amount
        uint256 maxDeposit = token.maxDeposit(user);
        
        pusd.mint(user, maxDeposit + 1e6);
        
        vm.startPrank(user);
        pusd.approve(address(token), maxDeposit + 1e6);
        
        // Deposit to reach cap
        token.deposit(maxDeposit, user);
        
        // Now at cap, any deposit should fail
        vm.expectRevert(); // ERC4626ExceededMaxDeposit
        token.deposit(1e6, user);
        vm.stopPrank();
    }

    // ---------- ERC-4626: Redeem ----------

    function test_Redeem() public {
        uint256 depositAmount = 1000 * 1e6;
        
        // First deposit
        vm.startPrank(user);
        pusd.approve(address(token), depositAmount);
        token.deposit(depositAmount, user);
        
        // Then redeem half (shares = assets * 1000)
        uint256 redeemShares = 500 * 1e6 * 1000; // 500 PUSD worth of shares
        uint256 assets = token.redeem(redeemShares, user, user);
        vm.stopPrank();

        // assets = shares / 1000
        assertApproxEqRel(assets, 500 * 1e6, 1e15);
    }

    function test_Withdraw() public {
        uint256 depositAmount = 1000 * 1e6;
        
        vm.startPrank(user);
        pusd.approve(address(token), depositAmount);
        token.deposit(depositAmount, user);
        
        // Withdraw specific asset amount
        uint256 withdrawAssets = 300 * 1e6;
        uint256 shares = token.withdraw(withdrawAssets, user, user);
        vm.stopPrank();

        // shares = assets * 1000 (due to decimalsOffset)
        assertApproxEqRel(shares, withdrawAssets * 1000, 1e15);
        assertEq(pusd.balanceOf(user), INITIAL_BALANCE - depositAmount + withdrawAssets);
    }

    // ---------- Linear Yield Vesting ----------

    function test_AccrueYieldWithDuration() public {
        // User deposits 1000 PUSD
        uint256 depositAmount = 1000 * 1e6;
        vm.startPrank(user);
        pusd.approve(address(token), depositAmount);
        token.deposit(depositAmount, user);
        vm.stopPrank();

        // Yield injector adds 100 PUSD yield with 7 day vesting
        uint256 yieldAmount = 100 * 1e6;
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), yieldAmount);
        token.accrueYield(yieldAmount, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Immediately after accrual, totalAssets should still be bootstrap + deposit (no yield released yet)
        assertApproxEqAbs(token.totalAssets(), BOOTSTRAP_AMOUNT + depositAmount, 1);
        
        // Exchange rate = totalAssets * 1e18 / totalSupply = 2000e6 * 1e18 / 2000e9 = 1e15
        assertApproxEqRel(token.exchangeRate(), 1e15, 1e12);
    }

    function test_YieldReleasesLinearly() public {
        // User deposits 1000 PUSD
        uint256 depositAmount = 1000 * 1e6;
        vm.startPrank(user);
        pusd.approve(address(token), depositAmount);
        token.deposit(depositAmount, user);
        vm.stopPrank();

        // Yield injector adds 100 PUSD yield with 10 day vesting
        uint256 yieldAmount = 100 * 1e6;
        uint256 vestingDuration = 10 days;
        uint256 startTime = block.timestamp;
        
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), yieldAmount);
        token.accrueYield(yieldAmount, vestingDuration);
        vm.stopPrank();

        // Total deposited = BOOTSTRAP_AMOUNT + depositAmount = 2000e6
        // After 5 days, 50% yield should be released
        vm.warp(startTime + 5 days);
        assertApproxEqAbs(token.totalAssets(), BOOTSTRAP_AMOUNT + depositAmount + yieldAmount / 2, 2);
        
        // Exchange rate = 2050e6 * 1e18 / 2000e9 = 1.025e15
        assertApproxEqRel(token.exchangeRate(), 1.025e15, 1e12);

        // After full vesting, all yield released
        vm.warp(startTime + vestingDuration);
        assertApproxEqAbs(token.totalAssets(), BOOTSTRAP_AMOUNT + depositAmount + yieldAmount, 2);
        
        // Exchange rate = 2100e6 * 1e18 / 2000e9 = 1.05e15
        assertApproxEqRel(token.exchangeRate(), 1.05e15, 1e12);
    }

    function test_AccrueYieldOnlyAuthorized() public {
        vm.startPrank(user);
        pusd.approve(address(token), 100 * 1e6);
        
        vm.expectRevert();
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();
    }

    function test_RedeemAfterYieldFullyVested() public {
        // User deposits 1000 PUSD, gets ~1000e9 shares
        uint256 depositAmount = 1000 * 1e6;
        vm.startPrank(user);
        pusd.approve(address(token), depositAmount);
        token.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 sharesBefore = token.balanceOf(user);

        // Yield injector adds 100 PUSD (5% yield for 2000 total) with 7 day vesting
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        // User redeems all shares
        vm.prank(user);
        uint256 assetsReceived = token.redeem(sharesBefore, user, user);

        // User gets half of yield (admin has other half): ~1050 PUSD
        assertApproxEqAbs(assetsReceived, 1050 * 1e6, 1e6);
    }

    function test_RedeemDuringVesting_ReceivesPartialYield() public {
        // User deposits 1000 PUSD
        uint256 depositAmount = 1000 * 1e6;
        vm.startPrank(user);
        pusd.approve(address(token), depositAmount);
        token.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 sharesBefore = token.balanceOf(user);

        // Yield injector adds 100 PUSD with 10 day vesting
        uint256 yieldAmount = 100 * 1e6;
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), yieldAmount);
        token.accrueYield(yieldAmount, 10 days);
        vm.stopPrank();

        // Wait 5 days (50% vesting)
        vm.warp(block.timestamp + 5 days);

        // User redeems all shares
        vm.prank(user);
        uint256 assetsReceived = token.redeem(sharesBefore, user, user);

        // User gets half of vested yield (admin has other half): ~1025 PUSD
        assertApproxEqAbs(assetsReceived, depositAmount + yieldAmount / 4, 1e6); // 25% of total yield
    }

    function test_FlashLoanAttackPrevented() public {
        // Existing user deposits 1000 PUSD
        address existingUser = address(0x1111);
        pusd.mint(existingUser, 1000 * 1e6);
        vm.startPrank(existingUser);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, existingUser);
        vm.stopPrank();

        // Attacker tries to front-run yield injection
        address attacker = address(0x6666);
        pusd.mint(attacker, 10000 * 1e6);
        
        vm.startPrank(attacker);
        pusd.approve(address(token), 10000 * 1e6);
        token.deposit(10000 * 1e6, attacker);
        vm.stopPrank();

        // Yield is injected with linear vesting
        uint256 yieldAmount = 100 * 1e6;
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), yieldAmount);
        token.accrueYield(yieldAmount, 7 days);
        vm.stopPrank();

        // Attacker tries to withdraw immediately - gets NO extra yield
        uint256 attackerSharesBefore = token.balanceOf(attacker);
        vm.prank(attacker);
        uint256 attackerReceived = token.redeem(attackerSharesBefore, attacker, attacker);

        // Attacker should receive approximately what they deposited (no yield captured)
        assertApproxEqAbs(attackerReceived, 10000 * 1e6, 2);
    }

    function test_VestingInfoView() public {
        // User deposits
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // Add yield
        uint256 yieldAmount = 100 * 1e6;
        uint256 vestingDuration = 10 days;
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), yieldAmount);
        token.accrueYield(yieldAmount, vestingDuration);
        vm.stopPrank();

        (
            uint256 vestingEndTime,
            uint256 vestingRate,
            uint256 unvestedYield,
            uint256 releasedYield
        ) = token.getVestingInfo();

        assertEq(vestingEndTime, block.timestamp + vestingDuration);
        assertEq(vestingRate, yieldAmount / vestingDuration);
        assertEq(unvestedYield, yieldAmount);
        assertEq(releasedYield, 0);

        // After some time
        vm.warp(block.timestamp + 5 days);
        
        (
            ,
            ,
            uint256 unvestedYieldAfter,
            uint256 releasedYieldAfter
        ) = token.getVestingInfo();

        // Half released
        assertApproxEqAbs(unvestedYieldAfter, yieldAmount / 2, 500000); // Allow for rate truncation
        assertApproxEqAbs(releasedYieldAfter, yieldAmount / 2, 500000); // Allow for rate truncation
    }

    function test_SettleVesting() public {
        // User deposits
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // Add yield
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, 10 days);
        vm.stopPrank();

        // Warp time
        vm.warp(block.timestamp + 5 days);

        // Anyone can settle
        token.settleVesting();

        // Check state was updated
        (,,uint256 unvestedYield, uint256 releasedYield) = token.getVestingInfo();
        assertApproxEqAbs(unvestedYield, 50 * 1e6, 500000); // Allow for rate truncation
        assertApproxEqAbs(releasedYield, 50 * 1e6, 500000); // Allow for rate truncation
    }

    function test_AccrueYieldCombinesPreviousUnvested() public {
        // User deposits
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // First yield injection: 100 PUSD over 10 days
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 200 * 1e6);
        token.accrueYield(100 * 1e6, 10 days);
        
        // After 5 days, inject more yield
        vm.warp(block.timestamp + 5 days);
        
        // At this point: ~50 released, ~50 unvested
        // New injection: 100 PUSD over 10 days
        // Total new unvested = ~50 + 100 = ~150
        token.accrueYield(100 * 1e6, 10 days);
        vm.stopPrank();

        (
            uint256 vestingEndTime,
            uint256 vestingRate,
            uint256 unvestedYield,
        ) = token.getVestingInfo();

        // New vesting period
        assertEq(vestingEndTime, block.timestamp + 10 days);
        
        // Unvested should be ~150 (50 remaining + 100 new)
        assertApproxEqAbs(unvestedYield, 150 * 1e6, 500000); // Allow for rate truncation
        
        // Rate = 150 / 10 days
        assertApproxEqAbs(vestingRate, uint256(150 * 1e6) / uint256(10 days), 500); // Allow for rate truncation
    }

    function test_AccrueYieldZeroAmountReverts() public {
        vm.prank(yieldInjector);
        vm.expectRevert("yPUSD: zero amount");
        token.accrueYield(0, DEFAULT_VESTING_DURATION);
    }

    function test_AccrueYieldDurationTooShort() public {
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        
        vm.expectRevert("yPUSD: duration too short");
        token.accrueYield(100 * 1e6, 1 hours); // Less than MIN_VESTING_DURATION
        vm.stopPrank();
    }

    function test_AccrueYieldDurationTooLong() public {
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        
        vm.expectRevert("yPUSD: duration too long");
        token.accrueYield(100 * 1e6, 31 days); // More than MAX_VESTING_DURATION
        vm.stopPrank();
    }

    // ---------- Exchange Rate ----------

    function test_ExchangeRateInitiallyOne() public view {
        // With bootstrap deposit and decimalsOffset=3:
        // totalAssets = 1000e6, totalSupply = 1000e9
        // exchangeRate = 1000e6 * 1e18 / 1000e9 = 1e15
        assertApproxEqRel(token.exchangeRate(), 1e15, 1e12);
    }

    function test_ExchangeRateAfterDeposit() public {
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // With _decimalsOffset()=3, exchangeRate = totalAssets * 1e18 / totalSupply
        // totalAssets = 1000e6, totalSupply = 1000e9
        // exchangeRate = 1000e6 * 1e18 / 1000e9 = 1e15
        // This represents the value per share in 18 decimals
        assertApproxEqRel(token.exchangeRate(), 1e15, 1e12); // ~0.001 (1/1000)
    }

    // ---------- Pause ----------

    function test_AdminCanPauseAndUnpause() public {
        vm.prank(admin);
        token.pause();
        assertTrue(token.paused());

        vm.prank(admin);
        token.unpause();
        assertFalse(token.paused());
    }

    function test_DepositWhenPausedReverts() public {
        vm.prank(admin);
        token.pause();

        vm.startPrank(user);
        pusd.approve(address(token), 100 * 1e6);
        vm.expectRevert();
        token.deposit(100 * 1e6, user);
        vm.stopPrank();
    }

    function test_RedeemWhenPausedReverts() public {
        // First deposit
        vm.startPrank(user);
        pusd.approve(address(token), 100 * 1e6);
        token.deposit(100 * 1e6, user);
        vm.stopPrank();

        // Pause
        vm.prank(admin);
        token.pause();

        // Try to redeem
        vm.prank(user);
        vm.expectRevert();
        token.redeem(50 * 1e6, user, user);
    }

    function test_MaxDepositReturnsZeroWhenPaused() public {
        vm.prank(admin);
        token.pause();

        assertEq(token.maxDeposit(user), 0);
    }

    // ---------- Cap ----------

    function test_SetCap() public {
        uint256 newCap = 2_000_000_000 * 1e6;
        
        vm.prank(admin);
        token.setCap(newCap);
        
        assertEq(token.cap(), newCap);
    }

    function test_SetCapBelowSupplyReverts() public {
        // Deposit some first
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // Try to set cap below current supply
        vm.prank(admin);
        vm.expectRevert("yPUSD: cap below current supply");
        token.setCap(500 * 1e6);
    }

    // ---------- View Functions ----------

    function test_DecimalsReturnsFixedSix() public view {
        assertEq(token.decimals(), 6);
    }

    function test_UnderlyingBalanceOf() public {
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        assertEq(token.underlyingBalanceOf(user), 1000 * 1e6);
    }

    // ---------- Upgrade ----------

    function test_UpgradeKeepsState() public {
        // 1. Deposit some state on V1
        vm.startPrank(user);
        pusd.approve(address(token), 123 * 1e6);
        token.deposit(123 * 1e6, user);
        vm.stopPrank();

        // With decimalsOffset=3, shares = assets * 1000
        assertApproxEqRel(token.balanceOf(user), 123 * 1e6 * 1000, 1e15);

        // 2. Upgrade to V2
        vm.startPrank(admin);
        yPUSDV2Test implV2 = new yPUSDV2Test();
        token.upgradeToAndCall(address(implV2), "");
        tokenV2 = yPUSDV2Test(address(token));
        vm.stopPrank();

        // 3. State preserved
        assertApproxEqRel(tokenV2.balanceOf(user), 123 * 1e6 * 1000, 1e15);
        assertEq(tokenV2.totalAssets(), BOOTSTRAP_AMOUNT + 123 * 1e6);
        assertEq(tokenV2.cap(), CAP);
        assertTrue(tokenV2.hasRole(tokenV2.DEFAULT_ADMIN_ROLE(), admin));

        // 4. New logic works
        vm.prank(admin);
        tokenV2.setVersion(2);
        assertEq(tokenV2.version(), 2);
    }

    function test_UpgradeOnlyAdmin() public {
        yPUSDV2Test implV2 = new yPUSDV2Test();

        vm.prank(user);
        vm.expectRevert();
        token.upgradeToAndCall(address(implV2), "");
    }

    // ---------- Additional Coverage ----------

    function test_Mint() public {
        // With decimalsOffset=3, to mint X shares, we need X/1000 assets
        uint256 mintShares = 500 * 1e6 * 1000; // 500 PUSD worth of shares
        
        vm.startPrank(user);
        pusd.approve(address(token), 600 * 1e6); // Allow for rounding
        uint256 assets = token.mint(mintShares, user);
        vm.stopPrank();

        // assets = shares / 1000
        assertApproxEqRel(assets, 500 * 1e6, 1e15);
        assertEq(token.balanceOf(user), mintShares);
    }

    function test_MintAfterYieldFullyVested() public {
        // First user deposits 1000 PUSD
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // Yield: 100 PUSD with vesting
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        // Now rate increased, to mint 100e9 shares need more than 100 PUSD
        // Rate = 2100e6 / 2000e9 = 1.05e-3 assets per share
        // So 100e9 shares need ~105 PUSD
        address user2 = address(0x2222);
        pusd.mint(user2, 1000 * 1e6);
        
        vm.startPrank(user2);
        pusd.approve(address(token), 200 * 1e6);
        uint256 mintShares = 100 * 1e6 * 1000; // 100e9 shares
        uint256 assetsNeeded = token.mint(mintShares, user2);
        vm.stopPrank();

        // Should need more than 100 PUSD due to yield (rate > 1)
        assertTrue(assetsNeeded > 100 * 1e6);
    }

    function test_DepositAfterYieldFullyVested() public {
        // First user deposits 1000 PUSD
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // Yield: 100 PUSD with vesting
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        // Now rate increased, deposit 110 PUSD should get fewer than 110e9 shares
        // Rate = 2100e6 / 2000e9, so 110 PUSD gets ~104.76e9 shares
        address user2 = address(0x2222);
        pusd.mint(user2, 1000 * 1e6);
        
        vm.startPrank(user2);
        pusd.approve(address(token), 110 * 1e6);
        uint256 shares = token.deposit(110 * 1e6, user2);
        vm.stopPrank();

        // Should get fewer than 110e9 shares due to rate > 1
        assertTrue(shares < 110 * 1e6 * 1000);
    }

    function test_WithdrawWhenPausedReverts() public {
        // First deposit
        vm.startPrank(user);
        pusd.approve(address(token), 100 * 1e6);
        token.deposit(100 * 1e6, user);
        vm.stopPrank();

        // Pause
        vm.prank(admin);
        token.pause();

        // Try to withdraw
        vm.prank(user);
        vm.expectRevert();
        token.withdraw(50 * 1e6, user, user);
    }

    function test_MaxMintReturnsZeroWhenPaused() public {
        vm.prank(admin);
        token.pause();

        assertEq(token.maxMint(user), 0);
    }

    function test_MaxWithdrawReturnsZeroWhenPaused() public {
        // First deposit
        vm.startPrank(user);
        pusd.approve(address(token), 100 * 1e6);
        token.deposit(100 * 1e6, user);
        vm.stopPrank();

        vm.prank(admin);
        token.pause();

        assertEq(token.maxWithdraw(user), 0);
    }

    function test_MaxRedeemReturnsZeroWhenPaused() public {
        // First deposit
        vm.startPrank(user);
        pusd.approve(address(token), 100 * 1e6);
        token.deposit(100 * 1e6, user);
        vm.stopPrank();

        vm.prank(admin);
        token.pause();

        assertEq(token.maxRedeem(user), 0);
    }

    function test_MultipleUsersYieldDistribution() public {
        // User1 deposits 1000 PUSD
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // User2 deposits 1000 PUSD
        address user2 = address(0x2222);
        pusd.mint(user2, 1000 * 1e6);
        vm.startPrank(user2);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user2);
        vm.stopPrank();

        // Both have ~1000e9 shares (1000 PUSD * 1000 due to decimalsOffset)
        assertApproxEqRel(token.balanceOf(user), 1000 * 1e6 * 1000, 1e15);
        assertApproxEqRel(token.balanceOf(user2), 1000 * 1e6 * 1000, 1e15);

        // Yield: 200 PUSD (6.67% for total 3000 PUSD) with vesting
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 200 * 1e6);
        token.accrueYield(200 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        // Total assets: bootstrap + 2000 + 200 = 3200, total shares: ~3000e9
        // Exchange rate = 3200e6 * 1e18 / 3000e9 = 1.0667e15
        assertApproxEqAbs(token.totalAssets(), BOOTSTRAP_AMOUNT + 2000 * 1e6 + 200 * 1e6, 2);
        assertApproxEqRel(token.exchangeRate(), 1.0667e15, 1e14); // Allow more tolerance

        // Each user should get ~1066.67 PUSD when redeeming all shares
        uint256 user1Shares = token.balanceOf(user);
        uint256 user2Shares = token.balanceOf(user2);
        
        vm.prank(user);
        uint256 assets1 = token.redeem(user1Shares, user, user);
        
        vm.prank(user2);
        uint256 assets2 = token.redeem(user2Shares, user2, user2);

        // Each gets ~1/3 of yield (since bootstrap admin also has 1/3 shares)
        assertApproxEqAbs(assets1, 1066 * 1e6, 2e6); // ~1066.67 PUSD
        assertApproxEqAbs(assets2, 1066 * 1e6, 2e6);
    }

    function test_ExchangeRateUnchangedAfterDeposit() public {
        // User1 deposits, injector adds yield
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        uint256 rateBefore = token.exchangeRate();

        // User2 deposits
        address user2 = address(0x2222);
        pusd.mint(user2, 1000 * 1e6);
        vm.startPrank(user2);
        pusd.approve(address(token), 550 * 1e6);
        token.deposit(550 * 1e6, user2);
        vm.stopPrank();

        uint256 rateAfter = token.exchangeRate();

        // Rate should not change significantly after deposit
        assertApproxEqRel(rateBefore, rateAfter, 1e15); // 0.1% tolerance
    }

    function test_ExchangeRateUnchangedAfterRedeem() public {
        // Two users deposit
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        address user2 = address(0x2222);
        pusd.mint(user2, 1000 * 1e6);
        vm.startPrank(user2);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user2);
        vm.stopPrank();

        // Add yield
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 200 * 1e6);
        token.accrueYield(200 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        uint256 rateBefore = token.exchangeRate();

        // User1 redeems half
        vm.prank(user);
        token.redeem(500 * 1e6, user, user);

        uint256 rateAfter = token.exchangeRate();

        // Rate should not change after redeem (allow small rounding variance)
        // Due to ERC-4626 rounding, the rate may differ slightly
        assertApproxEqRel(rateBefore, rateAfter, 1e15); // 0.1% tolerance
    }

    // ---------- Permission Tests ----------

    function test_PauseOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        token.pause();
    }

    function test_UnpauseOnlyAdmin() public {
        vm.prank(admin);
        token.pause();

        vm.prank(user);
        vm.expectRevert();
        token.unpause();
    }

    function test_SetCapOnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        token.setCap(1000 * 1e6);
    }

    function test_TotalAssets() public {
        // Bootstrap deposit already in setUp
        assertEq(token.totalAssets(), BOOTSTRAP_AMOUNT);

        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        assertEq(token.totalAssets(), BOOTSTRAP_AMOUNT + 1000 * 1e6);
    }

    function test_Asset() public view {
        assertEq(token.asset(), address(pusd));
    }

    function test_ConvertToShares() public {
        // With bootstrap deposit and decimalsOffset=3, shares = assets * 1000
        assertApproxEqRel(token.convertToShares(100 * 1e6), 100 * 1e6 * 1000, 1e15);

        // After deposit and yield (fully vested)
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        // Rate changes due to yield, 110 assets gets fewer shares
        uint256 shares = token.convertToShares(110 * 1e6);
        assertApproxEqRel(shares, 100 * 1e6 * 1000, 5e16); // 5% tolerance
    }

    function test_ConvertToAssets() public {
        // With bootstrap deposit and decimalsOffset=3, assets = shares / 1000
        assertApproxEqRel(token.convertToAssets(100 * 1e6 * 1000), 100 * 1e6, 1e15);

        // After deposit and yield (fully vested)
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        // Rate > 1, 100e9 shares gets more than 100 assets
        uint256 assets = token.convertToAssets(100 * 1e6 * 1000);
        assertApproxEqRel(assets, 105 * 1e6, 5e16); // 5% tolerance
    }

    function test_PreviewDeposit() public view {
        // With bootstrap deposit and decimalsOffset=3, shares = assets * 1000
        assertApproxEqRel(token.previewDeposit(100 * 1e6), 100 * 1e6 * 1000, 1e15);
    }

    function test_PreviewMint() public view {
        // With bootstrap deposit and decimalsOffset=3, assets = shares / 1000
        assertApproxEqRel(token.previewMint(100 * 1e6 * 1000), 100 * 1e6, 1e15);
    }

    function test_PreviewWithdraw() public {
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // shares = assets * 1000 (due to decimalsOffset)
        assertApproxEqRel(token.previewWithdraw(100 * 1e6), 100 * 1e6 * 1000, 1e15);
    }

    function test_PreviewRedeem() public {
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // assets = shares / 1000 (due to decimalsOffset)
        assertApproxEqRel(token.previewRedeem(100 * 1e6 * 1000), 100 * 1e6, 1e15);
    }

    // ---------- Edge Cases ----------

    function test_TotalAssetsWhenVestingCompleted() public {
        // User deposits
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // Add yield
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Warp beyond vesting period
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION + 30 days);

        // Should show bootstrap + deposit + yield
        assertApproxEqAbs(token.totalAssets(), BOOTSTRAP_AMOUNT + 1100 * 1e6, 1);
    }

    function test_NoDepositorsYieldAccrual() public {
        // Note: With bootstrap deposit, there IS a depositor (admin with 1000 PUSD)
        // Test the behavior when yield is added to existing pool
        uint256 startTime = block.timestamp;
        
        // Add yield (admin will receive it)
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // totalAssets should still be bootstrap amount (unvested)
        assertApproxEqAbs(token.totalAssets(), BOOTSTRAP_AMOUNT, 1);

        // Wait for full vesting
        vm.warp(startTime + DEFAULT_VESTING_DURATION);

        // Now totalAssets includes the yield
        assertEq(token.totalAssets(), BOOTSTRAP_AMOUNT + 100 * 1e6);

        // New depositor joins after yield - gets fewer shares per asset
        vm.startPrank(user);
        pusd.approve(address(token), 100 * 1e6);
        uint256 shares = token.deposit(100 * 1e6, user);
        vm.stopPrank();

        // Rate increased, so shares < 100e9
        // shares = 100e6 * 1000e9 / 1100e6 ≈ 90.9e9
        assertTrue(shares < 100 * 1e6 * 1000, "Should get fewer shares due to yield");
    }
}
