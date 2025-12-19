// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockOracle} from "test/mocks/MockOracle.sol";
import {FarmUpgradeable} from "src/Farm/Farm.sol";
import {NFTManager} from "src/token/NFTManager/NFTManager.sol";
import {Vault} from "src/Vault/Vault.sol";
import {yPUSD} from "src/token/yPUSD/yPUSD.sol";
import {IFarm} from "src/interfaces/IFarm.sol";
import {Farm_Deployer_Base} from "script/Farm/base/Farm_Deployer_Base.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Farm Integration Tests
 * @notice Integration tests - Tests complete interaction flow between Farm and real Vault, yPUSD, NFTManager
 * @dev Uses real contracts, tests end-to-end flows
 */
contract FarmIntegrationTest is Test, Farm_Deployer_Base {
    FarmUpgradeable farm;
    NFTManager nftManager;
    Vault vault;
    ERC20Mock pusd;
    yPUSD ypusd;
    ERC20Mock usdt;
    MockOracle oracle;

    address admin = address(0xA11CE);
    address user1 = address(0xCAFE);
    address user2 = address(0xBEEF);
    address operator = address(0x0908);

    uint256 constant INITIAL_BALANCE = 100_000 * 1e6;
    uint256 constant YPUSD_CAP = 1_000_000_000 * 1e6;

    function setUp() public {
        vm.startPrank(admin);

        // Deploy mock tokens
        usdt = new ERC20Mock("Tether USD", "USDT", 6);
        pusd = new ERC20Mock("Phoenix USD", "PUSD", 6);

        // Deploy yPUSD
        yPUSD ypusdImpl = new yPUSD();
        bytes memory ypusdInitData = abi.encodeCall(
            yPUSD.initialize,
            (IERC20(address(pusd)), YPUSD_CAP, admin)
        );
        ypusd = yPUSD(address(new ERC1967Proxy(address(ypusdImpl), ypusdInitData)));

        // Deploy Oracle mock
        oracle = new MockOracle();
        oracle.setTokenPUSDPrice(address(usdt), 1e18); // 1 USDT = 1 PUSD
        oracle.setLastTokenPriceTimestamp(block.timestamp);

        // Deploy Vault
        Vault vaultImpl = new Vault();
        bytes memory vaultInitData = abi.encodeCall(
            Vault.initialize,
            (admin, address(pusd), address(0)) // nftManager can be set later
        );
        vault = Vault(address(new ERC1967Proxy(address(vaultImpl), vaultInitData)));
        vault.setOracleManager(address(oracle));

        // Deploy Farm using deployer base
        bytes32 salt = bytes32("FARM_TEST_SALT");
        farm = Farm_Deployer_Base._deploy(admin, address(pusd), address(ypusd), address(vault), salt);

        // Deploy NFTManager
        NFTManager nftManagerImpl = new NFTManager();
        bytes memory nftInitData = abi.encodeCall(
            NFTManager.initialize,
            ("Phoenix Stake NFT", "PSN", admin, address(farm))
        );
        nftManager = NFTManager(address(new ERC1967Proxy(address(nftManagerImpl), nftInitData)));

        // Setup roles and connections
        farm.grantRole(farm.OPERATOR_ROLE(), operator);
        farm.setNFTManager(address(nftManager));
        
        vault.setFarmAddress(address(farm));
        vault.addAsset(address(usdt), "USDT");
        
        // Add reward reserve: mint PUSD and approve to vault
        pusd.mint(admin, INITIAL_BALANCE * 100);
        pusd.approve(address(vault), INITIAL_BALANCE * 100);
        vault.addRewardReserve(INITIAL_BALANCE * 100);

        // Setup lock periods
        uint256[] memory periods = new uint256[](3);
        uint16[] memory multipliers = new uint16[](3);
        periods[0] = 30 days;
        periods[1] = 90 days;
        periods[2] = 180 days;
        multipliers[0] = 10000;  // 1x
        multipliers[1] = 15000;  // 1.5x
        multipliers[2] = 20000;  // 2x
        farm.batchSetLockPeriodMultipliers(periods, multipliers);

        vm.stopPrank();

        // Mint tokens to users
        usdt.mint(user1, INITIAL_BALANCE);
        usdt.mint(user2, INITIAL_BALANCE);
        
        // Fund vault with USDT for withdrawals
        usdt.mint(address(vault), INITIAL_BALANCE * 10);
    }

    // ==================== Deposit Tests ====================

    function test_DepositAsset_Success() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.startPrank(user1);
        usdt.approve(address(vault), depositAmount);
        farm.depositAsset(address(usdt), depositAmount);
        vm.stopPrank();

        assertGt(pusd.balanceOf(user1), 0);
    }

    function test_DepositAsset_WithFee() public {
        // Set deposit fee to 1%
        vm.prank(admin);
        farm.setFeeRates(100, 0, 0); // 1% deposit fee

        uint256 depositAmount = 1000 * 1e6;

        vm.startPrank(user1);
        usdt.approve(address(vault), depositAmount);
        farm.depositAsset(address(usdt), depositAmount);
        vm.stopPrank();

        // User should receive PUSD minus 1% fee
        uint256 expectedPUSD = depositAmount - (depositAmount * 100 / 10000);
        assertEq(pusd.balanceOf(user1), expectedPUSD);
    }

    function test_DepositAsset_RevertInvalidAsset() public {
        ERC20Mock invalidToken = new ERC20Mock("Invalid", "INV", 6);
        invalidToken.mint(user1, 1000 * 1e6);

        vm.startPrank(user1);
        invalidToken.approve(address(vault), 1000 * 1e6);
        vm.expectRevert("Unsupported asset");
        farm.depositAsset(address(invalidToken), 1000 * 1e6);
        vm.stopPrank();
    }

    // ==================== Withdraw Tests ====================

    function test_WithdrawAsset_Success() public {
        uint256 depositAmount = 1000 * 1e6;

        // First deposit
        vm.startPrank(user1);
        usdt.approve(address(vault), depositAmount);
        farm.depositAsset(address(usdt), depositAmount);

        uint256 pusdBalance = pusd.balanceOf(user1);
        
        // Then withdraw
        farm.withdrawAsset(address(usdt), pusdBalance);
        vm.stopPrank();

        // PUSD should be burned
        assertEq(pusd.balanceOf(user1), 0);
        // User should receive USDT back
        assertGt(usdt.balanceOf(user1), INITIAL_BALANCE - depositAmount);
    }

    // ==================== Stake Tests ====================

    function test_StakePUSD_Success() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 stakeAmount = 500 * 1e6;

        // First get PUSD
        vm.startPrank(user1);
        usdt.approve(address(vault), depositAmount);
        farm.depositAsset(address(usdt), depositAmount);

        // Approve and stake
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        // Check NFT minted
        assertEq(nftManager.ownerOf(tokenId), user1);
        
        // Check stake record
        IFarm.StakeRecord memory record = nftManager.getStakeRecord(tokenId);
        assertEq(record.amount, stakeAmount);
        assertEq(record.lockPeriod, 30 days);
        assertTrue(record.active);
    }

    function test_StakePUSD_RevertInvalidLockPeriod() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.startPrank(user1);
        usdt.approve(address(vault), depositAmount);
        farm.depositAsset(address(usdt), depositAmount);

        pusd.approve(address(farm), depositAmount);
        vm.expectRevert("Unsupported lock period");
        farm.stakePUSD(500 * 1e6, 7 days); // 7 days not supported
        vm.stopPrank();
    }

    function test_StakePUSD_RevertInsufficientBalance() public {
        vm.startPrank(user1);
        pusd.approve(address(farm), 1000 * 1e6);
        vm.expectRevert("Insufficient PUSD balance");
        farm.stakePUSD(1000 * 1e6, 30 days);
        vm.stopPrank();
    }

    // ==================== Unstake Tests ====================

    function test_UnstakePUSD_Success() public {
        uint256 stakeAmount = 500 * 1e6;

        // Setup: deposit and stake
        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        // Warp past lock period
        vm.warp(block.timestamp + 31 days);
        oracle.setLastTokenPriceTimestamp(block.timestamp); // Update oracle timestamp
        vm.prank(address(oracle));
        vault.heartbeat(); // Update vault health check

        // Unstake
        vm.prank(user1);
        farm.unstakePUSD(tokenId);

        // NFT should be burned
        vm.expectRevert();
        nftManager.ownerOf(tokenId);

        // User should get PUSD back (plus any rewards)
        assertGe(pusd.balanceOf(user1), stakeAmount);
    }

    function test_UnstakePUSD_RevertStillLocked() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);

        // Try to unstake before lock period ends
        vm.expectRevert("Still in lock period");
        farm.unstakePUSD(tokenId);
        vm.stopPrank();
    }

    function test_UnstakePUSD_RevertNotOwner() public {
        uint256 stakeAmount = 500 * 1e6;

        // User1 stakes
        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        // User2 tries to unstake
        vm.prank(user2);
        vm.expectRevert("Not stake owner");
        farm.unstakePUSD(tokenId);
    }

    // ==================== Renew Stake Tests ====================

    function test_RenewStake_Success() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        // Warp past lock period
        vm.warp(block.timestamp + 31 days);

        // Renew with new lock period
        vm.prank(user1);
        farm.renewStake(tokenId, false, 90 days);

        // Check updated record
        IFarm.StakeRecord memory record = nftManager.getStakeRecord(tokenId);
        assertEq(record.lockPeriod, 90 days);
        assertTrue(record.active);
    }

    function test_RenewStake_WithCompound() public {
        uint256 stakeAmount = 500 * 1e6;

        // Setup reward reserve
        vm.prank(admin);
        pusd.mint(address(vault), 10000 * 1e6);

        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        // Warp to accumulate rewards
        vm.warp(block.timestamp + 31 days);

        IFarm.StakeRecord memory recordBefore = nftManager.getStakeRecord(tokenId);

        // Renew with compound
        vm.prank(user1);
        farm.renewStake(tokenId, true, 30 days);

        IFarm.StakeRecord memory recordAfter = nftManager.getStakeRecord(tokenId);
        
        // Amount should have increased due to compounding
        assertGe(recordAfter.amount, recordBefore.amount);
    }

    // ==================== Claim Rewards Tests ====================

    function test_ClaimStakeRewards_Success() public {
        uint256 stakeAmount = 500 * 1e6;

        // Setup reward reserve
        vm.prank(admin);
        pusd.mint(address(vault), 10000 * 1e6);

        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        uint256 pusdBefore = pusd.balanceOf(user1);

        // Warp to accumulate rewards (but stay within lock period)
        vm.warp(block.timestamp + 15 days);

        // Claim rewards
        vm.prank(user1);
        farm.claimStakeRewards(tokenId);

        // Should have received some rewards
        assertGt(pusd.balanceOf(user1), pusdBefore);
    }

    function test_ClaimStakeRewards_RevertNotOwner() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 15 days);

        // User2 tries to claim
        vm.prank(user2);
        vm.expectRevert("Not stake owner");
        farm.claimStakeRewards(tokenId);
    }

    // ==================== APY Management Tests ====================

    function test_SetAPY_Success() public {
        vm.prank(admin);
        farm.setAPY(3000); // 30%
    }

    function test_SetAPY_RevertNotOperator() public {
        vm.prank(user1);
        vm.expectRevert();
        farm.setAPY(3000);
    }

    // ==================== Lock Period Configuration Tests ====================

    function test_BatchSetLockPeriodMultipliers() public {
        uint256[] memory periods = new uint256[](1);
        uint16[] memory multipliers = new uint16[](1);
        periods[0] = 365 days;
        multipliers[0] = 30000; // 3x

        vm.prank(admin);
        farm.batchSetLockPeriodMultipliers(periods, multipliers);

        // Now 365 days should be valid
        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), 500 * 1e6);
        uint256 tokenId = farm.stakePUSD(500 * 1e6, 365 days);
        vm.stopPrank();

        IFarm.StakeRecord memory record = nftManager.getStakeRecord(tokenId);
        assertEq(record.lockPeriod, 365 days);
        assertEq(record.rewardMultiplier, 30000);
    }

    function test_RemoveLockPeriod() public {
        vm.prank(admin);
        farm.removeLockPeriod(180 days);

        // 180 days should no longer be valid
        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), 500 * 1e6);
        vm.expectRevert("Unsupported lock period");
        farm.stakePUSD(500 * 1e6, 180 days);
        vm.stopPrank();
    }

    // ==================== View Function Tests ====================

    function test_GetUserInfo() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        (
            uint256 pusdBalance,
            ,
            ,
            uint256 totalStakedAmount,
            ,
            uint256 activeStakeCount
        ) = farm.getUserInfo(user1);

        assertGt(pusdBalance, 0);
        assertEq(totalStakedAmount, stakeAmount);
        assertEq(activeStakeCount, 1);
    }

    function test_GetSupportedLockPeriodsWithMultipliers() public view {
        (uint256[] memory periods, uint16[] memory multipliers) = farm.getSupportedLockPeriodsWithMultipliers();

        assertEq(periods.length, 3);
        assertEq(periods[0], 30 days);
        assertEq(periods[1], 90 days);
        assertEq(periods[2], 180 days);
        assertEq(multipliers[0], 10000);
        assertEq(multipliers[1], 15000);
        assertEq(multipliers[2], 20000);
    }

    // ==================== Pause Tests ====================

    function test_Pause_BlocksOperations() public {
        vm.prank(admin);
        farm.pause();

        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        vm.expectRevert();
        farm.depositAsset(address(usdt), 1000 * 1e6);
        vm.stopPrank();
    }

    function test_Unpause_AllowsOperations() public {
        vm.prank(admin);
        farm.pause();

        vm.prank(admin);
        farm.unpause();

        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        vm.stopPrank();

        assertGt(pusd.balanceOf(user1), 0);
    }

    // ==================== Fee Configuration Tests ====================

    function test_SetFeeRates() public {
        vm.prank(admin);
        farm.setFeeRates(100, 50, 200); // 1%, 0.5%, 2%

        // Deposit with new fee
        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        vm.stopPrank();

        // Should have 1% less PUSD
        uint256 expectedPUSD = 1000 * 1e6 - (1000 * 1e6 * 100 / 10000);
        assertEq(pusd.balanceOf(user1), expectedPUSD);
    }

    // ==================== NFT Transfer Tests ====================

    function test_NFTTransfer_NewOwnerCanOperate() public {
        uint256 stakeAmount = 500 * 1e6;

        // User1 stakes
        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);

        // Transfer NFT to user2
        nftManager.transferFrom(user1, user2, tokenId);
        vm.stopPrank();

        // Verify ownership
        assertEq(nftManager.ownerOf(tokenId), user2);

        // Warp past lock period
        vm.warp(block.timestamp + 31 days);
        oracle.setLastTokenPriceTimestamp(block.timestamp); // Update oracle timestamp
        vm.prank(address(oracle));
        vault.heartbeat(); // Update vault health check

        // User2 can now unstake
        vm.prank(user2);
        farm.unstakePUSD(tokenId);
    }

    function test_NFTTransfer_OldOwnerCannotOperate() public {
        uint256 stakeAmount = 500 * 1e6;

        // User1 stakes
        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);

        // Transfer NFT to user2
        nftManager.transferFrom(user1, user2, tokenId);
        vm.stopPrank();

        // Warp past lock period
        vm.warp(block.timestamp + 31 days);

        // User1 can no longer unstake
        vm.prank(user1);
        vm.expectRevert("Not stake owner");
        farm.unstakePUSD(tokenId);
    }

    // ==================== Edge Cases ====================

    function test_MultipleStakes_SameUser() public {
        vm.startPrank(user1);
        usdt.approve(address(vault), 5000 * 1e6);
        farm.depositAsset(address(usdt), 5000 * 1e6);

        pusd.approve(address(farm), 3000 * 1e6);
        
        uint256 tokenId1 = farm.stakePUSD(1000 * 1e6, 30 days);
        uint256 tokenId2 = farm.stakePUSD(1000 * 1e6, 90 days);
        uint256 tokenId3 = farm.stakePUSD(1000 * 1e6, 180 days);
        vm.stopPrank();

        // All three should be separate NFTs
        assertEq(nftManager.ownerOf(tokenId1), user1);
        assertEq(nftManager.ownerOf(tokenId2), user1);
        assertEq(nftManager.ownerOf(tokenId3), user1);
        assertTrue(tokenId1 != tokenId2 && tokenId2 != tokenId3);

        // User should have 3 active stakes
        (, , , , , uint256 activeStakeCount) = farm.getUserInfo(user1);
        assertEq(activeStakeCount, 3);
    }

    function test_RewardCalculation_NoRewardsAfterUnlock() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        usdt.approve(address(vault), 1000 * 1e6);
        farm.depositAsset(address(usdt), 1000 * 1e6);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        // Check rewards at unlock
        vm.warp(block.timestamp + 30 days);
        (, uint256 rewardsAtUnlock, , , ) = farm.getStakeDetails(user1, tokenId);

        // Check rewards 30 days after unlock - should be same (no post-expiry yield)
        vm.warp(block.timestamp + 30 days);
        (, uint256 rewardsAfterUnlock, , , ) = farm.getStakeDetails(user1, tokenId);

        assertEq(rewardsAtUnlock, rewardsAfterUnlock);
    }
}
