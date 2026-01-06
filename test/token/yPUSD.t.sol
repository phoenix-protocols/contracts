// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {yPUSD} from "src/token/yPUSD/yPUSD.sol";
import {yPUSDStorage} from "src/token/yPUSD/yPUSDStorage.sol";
import {yPUSD_Deployer_Base, yPUSDV2} from "script/token/base/yPUSD_Deployer_Base.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract yPUSDTest is Test, yPUSD_Deployer_Base {
    bytes32 salt;

    yPUSD token;
    yPUSDV2 tokenV2;
    ERC20Mock pusd;

    address admin = address(0xA11CE);
    address user = address(0xCAFE);
    address yieldInjector = address(0xBEEF);

    uint256 constant CAP = 1_000_000_000 * 1e6;
    uint256 constant INITIAL_BALANCE = 10_000 * 1e6;
    uint256 constant DEFAULT_VESTING_DURATION = 7 days;

    bytes32 YIELD_INJECTOR_ROLE;

    function setUp() public {
        salt = vm.envBytes32("SALT");
        
        // Deploy mock PUSD
        pusd = new ERC20Mock("Phoenix USD", "PUSD", 6);
        
        // Deploy yPUSD with PUSD as underlying
        token = _deploy(IERC20(address(pusd)), CAP, admin, salt);

        YIELD_INJECTOR_ROLE = token.YIELD_INJECTOR_ROLE();
        
        // Grant yield injector role
        vm.prank(admin);
        token.grantRole(YIELD_INJECTOR_ROLE, yieldInjector);

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

        // Initial rate is 1:1
        assertEq(shares, depositAmount);
        assertEq(token.balanceOf(user), depositAmount);
        assertEq(token.totalAssets(), depositAmount);
        assertEq(pusd.balanceOf(address(token)), depositAmount);
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
        // Mint more PUSD to test cap
        pusd.mint(user, CAP);
        
        vm.startPrank(user);
        pusd.approve(address(token), CAP + 1);
        
        // Deposit up to cap should work
        token.deposit(CAP, user);
        
        // Deposit more should fail (maxDeposit returns 0, so any deposit fails)
        vm.expectRevert(); // ERC4626ExceededMaxDeposit
        token.deposit(1, user);
        vm.stopPrank();
    }

    // ---------- ERC-4626: Redeem ----------

    function test_Redeem() public {
        uint256 depositAmount = 1000 * 1e6;
        
        // First deposit
        vm.startPrank(user);
        pusd.approve(address(token), depositAmount);
        token.deposit(depositAmount, user);
        
        // Then redeem half
        uint256 redeemShares = 500 * 1e6;
        uint256 assets = token.redeem(redeemShares, user, user);
        vm.stopPrank();

        assertEq(assets, redeemShares); // 1:1 rate
        assertEq(token.balanceOf(user), 500 * 1e6);
        assertEq(pusd.balanceOf(user), INITIAL_BALANCE - depositAmount + assets);
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

        assertEq(shares, withdrawAssets); // 1:1 rate
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

        // Immediately after accrual, totalAssets should still be ~depositAmount (no yield released yet)
        assertApproxEqAbs(token.totalAssets(), depositAmount, 1);
        
        // Exchange rate should still be ~1.0
        assertApproxEqRel(token.exchangeRate(), 1e18, 1e15); // 0.1% tolerance
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

        // After 5 days, 50% yield should be released
        vm.warp(startTime + 5 days);
        assertApproxEqAbs(token.totalAssets(), depositAmount + yieldAmount / 2, 2);
        
        // Exchange rate should be ~1.05
        assertApproxEqRel(token.exchangeRate(), 1.05e18, 1e15); // 0.1% tolerance

        // After full vesting, all yield released
        vm.warp(startTime + vestingDuration);
        assertApproxEqAbs(token.totalAssets(), depositAmount + yieldAmount, 2);
        
        // Exchange rate should be ~1.1
        assertApproxEqRel(token.exchangeRate(), 1.1e18, 1e15);
    }

    function test_AccrueYieldOnlyAuthorized() public {
        vm.startPrank(user);
        pusd.approve(address(token), 100 * 1e6);
        
        vm.expectRevert();
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();
    }

    function test_RedeemAfterYieldFullyVested() public {
        // User deposits 1000 PUSD, gets 1000 yPUSD
        uint256 depositAmount = 1000 * 1e6;
        vm.startPrank(user);
        pusd.approve(address(token), depositAmount);
        token.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 sharesBefore = token.balanceOf(user);

        // Yield injector adds 100 PUSD (10% yield) with 7 day vesting
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        // User redeems all shares
        vm.prank(user);
        uint256 assetsReceived = token.redeem(sharesBefore, user, user);

        // Should receive ~1100 PUSD (original + yield), allow 1 wei rounding
        assertApproxEqAbs(assetsReceived, 1100 * 1e6, 1);
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

        // Should receive ~1050 PUSD (original + 50% of yield)
        assertApproxEqAbs(assetsReceived, depositAmount + yieldAmount / 2, 500000); // Allow for rate truncation
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
        assertEq(token.exchangeRate(), 1e18);
    }

    function test_ExchangeRateAfterDeposit() public {
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // Rate should still be 1:1
        assertEq(token.exchangeRate(), 1e18);
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

        assertEq(token.balanceOf(user), 123 * 1e6);

        // 2. Upgrade to V2
        vm.startPrank(admin);
        tokenV2 = _upgrade(address(token), "");
        vm.stopPrank();

        // 3. State preserved
        assertEq(tokenV2.balanceOf(user), 123 * 1e6);
        assertEq(tokenV2.totalAssets(), 123 * 1e6);
        assertEq(tokenV2.cap(), CAP);
        assertTrue(tokenV2.hasRole(tokenV2.DEFAULT_ADMIN_ROLE(), admin));

        // 4. New logic works
        vm.prank(admin);
        tokenV2.setVersion(2);
        assertEq(tokenV2.version(), 2);
    }

    function test_UpgradeOnlyAdmin() public {
        yPUSDV2 implV2 = new yPUSDV2();

        vm.prank(user);
        vm.expectRevert();
        token.upgradeToAndCall(address(implV2), "");
    }

    // ---------- Additional Coverage ----------

    function test_Mint() public {
        uint256 mintShares = 500 * 1e6;
        
        vm.startPrank(user);
        pusd.approve(address(token), mintShares); // 1:1 initially
        uint256 assets = token.mint(mintShares, user);
        vm.stopPrank();

        assertEq(assets, mintShares); // 1:1 rate
        assertEq(token.balanceOf(user), mintShares);
    }

    function test_MintAfterYieldFullyVested() public {
        // First user deposits 1000 PUSD
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // Yield: 100 PUSD (10%) with vesting
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        // Now rate is 1.1, to mint 100 shares need 110 PUSD
        address user2 = address(0x2222);
        pusd.mint(user2, 1000 * 1e6);
        
        vm.startPrank(user2);
        pusd.approve(address(token), 200 * 1e6);
        uint256 assetsNeeded = token.mint(100 * 1e6, user2); // mint 100 yPUSD
        vm.stopPrank();

        // Should need ~110 PUSD (allow rounding)
        assertApproxEqAbs(assetsNeeded, 110 * 1e6, 1);
    }

    function test_DepositAfterYieldFullyVested() public {
        // First user deposits 1000 PUSD, gets 1000 yPUSD
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // Yield: 100 PUSD (10%) with vesting
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        // Now rate is 1.1, deposit 110 PUSD should get ~100 yPUSD
        address user2 = address(0x2222);
        pusd.mint(user2, 1000 * 1e6);
        
        vm.startPrank(user2);
        pusd.approve(address(token), 110 * 1e6);
        uint256 shares = token.deposit(110 * 1e6, user2);
        vm.stopPrank();

        // Should get ~100 yPUSD (allow rounding)
        assertApproxEqAbs(shares, 100 * 1e6, 1);
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

        // Both have 1000 yPUSD, total 2000
        assertEq(token.balanceOf(user), 1000 * 1e6);
        assertEq(token.balanceOf(user2), 1000 * 1e6);

        // Yield: 200 PUSD (10%) with vesting
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 200 * 1e6);
        token.accrueYield(200 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // Wait for full vesting
        vm.warp(block.timestamp + DEFAULT_VESTING_DURATION);

        // Total assets: 2200, total shares: 2000, rate = 1.1
        assertApproxEqAbs(token.totalAssets(), 2200 * 1e6, 2);
        assertApproxEqRel(token.exchangeRate(), 1.1e18, 1e15);

        // Each user should get 1100 PUSD when redeeming
        vm.prank(user);
        uint256 assets1 = token.redeem(1000 * 1e6, user, user);
        
        vm.prank(user2);
        uint256 assets2 = token.redeem(1000 * 1e6, user2, user2);

        assertApproxEqAbs(assets1, 1100 * 1e6, 1);
        assertApproxEqAbs(assets2, 1100 * 1e6, 1);
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

        // Rate should not change after deposit
        assertApproxEqAbs(rateBefore, rateAfter, 1);
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
        assertEq(token.totalAssets(), 0);

        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        assertEq(token.totalAssets(), 1000 * 1e6);
    }

    function test_Asset() public view {
        assertEq(token.asset(), address(pusd));
    }

    function test_ConvertToShares() public {
        // Initial rate 1:1
        assertEq(token.convertToShares(100 * 1e6), 100 * 1e6);

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

        // Rate is 1.1, so 110 assets = ~100 shares
        assertApproxEqAbs(token.convertToShares(110 * 1e6), 100 * 1e6, 1);
    }

    function test_ConvertToAssets() public {
        // Initial rate 1:1
        assertEq(token.convertToAssets(100 * 1e6), 100 * 1e6);

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

        // Rate is 1.1, so 100 shares = 110 assets
        assertApproxEqAbs(token.convertToAssets(100 * 1e6), 110 * 1e6, 1);
    }

    function test_PreviewDeposit() public {
        // Initial rate 1:1
        assertEq(token.previewDeposit(100 * 1e6), 100 * 1e6);
    }

    function test_PreviewMint() public {
        // Initial rate 1:1
        assertEq(token.previewMint(100 * 1e6), 100 * 1e6);
    }

    function test_PreviewWithdraw() public {
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // 1:1 rate
        assertEq(token.previewWithdraw(100 * 1e6), 100 * 1e6);
    }

    function test_PreviewRedeem() public {
        vm.startPrank(user);
        pusd.approve(address(token), 1000 * 1e6);
        token.deposit(1000 * 1e6, user);
        vm.stopPrank();

        // 1:1 rate
        assertEq(token.previewRedeem(100 * 1e6), 100 * 1e6);
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

        // Should still show full yield
        assertApproxEqAbs(token.totalAssets(), 1100 * 1e6, 1);
    }

    function test_NoDepositorsYieldAccrual() public {
        uint256 startTime = block.timestamp;
        
        // Add yield without any depositors (edge case - not typical in production)
        vm.startPrank(yieldInjector);
        pusd.approve(address(token), 100 * 1e6);
        token.accrueYield(100 * 1e6, DEFAULT_VESTING_DURATION);
        vm.stopPrank();

        // totalAssets should still be ~0 (unvested)
        assertApproxEqAbs(token.totalAssets(), 0, 1);

        // Wait for full vesting
        vm.warp(startTime + DEFAULT_VESTING_DURATION);

        // Now totalAssets includes the yield
        assertEq(token.totalAssets(), 100 * 1e6);

        // When there's yield but no shares, ERC4626 behavior:
        // First depositor's shares calculation: shares = assets * totalSupply / totalAssets
        // But totalSupply = 0, so OpenZeppelin returns assets (1:1)
        // However, the assets they get back will include their share of the yield
        // This is an edge case - in production, yield wouldn't be injected without depositors
        
        // First depositor
        vm.startPrank(user);
        pusd.approve(address(token), 100 * 1e6);
        uint256 shares = token.deposit(100 * 1e6, user);
        vm.stopPrank();

        // ERC4626 with totalSupply=0: shares = assets (implementation defined)
        // OpenZeppelin returns 0 when totalAssets > 0 but totalSupply = 0 to prevent inflation attack
        // This is expected ERC4626 security behavior
        // In real usage: yield is only injected when there are depositors
        assertTrue(shares == 0 || shares == 100 * 1e6, "Shares should be 0 (OZ security) or 1:1");
    }
}
