// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FarmLend} from "src/Farm/FarmLend.sol";
import {FarmLend_Deployer_Base, FarmLendV2} from "script/Farm/base/FarmLend_Deployer_Base.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockNFTManager} from "test/mocks/MockNFTManager.sol";
import {MockVault} from "test/mocks/MockVault.sol";
import {MockOracle} from "test/mocks/MockOracle.sol";
import {MockFarm} from "test/mocks/MockFarm.sol";
import {IFarm} from "src/interfaces/IFarm.sol";

contract FarmLendTest is Test, FarmLend_Deployer_Base {
    FarmLend public farmLend;
    
    MockNFTManager public nftManager;
    MockVault public vault;
    MockOracle public oracle;
    MockFarm public farm;
    
    ERC20Mock public pusd;
    ERC20Mock public usdt;
    ERC20Mock public usdc;
    
    address public admin = address(0xAD01);
    address public user1 = address(0x1111);
    address public user2 = address(0x2222);
    address public liquidator = address(0x3333);
    
    uint256 public constant TOKEN_ID_1 = 1;
    uint256 public constant TOKEN_ID_2 = 2;
    
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    
    function setUp() public {
        // Set a reasonable timestamp (avoid potential issues with timestamp=1)
        vm.warp(1700000000); // Some time in 2023
        
        // Deploy mock tokens
        pusd = new ERC20Mock("PUSD", "PUSD", 6);
        usdt = new ERC20Mock("USDT", "USDT", 6);
        usdc = new ERC20Mock("USDC", "USDC", 6);
        
        // Deploy mocks
        nftManager = new MockNFTManager();
        vault = new MockVault();
        vault.initialize(address(pusd));
        oracle = new MockOracle();
        farm = new MockFarm();
        
        // Deploy FarmLend
        bytes32 salt = bytes32("FARMLEND_TEST");
        farmLend = _deployFarmLend(
            admin,
            address(nftManager),
            address(vault),
            address(oracle),
            address(farm),
            salt
        );
        
        // Setup oracle prices (1 USDT = 1 PUSD, represented as 1e18)
        oracle.setTokenPUSDPrice(address(usdt), 1e18);
        oracle.setTokenPUSDPrice(address(usdc), 1e18);
        // Set timestamp to current block timestamp
        oracle.setLastTokenPriceTimestamp(block.timestamp);
        
        // Allow debt tokens
        vm.startPrank(admin);
        farmLend.setAllowedDebtToken(address(usdt), true);
        farmLend.setAllowedDebtToken(address(usdc), true);
        vm.stopPrank();
        
        // Fund vault with tokens
        usdt.mint(address(vault), 1_000_000e6);
        usdc.mint(address(vault), 1_000_000e6);
        pusd.mint(address(vault), 1_000_000e6);
        
        // Setup user1 with NFT and stake
        nftManager.setOwner(TOKEN_ID_1, user1);
        nftManager.setStakeRecord(TOKEN_ID_1, _createStakeRecord(1000e6, true));
        
        // Setup user2 with NFT
        nftManager.setOwner(TOKEN_ID_2, user2);
        nftManager.setStakeRecord(TOKEN_ID_2, _createStakeRecord(2000e6, true));

        // Approve FarmLend to transfer NFTs (required for borrowWithNFT)
        vm.prank(user1);
        nftManager.setApprovalForAll(address(farmLend), true);
        vm.prank(user2);
        nftManager.setApprovalForAll(address(farmLend), true);
    }

    /// @dev Helper function to create StakeRecord struct
    function _createStakeRecord(uint256 amount, bool active) internal view returns (IFarm.StakeRecord memory) {
        return IFarm.StakeRecord({
            amount: amount,
            startTime: block.timestamp,
            lockPeriod: 30 days,
            lastClaimTime: block.timestamp,
            rewardMultiplier: 10000,
            active: active,
            pendingReward: 0
        });
    }

    // ==================== Initialization Tests ====================

    function test_Initialize_Success() public view {
        assertEq(address(farmLend.nftManager()), address(nftManager));
        assertEq(address(farmLend.vault()), address(vault));
        assertEq(address(farmLend.pusdOracle()), address(oracle));
        assertEq(farmLend.farm(), address(farm));
        assertTrue(farmLend.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_Initialize_OnlyOnce() public {
        vm.expectRevert();
        farmLend.initialize(admin, address(nftManager), address(vault), address(oracle), address(farm));
    }

    function test_Initialize_RevertZeroNFTManager() public {
        FarmLend impl = new FarmLend();
        vm.expectRevert("FarmLend: zero NFTManager address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (admin, address(0), address(vault), address(oracle), address(farm)))
        );
    }

    function test_Initialize_RevertZeroVault() public {
        FarmLend impl = new FarmLend();
        vm.expectRevert("FarmLend: zero vault address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (admin, address(nftManager), address(0), address(oracle), address(farm)))
        );
    }

    function test_Initialize_RevertZeroOracle() public {
        FarmLend impl = new FarmLend();
        vm.expectRevert("FarmLend: zero PUSD Oracle address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (admin, address(nftManager), address(vault), address(0), address(farm)))
        );
    }

    function test_DefaultLoanDurationInterestRatios() public view {
        assertEq(farmLend.loanDurationInterestRatios(30 days), 110); // 1.1%
        assertEq(farmLend.loanDurationInterestRatios(60 days), 200); // 2%
    }

    // ==================== Admin Configuration Tests ====================

    function test_SetAllowedDebtToken() public {
        address newToken = address(0x9999);
        
        vm.prank(admin);
        farmLend.setAllowedDebtToken(newToken, true);
        assertTrue(farmLend.allowedDebtTokens(newToken));
        
        vm.prank(admin);
        farmLend.setAllowedDebtToken(newToken, false);
        assertFalse(farmLend.allowedDebtTokens(newToken));
    }

    function test_SetAllowedDebtToken_RevertUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        farmLend.setAllowedDebtToken(address(0x9999), true);
    }

    function test_SetPUSDOracle() public {
        address newOracle = address(0x8888);
        
        vm.prank(admin);
        farmLend.setPUSDOracle(newOracle);
        assertEq(address(farmLend.pusdOracle()), newOracle);
    }

    function test_SetPUSDOracle_RevertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("FarmLend: zero PUSD Oracle address");
        farmLend.setPUSDOracle(address(0));
    }

    function test_SetPUSDOracle_RevertUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        farmLend.setPUSDOracle(address(0x8888));
    }

    function test_SetLiquidationRatio() public {
        vm.prank(admin);
        farmLend.setLiquidationRatio(11000); // 110%
        assertEq(farmLend.liquidationRatio(), 11000);
    }

    function test_SetLiquidationRatio_RevertBelow100() public {
        vm.prank(admin);
        vm.expectRevert("FarmLend: CR below 100%");
        farmLend.setLiquidationRatio(9999);
    }

    function test_SetLiquidationRatio_RevertAboveTarget() public {
        vm.prank(admin);
        vm.expectRevert("FarmLend: must be < targetCollateralRatio");
        farmLend.setLiquidationRatio(14000); // > targetCollateralRatio (13000)
    }

    function test_SetTargetCollateralRatio() public {
        vm.prank(admin);
        farmLend.setTargetCollateralRatio(15000); // 150%
        assertEq(farmLend.targetCollateralRatio(), 15000);
    }

    function test_SetTargetCollateralRatio_RevertBelowLiquidation() public {
        vm.prank(admin);
        vm.expectRevert("FarmLend: must be >= liquidationRatio");
        farmLend.setTargetCollateralRatio(12000); // < liquidationRatio (12500)
    }

    function test_SetCollateralRatios() public {
        vm.prank(admin);
        farmLend.setCollateralRatios(11000, 14000);
        assertEq(farmLend.liquidationRatio(), 11000);
        assertEq(farmLend.targetCollateralRatio(), 14000);
    }

    function test_SetCollateralRatios_RevertInvalid() public {
        vm.prank(admin);
        vm.expectRevert("FarmLend: liquidation < target");
        farmLend.setCollateralRatios(14000, 12000); // liquidation > target
    }

    function test_SetPenaltyRatio() public {
        vm.prank(admin);
        farmLend.setPenaltyRatio(500); // 5%
        assertEq(farmLend.penaltyRatio(), 500);
    }

    function test_SetLoanDurationInterestRatios() public {
        vm.prank(admin);
        farmLend.setLoanDurationInterestRatios(90 days, 300); // 3% for 90 days
        assertEq(farmLend.loanDurationInterestRatios(90 days), 300);
    }

    function test_SetLoanGracePeriod() public {
        vm.prank(admin);
        farmLend.setLoanGracePeriod(14 days);
        assertEq(farmLend.loanGracePeriod(), 14 days);
    }

    function test_SetPenaltyGracePeriod() public {
        vm.prank(admin);
        farmLend.setPenaltyGracePeriod(2 days);
        assertEq(farmLend.penaltyGracePeriod(), 2 days);
    }

    function test_SetPenaltyGracePeriod_RevertExceedsLoanGrace() public {
        vm.prank(admin);
        vm.expectRevert("FarmLend: penalty grace > loan grace");
        farmLend.setPenaltyGracePeriod(10 days); // > loanGracePeriod (7 days)
    }

    function test_SetLiquidationBonus() public {
        vm.prank(admin);
        farmLend.setLiquidationBonus(500); // 5%
        assertEq(farmLend.liquidationBonus(), 500);
    }

    function test_SetLiquidationBonus_RevertTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("FarmLend: bonus too high");
        farmLend.setLiquidationBonus(1100); // > 10%
    }

    // ==================== maxBorrowable Tests ====================

    function test_MaxBorrowable() public view {
        // 1000 PUSD collateral, 125% CR, price 1:1
        // maxBorrow = 1000 / 1.25 = 800 USDT
        uint256 maxBorrow = farmLend.maxBorrowable(TOKEN_ID_1, address(usdt));
        assertEq(maxBorrow, 800e6);
    }

    function test_MaxBorrowable_DifferentPrice() public {
        // Set USDT price to 1.1 PUSD (USDT more valuable)
        oracle.setTokenPUSDPrice(address(usdt), 1.1e18);
        
        // 1000 PUSD collateral, 125% CR, price 1.1
        // collateralTokens = 1000 / 1.1 = 909.09
        // maxBorrow = 909.09 / 1.25 = 727.27
        uint256 maxBorrow = farmLend.maxBorrowable(TOKEN_ID_1, address(usdt));
        assertApproxEqAbs(maxBorrow, 727e6, 1e6);
    }

    function test_MaxBorrowable_RevertStalePrice() public {
        // Set price timestamp to 2 hours ago
        oracle.setLastTokenPriceTimestamp(block.timestamp - 7200);
        
        vm.expectRevert("FarmLend: stale debt token price");
        farmLend.maxBorrowable(TOKEN_ID_1, address(usdt));
    }

    function test_MaxBorrowable_RevertInactiveStake() public {
        nftManager.setStakeRecord(TOKEN_ID_1, _createStakeRecord(1000e6, false));
        
        vm.expectRevert("FarmLend: stake not active");
        farmLend.maxBorrowable(TOKEN_ID_1, address(usdt));
    }

    // ==================== Borrow Tests ====================

    function test_BorrowWithNFT_Success() public {
        vm.startPrank(user1);
        
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        vm.stopPrank();
        
        // Check loan is active
        assertTrue(farmLend.isLoanActive(TOKEN_ID_1));
        
        // Check loan details
        (uint256 principal, , , ) = farmLend.getLoanDebt(TOKEN_ID_1);
        assertEq(principal, 500e6);
        
        // Check NFT transferred to vault
        assertEq(nftManager.ownerOf(TOKEN_ID_1), address(vault));
    }

    function test_BorrowWithNFT_RevertNotOwner() public {
        vm.prank(user2);
        vm.expectRevert("FarmLend: not NFT owner");
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
    }

    function test_BorrowWithNFT_RevertDebtTokenNotAllowed() public {
        address randomToken = address(0x7777);
        
        vm.prank(user1);
        vm.expectRevert("FarmLend: debt token not allowed");
        farmLend.borrowWithNFT(TOKEN_ID_1, randomToken, 500e6, 30 days);
    }

    function test_BorrowWithNFT_RevertZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("FarmLend: zero amount");
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 0, 30 days);
    }

    function test_BorrowWithNFT_RevertExceedsMax() public {
        vm.prank(user1);
        vm.expectRevert("FarmLend: amount exceeds max borrowable");
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 900e6, 30 days); // > 800 max
    }

    function test_BorrowWithNFT_RevertInvalidDuration() public {
        vm.prank(user1);
        vm.expectRevert("FarmLend: invalid loan duration");
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 45 days); // not configured
    }

    function test_BorrowWithNFT_RevertLoanAlreadyActive() public {
        vm.startPrank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Reset NFT owner for second attempt (simulating)
        vm.stopPrank();
        nftManager.setOwner(TOKEN_ID_1, user1);
        
        vm.prank(user1);
        vm.expectRevert("FarmLend: loan already active");
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 100e6, 30 days);
    }

    // ==================== getLoanDebt Tests ====================

    function test_GetLoanDebt_NoLoan() public view {
        (uint256 principal, uint256 interest, uint256 penalty, uint256 total) = farmLend.getLoanDebt(TOKEN_ID_1);
        assertEq(principal, 0);
        assertEq(interest, 0);
        assertEq(penalty, 0);
        assertEq(total, 0);
    }

    function test_GetLoanDebt_WithInterest() public {
        // Borrow
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Fast forward 15 days (half of loan duration)
        vm.warp(block.timestamp + 15 days);
        
        // Interest = 500 * 1.1% * 15/30 = 500 * 0.011 * 0.5 = 2.75
        (uint256 principal, uint256 interest, uint256 penalty, uint256 total) = farmLend.getLoanDebt(TOKEN_ID_1);
        assertEq(principal, 500e6);
        assertApproxEqAbs(interest, 2.75e6, 0.1e6);
        assertEq(penalty, 0);
        assertApproxEqAbs(total, 502.75e6, 0.1e6);
    }

    function test_GetLoanDebt_WithPenalty() public {
        // Borrow
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Fast forward past due date + penalty grace period (30 days + 3 days + 2 days)
        vm.warp(block.timestamp + 35 days);
        
        // Should have both interest and penalty
        (uint256 principal, uint256 interest, uint256 penalty, uint256 total) = farmLend.getLoanDebt(TOKEN_ID_1);
        assertEq(principal, 500e6);
        assertTrue(interest > 0);
        assertTrue(penalty > 0); // 2 days * 4% per day
        assertEq(total, principal + interest + penalty);
    }

    // ==================== getHealthFactor Tests ====================

    function test_GetHealthFactor_NoLoan() public view {
        uint256 hf = farmLend.getHealthFactor(TOKEN_ID_1);
        assertEq(hf, type(uint256).max);
    }

    function test_GetHealthFactor_HealthyLoan() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Collateral: 1000 PUSD, Debt: 500 USDT, CR = 200%
        // healthFactor = 200% / 125% = 1.6 > 1
        uint256 hf = farmLend.getHealthFactor(TOKEN_ID_1);
        assertTrue(hf > 1e18);
    }

    // ==================== Repay Tests ====================

    function test_Repay_Partial() public {
        // Borrow
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Mint USDT to user1 for repayment
        usdt.mint(user1, 200e6);
        
        // Approve and repay partial
        vm.startPrank(user1);
        usdt.approve(address(vault), 200e6);
        farmLend.repay(TOKEN_ID_1, 200e6);
        vm.stopPrank();
        
        // Check loan still active
        assertTrue(farmLend.isLoanActive(TOKEN_ID_1));
        
        // Check reduced principal
        (uint256 principal, , , ) = farmLend.getLoanDebt(TOKEN_ID_1);
        assertEq(principal, 300e6);
    }

    function test_RepayFull() public {
        // Borrow
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Fast forward a bit
        vm.warp(block.timestamp + 10 days);
        
        // Get total debt
        (, , , uint256 totalDebt) = farmLend.getLoanDebt(TOKEN_ID_1);
        
        // Mint USDT to user1 for repayment
        usdt.mint(user1, totalDebt);
        
        // Approve and repay full
        vm.startPrank(user1);
        usdt.approve(address(vault), totalDebt);
        farmLend.repayFull(TOKEN_ID_1);
        vm.stopPrank();
        
        // Check loan is closed
        assertFalse(farmLend.isLoanActive(TOKEN_ID_1));
    }

    function test_Repay_RevertNoActiveLoan() public {
        vm.prank(user1);
        vm.expectRevert("FarmLend: no active loan");
        farmLend.repay(TOKEN_ID_1, 100e6);
    }

    function test_Repay_RevertZeroAmount() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        vm.prank(user1);
        vm.expectRevert("FarmLend: zero amount");
        farmLend.repay(TOKEN_ID_1, 0);
    }

    function test_Repay_RevertOverdue() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Fast forward past grace period
        vm.warp(block.timestamp + 38 days); // 30 days loan + 7 days grace + 1 day
        
        usdt.mint(user1, 600e6);
        vm.startPrank(user1);
        usdt.approve(address(farmLend), 600e6);
        
        vm.expectRevert("FarmLend: loan overdue, cannot repay");
        farmLend.repay(TOKEN_ID_1, 500e6);
        vm.stopPrank();
    }

    // ==================== Liquidate Tests ====================

    function test_Liquidate_Success() public {
        // Default: liquidationRatio = 12500 (125%), targetCR = 13000 (130%)
        // Price increases to 1.05 (token appreciates, collateral worth less in token terms)
        _testLiquidateWithParams(12500, 13000, 300, 780e6, 34 days, 800e6, 1.05e18, "Default 125%/130%");
    }

    function test_Liquidate_Success_Params_120_125() public {
        // Tighter gap: liquidationRatio = 12000 (120%), targetCR = 12500 (125%)
        _testLiquidateWithParams(12000, 12500, 300, 820e6, 34 days, 900e6, 1.05e18, "120%/125%");
    }

    function test_Liquidate_Success_Params_125_135() public {
        // Medium gap: liquidationRatio = 12500 (125%), targetCR = 13500 (135%)
        _testLiquidateWithParams(12500, 13500, 300, 780e6, 34 days, 800e6, 1.05e18, "125%/135%");
    }

    function test_Liquidate_Success_Params_130_145() public {
        // Conservative: liquidationRatio = 13000 (130%), targetCR = 14500 (145%)
        _testLiquidateWithParams(13000, 14500, 300, 750e6, 38 days, 1200e6, 1.08e18, "130%/145%");
    }

    function test_Liquidate_Success_HighBonus() public {
        // Higher liquidation bonus: 5%
        _testLiquidateWithParams(12500, 13500, 500, 780e6, 34 days, 800e6, 1.05e18, "125%/135% with 5% bonus");
    }

    function test_Liquidate_Success_LowBonus() public {
        // Lower liquidation bonus: 1%
        _testLiquidateWithParams(12500, 13000, 100, 780e6, 34 days, 800e6, 1.05e18, "125%/130% with 1% bonus");
    }

    function _testLiquidateWithParams(
        uint16 liquidationRatio_,
        uint16 targetCR_,
        uint16 bonus_,
        uint256 borrowAmount,
        uint256 warpTime,
        uint256 maxLiquidateAmount,
        uint256 newTokenPrice,
        string memory label
    ) internal {
        emit log_string("========================================");
        emit log_string(label);
        emit log_named_uint("liquidationRatio (bps)", liquidationRatio_);
        emit log_named_uint("targetCR (bps)", targetCR_);
        emit log_named_uint("bonus (bps)", bonus_);
        emit log_named_uint("newTokenPrice (1e18)", newTokenPrice);
        
        // Calculate denominator: t - 1 - bonus (in bps for display)
        uint256 denomBps = targetCR_ - 10000 - bonus_;
        emit log_named_uint("Denominator (t-1-bonus) bps", denomBps);
        
        // Set parameters
        vm.startPrank(admin);
        farmLend.setCollateralRatios(liquidationRatio_, targetCR_);
        farmLend.setLiquidationBonus(bonus_);
        vm.stopPrank();
        
        // Check maxBorrow before borrowing
        uint256 maxBorrowBefore = farmLend.maxBorrowable(TOKEN_ID_1, address(usdt));
        emit log_named_uint("MaxBorrow before", maxBorrowBefore);
        
        // Adjust borrow amount if needed
        uint256 actualBorrow = borrowAmount > maxBorrowBefore ? maxBorrowBefore - 1e6 : borrowAmount;
        emit log_named_uint("Actual borrow", actualBorrow);
        
        // Borrow
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), actualBorrow, 30 days);
        
        // Fast forward and change price (token appreciates = collateral worth less)
        vm.warp(block.timestamp + warpTime);
        oracle.setTokenPUSDPrice(address(usdt), newTokenPrice);
        oracle.setLastTokenPriceTimestamp(block.timestamp);
        
        // Check current debt  
        (uint256 principal, uint256 interest, uint256 penalty, uint256 totalDebt) = farmLend.getLoanDebt(TOKEN_ID_1);
        uint256 maxBorrow = farmLend.maxBorrowable(TOKEN_ID_1, address(usdt));
        
        emit log_named_uint("Principal", principal);
        emit log_named_uint("Interest", interest);  
        emit log_named_uint("Penalty", penalty);
        emit log_named_uint("TotalDebt", totalDebt);
        emit log_named_uint("MaxBorrow (current)", maxBorrow);
        emit log_named_uint("Current CR (bps)", (1000e6 * 1e18 * 10000) / (totalDebt * newTokenPrice)); // adjusted for price
        
        // With price change + penalties, totalDebt should exceed maxBorrow
        assertTrue(totalDebt > maxBorrow, "Loan should be liquidatable");
        
        // Liquidator prepares
        usdt.mint(liquidator, maxLiquidateAmount);
        vm.startPrank(liquidator);
        usdt.approve(address(vault), maxLiquidateAmount);
        
        emit log_named_uint("maxLiquidateAmount provided", maxLiquidateAmount);
        
        // Liquidate 
        farmLend.liquidate(TOKEN_ID_1, maxLiquidateAmount);
        vm.stopPrank();
        
        // Check loan state changed - some debt paid off
        (, , , uint256 totalDebtAfter) = farmLend.getLoanDebt(TOKEN_ID_1);
        emit log_named_uint("TotalDebt after liquidation", totalDebtAfter);
        emit log_named_uint("Actual x (debt reduced by)", totalDebt - totalDebtAfter);
        assertTrue(totalDebtAfter < totalDebt, "total debt should be reduced");
        emit log_string("========================================");
    }

    function test_Liquidate_RevertNotLiquidatable() public {
        // User borrows conservative amount
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 400e6, 30 days);
        
        // Loan is healthy (CR = 250% > 125%)
        usdt.mint(liquidator, 200e6);
        vm.startPrank(liquidator);
        usdt.approve(address(vault), 200e6);
        
        vm.expectRevert("FarmLend: not liquidatable");
        farmLend.liquidate(TOKEN_ID_1, 200e6);
        vm.stopPrank();
    }

    function test_Liquidate_RevertNoActiveLoan() public {
        vm.prank(liquidator);
        vm.expectRevert("FarmLend: no active loan");
        farmLend.liquidate(TOKEN_ID_1, 100e6);
    }

    // ==================== seizeOverdueNFT Tests ====================

    function test_SeizeOverdueNFT() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Fast forward past grace period
        vm.warp(block.timestamp + 38 days);
        
        vm.prank(admin);
        farmLend.seizeOverdueNFT(TOKEN_ID_1);
        
        // Loan should be inactive
        assertFalse(farmLend.isLoanActive(TOKEN_ID_1));
    }

    function test_SeizeOverdueNFT_RevertNotOverdue() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Only 20 days passed
        vm.warp(block.timestamp + 20 days);
        
        vm.prank(admin);
        vm.expectRevert("FarmLend: not overdue enough");
        farmLend.seizeOverdueNFT(TOKEN_ID_1);
    }

    function test_SeizeOverdueNFT_RevertUnauthorized() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        vm.warp(block.timestamp + 38 days);
        
        vm.prank(user1);
        vm.expectRevert();
        farmLend.seizeOverdueNFT(TOKEN_ID_1);
    }

    // ==================== claimCollateral Tests ====================

    function test_ClaimCollateral_RevertLoanStillActive() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        vm.prank(user1);
        vm.expectRevert("FarmLend: loan still active");
        farmLend.claimCollateral(TOKEN_ID_1);
    }

    // ==================== View Functions Tests ====================

    function test_GetTokenIdsForDebt() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        uint256[] memory tokenIds = farmLend.getTokenIdsForDebt(user1);
        assertEq(tokenIds.length, 1);
        assertEq(tokenIds[0], TOKEN_ID_1);
    }

    function test_GetLoan() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        FarmLend.Loan memory loan = farmLend.getLoan(TOKEN_ID_1);
        assertTrue(loan.active);
        assertEq(loan.borrower, user1);
        assertEq(loan.borrowedAmount, 500e6);
        assertEq(loan.debtToken, address(usdt));
    }

    function test_GetLoansForBorrower() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        (uint256[] memory tokenIds, FarmLend.Loan[] memory loans) = farmLend.getLoansForBorrower(user1);
        assertEq(tokenIds.length, 1);
        assertEq(loans.length, 1);
        assertEq(loans[0].borrowedAmount, 500e6);
    }

    function test_GetBorrowerLoansSummary() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        (
            uint256[] memory tokenIds,
            uint256[] memory principals,
            uint256[] memory totalDebts,
            uint256[] memory healthFactors
        ) = farmLend.getBorrowerLoansSummary(user1);
        
        assertEq(tokenIds.length, 1);
        assertEq(principals[0], 500e6);
        assertEq(totalDebts[0], 500e6); // No interest accrued yet
        assertTrue(healthFactors[0] > 1e18); // Healthy
    }

    // ==================== Interest and Penalty Calculation Tests ====================

    function test_InterestCalculation() public {
        // With 1000 PUSD collateral and 125% LR, max borrow = 800 USDT
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Full duration
        vm.warp(block.timestamp + 30 days);
        
        // Interest = 500 * 1.1% = 5.5 USDT
        (, uint256 interest, , ) = farmLend.getLoanDebt(TOKEN_ID_1);
        assertApproxEqAbs(interest, 5.5e6, 0.1e6);
    }

    function test_PenaltyCalculation() public {
        // With 1000 PUSD collateral and 125% LR, max borrow = 800 USDT
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Past due date + penalty grace period + 5 days
        // Penalty actually accrues from endTime (dueDate), not from grace period end
        // So penalty days = 8 days (30 days dueTime to 38 days)
        vm.warp(block.timestamp + 30 days + 3 days + 5 days);
        
        // Penalty = 500 * 0.5% * 8 days = 20 USDT (penaltyRatio changed from 4% to 0.5%)
        (, , uint256 penalty, ) = farmLend.getLoanDebt(TOKEN_ID_1);
        assertApproxEqAbs(penalty, 20e6, 1e6);
    }

    // ==================== Edge Cases ====================

    function test_MultipleBorrows_DifferentUsers() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        vm.prank(user2);
        farmLend.borrowWithNFT(TOKEN_ID_2, address(usdc), 1000e6, 60 days);
        
        assertTrue(farmLend.isLoanActive(TOKEN_ID_1));
        assertTrue(farmLend.isLoanActive(TOKEN_ID_2));
        
        (uint256 principal1, , , ) = farmLend.getLoanDebt(TOKEN_ID_1);
        (uint256 principal2, , , ) = farmLend.getLoanDebt(TOKEN_ID_2);
        
        assertEq(principal1, 500e6);
        assertEq(principal2, 1000e6);
    }

    function test_RepayPriority_PenaltyFirst() public {
        vm.prank(user1);
        farmLend.borrowWithNFT(TOKEN_ID_1, address(usdt), 500e6, 30 days);
        
        // Accrue penalty
        vm.warp(block.timestamp + 35 days);
        
        (, uint256 interestBefore, uint256 penaltyBefore, ) = farmLend.getLoanDebt(TOKEN_ID_1);
        assertTrue(penaltyBefore > 0);
        
        // Repay small amount (should go to penalty first)
        uint256 smallRepay = penaltyBefore / 2;
        usdt.mint(user1, smallRepay);
        
        vm.startPrank(user1);
        usdt.approve(address(vault), smallRepay);
        farmLend.repay(TOKEN_ID_1, smallRepay);
        vm.stopPrank();
        
        // Penalty should be reduced, principal unchanged
        (uint256 principal, , uint256 penaltyAfter, ) = farmLend.getLoanDebt(TOKEN_ID_1);
        assertEq(principal, 500e6);
        assertTrue(penaltyAfter < penaltyBefore);
    }
}
