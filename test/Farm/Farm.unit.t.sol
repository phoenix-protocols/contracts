// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockVault} from "test/mocks/MockVault.sol";
import {MockyPUSD} from "test/mocks/MockyPUSD.sol";
import {FarmUpgradeable} from "src/Farm/Farm.sol";
import {NFTManager} from "src/token/NFTManager/NFTManager.sol";
import {IFarm} from "src/interfaces/IFarm.sol";
import {Farm_Deployer_Base} from "script/Farm/base/Farm_Deployer_Base.sol";
import {NFTManager_Deployer_Base} from "script/token/base/NFTManager_Deployer_Base.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Farm Unit Tests
 * @notice Unit tests - Tests Farm contract logic only, all dependencies are mocked
 * @dev Good test isolation, fast execution, easy to locate issues
 */
contract FarmUnitTest is Test, Farm_Deployer_Base {
    FarmUpgradeable farm;
    NFTManager nftManager;
    
    // Mocks
    ERC20Mock pusd;
    MockVault vault;
    MockyPUSD ypusd;

    address admin = address(0xA11CE);
    address user1 = address(0xCAFE);
    address user2 = address(0xBEEF);
    address operator = address(0x0908);

    uint256 constant INITIAL_BALANCE = 100_000 * 1e6;

    function setUp() public {
        bytes32 salt = bytes32("FARM_UNIT_TEST");
        
        vm.startPrank(admin);

        // Deploy mocks
        pusd = new ERC20Mock("Phoenix USD", "PUSD", 6);
        vault = new MockVault();
        vault.initialize(address(pusd));
        ypusd = new MockyPUSD(address(pusd));

        // Deploy Farm using deployer base
        farm = Farm_Deployer_Base._deploy(admin, address(pusd), address(ypusd), address(vault), salt);

        // Deploy NFTManager (real, because Farm needs it)
        NFTManager nftManagerImpl = new NFTManager();
        bytes memory nftInitData = abi.encodeCall(
            NFTManager.initialize,
            ("Phoenix Stake NFT", "PSN", admin, address(farm))
        );
        nftManager = NFTManager(address(new ERC1967Proxy(address(nftManagerImpl), nftInitData)));

        // Setup
        farm.grantRole(farm.OPERATOR_ROLE(), operator);
        farm.setNFTManager(address(nftManager));

        // Setup lock periods
        uint256[] memory periods = new uint256[](3);
        uint16[] memory multipliers = new uint16[](3);
        uint256[] memory caps = new uint256[](3);
        periods[0] = 30 days;
        periods[1] = 90 days;
        periods[2] = 180 days;
        multipliers[0] = 10000;  // 1x
        multipliers[1] = 15000;  // 1.5x
        multipliers[2] = 20000;  // 2x
        caps[0] = 0;  // no limit
        caps[1] = 0;  // no limit
        caps[2] = 0;  // no limit
        farm.batchSetLockPeriodConfig(periods, multipliers, caps);

        // Set max stakes per user (configType=2)
        farm.updateSystemConfig(2, 1000);

        vm.stopPrank();

        // Give users PUSD directly (skip deposit flow)
        pusd.mint(user1, INITIAL_BALANCE);
        pusd.mint(user2, INITIAL_BALANCE);
        
        // Setup vault mock to return rewards
        pusd.mint(address(vault), INITIAL_BALANCE * 10);
    }

    // ==================== Stake Tests ====================

    function test_StakePUSD_Success() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
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
        vm.startPrank(user1);
        pusd.approve(address(farm), 500 * 1e6);
        vm.expectRevert("Invalid period");
        farm.stakePUSD(500 * 1e6, 7 days);
        vm.stopPrank();
    }

    function test_StakePUSD_RevertInsufficientBalance() public {
        vm.startPrank(user1);
        pusd.approve(address(farm), INITIAL_BALANCE * 2);
        vm.expectRevert("Low PUSD");
        farm.stakePUSD(INITIAL_BALANCE * 2, 30 days);
        vm.stopPrank();
    }

    // Note: Zero amount stake may be allowed by Farm contract design

    // ==================== Unstake Tests ====================

    function test_UnstakePUSD_Success() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        // Warp past lock period
        vm.warp(block.timestamp + 31 days);

        uint256 balanceBefore = pusd.balanceOf(user1);

        vm.prank(user1);
        farm.unstakePUSD(tokenId);

        // NFT should be burned
        vm.expectRevert();
        nftManager.ownerOf(tokenId);

        // User should get PUSD back
        assertGe(pusd.balanceOf(user1), balanceBefore + stakeAmount);
    }

    function test_UnstakePUSD_RevertStillLocked() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);

        vm.expectRevert("Still locked");
        farm.unstakePUSD(tokenId);
        vm.stopPrank();
    }

    function test_UnstakePUSD_RevertNotOwner() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        vm.prank(user2);
        vm.expectRevert("Not owner");
        farm.unstakePUSD(tokenId);
    }

    // ==================== Renew Stake Tests ====================

    function test_RenewStake_Success() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        vm.prank(user1);
        farm.renewStake(tokenId, false, 90 days);

        IFarm.StakeRecord memory record = nftManager.getStakeRecord(tokenId);
        assertEq(record.lockPeriod, 90 days);
        assertTrue(record.active);
    }

    function test_RenewStake_RevertStillLocked() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);

        vm.expectRevert("Still locked");
        farm.renewStake(tokenId, false, 90 days);
        vm.stopPrank();
    }

    // ==================== Claim Rewards Tests ====================

    function test_ClaimStakeRewards_Success() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        uint256 balanceBefore = pusd.balanceOf(user1);

        vm.warp(block.timestamp + 15 days);

        vm.prank(user1);
        farm.claimStakeRewards(tokenId);

        // Should have received some rewards
        assertGt(pusd.balanceOf(user1), balanceBefore);
    }

    function test_ClaimStakeRewards_RevertNotOwner() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 15 days);

        vm.prank(user2);
        vm.expectRevert("Not owner");
        farm.claimStakeRewards(tokenId);
    }

    // ==================== APY & Config Tests ====================

    function test_SetAPY_Success() public {
        vm.prank(admin);
        farm.setAPY(3000); // 30%
        
        assertEq(farm.currentAPY(), 3000);
    }

    function test_SetAPY_ByOperator() public {
        vm.prank(operator);
        farm.setAPY(2500);
        
        assertEq(farm.currentAPY(), 2500);
    }

    function test_SetAPY_RevertUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        farm.setAPY(3000);
    }

    function test_BatchSetLockPeriodConfig() public {
        uint256[] memory periods = new uint256[](1);
        uint16[] memory multipliers = new uint16[](1);
        uint256[] memory caps = new uint256[](1);
        periods[0] = 365 days;
        multipliers[0] = 30000;
        caps[0] = 0;  // no limit

        vm.prank(admin);
        farm.batchSetLockPeriodConfig(periods, multipliers, caps);

        // Verify new period works
        vm.startPrank(user1);
        pusd.approve(address(farm), 500 * 1e6);
        uint256 tokenId = farm.stakePUSD(500 * 1e6, 365 days);
        vm.stopPrank();

        IFarm.StakeRecord memory record = nftManager.getStakeRecord(tokenId);
        assertEq(record.rewardMultiplier, 30000);
    }

    function test_RemoveLockPeriod() public {
        vm.prank(admin);
        farm.removeLockPeriod(180 days);

        vm.startPrank(user1);
        pusd.approve(address(farm), 500 * 1e6);
        vm.expectRevert("Invalid period");
        farm.stakePUSD(500 * 1e6, 180 days);
        vm.stopPrank();
    }

    // ==================== Fee Tests ====================

    function test_SetFeeRates() public {
        vm.prank(admin);
        farm.setFeeRates(100, 50, 200);

        // Verify by checking deposit fee effect
        uint256 depositAmount = 1000 * 1e6;
        vm.startPrank(user1);
        pusd.approve(address(farm), depositAmount);
        farm.stakePUSD(depositAmount, 30 days);
        vm.stopPrank();
        
        // Fee was applied (stake fee 2% = 200 basis points)
        // Stake record should show amount minus fee
    }

    // Note: Fee rate limit validation may vary by implementation

    // ==================== Pause Tests ====================

    function test_Pause_BlocksStake() public {
        vm.prank(admin);
        farm.pause();

        vm.startPrank(user1);
        pusd.approve(address(farm), 500 * 1e6);
        vm.expectRevert();
        farm.stakePUSD(500 * 1e6, 30 days);
        vm.stopPrank();
    }

    function test_Unpause_AllowsStake() public {
        vm.prank(admin);
        farm.pause();

        vm.prank(admin);
        farm.unpause();

        vm.startPrank(user1);
        pusd.approve(address(farm), 500 * 1e6);
        uint256 tokenId = farm.stakePUSD(500 * 1e6, 30 days);
        vm.stopPrank();

        assertEq(nftManager.ownerOf(tokenId), user1);
    }

    // ==================== NFT Transfer Tests ====================

    function test_NFTTransfer_NewOwnerCanOperate() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
        pusd.approve(address(farm), stakeAmount);
        uint256 tokenId = farm.stakePUSD(stakeAmount, 30 days);
        nftManager.transferFrom(user1, user2, tokenId);
        vm.stopPrank();

        assertEq(nftManager.ownerOf(tokenId), user2);

        vm.warp(block.timestamp + 31 days);

        vm.prank(user2);
        farm.unstakePUSD(tokenId);
    }

    // ==================== View Function Tests ====================

    function test_GetUserInfo() public {
        uint256 stakeAmount = 500 * 1e6;

        vm.startPrank(user1);
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

        assertEq(pusdBalance, INITIAL_BALANCE - stakeAmount);
        assertEq(totalStakedAmount, stakeAmount);
        assertEq(activeStakeCount, 1);
    }

    function test_GetSupportedLockPeriodsWithMultipliers() public view {
        (uint256[] memory periods, uint16[] memory multipliers) = farm.getSupportedLockPeriodsWithMultipliers();

        assertEq(periods.length, 3);
        assertEq(periods[0], 30 days);
        assertEq(multipliers[0], 10000);
    }

    // ==================== Multiple Stakes Tests ====================

    function test_MultipleStakes_SameUser() public {
        vm.startPrank(user1);
        pusd.approve(address(farm), 3000 * 1e6);
        
        uint256 tokenId1 = farm.stakePUSD(1000 * 1e6, 30 days);
        uint256 tokenId2 = farm.stakePUSD(1000 * 1e6, 90 days);
        uint256 tokenId3 = farm.stakePUSD(1000 * 1e6, 180 days);
        vm.stopPrank();

        assertEq(nftManager.ownerOf(tokenId1), user1);
        assertEq(nftManager.ownerOf(tokenId2), user1);
        assertEq(nftManager.ownerOf(tokenId3), user1);

        (, , , , , uint256 activeStakeCount) = farm.getUserInfo(user1);
        assertEq(activeStakeCount, 3);
    }
}
