// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ReferralRewardManager} from "src/Referral/ReferralRewardManager.sol";
import {ReferralRewardManagerStorage} from "src/Referral/ReferralRewardManagerStorage.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReferralRewardManager_Deployer_Base, ReferralRewardManagerV2} from "script/Referral/base/ReferralRewardManager_Deployer_Base.sol";

contract ReferralRewardManagerTest is Test, ReferralRewardManager_Deployer_Base {
    ReferralRewardManager public manager;
    ERC20Mock public ypusd;

    address admin = address(0xA11CE);
    address rewardManager = address(0xBEEF);
    address pauser = address(0xCAFE);
    address user1 = address(0x1111);
    address user2 = address(0x2222);
    address user3 = address(0x3333);
    address user4 = address(0x4444);

    uint256 constant INITIAL_BALANCE = 1_000_000 * 1e6; // 1M yPUSD
    uint256 constant DEFAULT_MIN_CLAIM = 1 * 1e6; // 1 yPUSD
    uint256 constant DEFAULT_MAX_REWARD = 10000 * 1e6; // 10000 yPUSD
    uint16 constant DEFAULT_MAX_REFERRALS = 1000;

    bytes32 PAUSER_ROLE;
    bytes32 REWARD_MANAGER_ROLE;
    bytes32 FUND_MANAGER_ROLE;
    bytes32 DEFAULT_ADMIN_ROLE;

    // Events
    event RewardAdded(bytes32 indexed recordId, address indexed user, uint256 amount, address manager);
    event RewardReduced(bytes32 indexed recordId, address indexed user, uint256 amount, address manager);
    event RewardSet(bytes32 indexed recordId, address indexed user, uint256 oldAmount, uint256 newAmount);
    event RewardCleared(bytes32 indexed recordId, address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event ReferrerSet(address indexed user, address indexed referrer);
    event RewardPoolFunded(address indexed funder, uint256 amount);
    event ConfigUpdated(uint256 minClaimAmount, uint256 maxRewardPerUser, uint256 maxReferralsPerUser);

    // Helper function to generate recordId
    function _genRecordId(string memory prefix, uint256 index) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prefix, index));
    }

    function _genRecordIds(string memory prefix, uint256 count) internal pure returns (bytes32[] memory) {
        bytes32[] memory ids = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = keccak256(abi.encodePacked(prefix, i));
        }
        return ids;
    }

    function setUp() public {
        // Deploy mock yPUSD token
        ypusd = new ERC20Mock("Yield Phoenix USD", "yPUSD", 6);

        // Deploy using base deployer
        bytes32 salt = bytes32(0);
        manager = _deploy(admin, address(ypusd), salt);

        // Setup roles
        PAUSER_ROLE = manager.PAUSER_ROLE();
        REWARD_MANAGER_ROLE = manager.REWARD_MANAGER_ROLE();
        FUND_MANAGER_ROLE = manager.FUND_MANAGER_ROLE();
        DEFAULT_ADMIN_ROLE = manager.DEFAULT_ADMIN_ROLE();

        // Grant additional roles
        vm.startPrank(admin);
        manager.grantRole(REWARD_MANAGER_ROLE, rewardManager);
        manager.grantRole(PAUSER_ROLE, pauser);
        vm.stopPrank();

        // Mint yPUSD to users and admin for testing
        ypusd.mint(admin, INITIAL_BALANCE);
        ypusd.mint(user1, INITIAL_BALANCE);
        ypusd.mint(user2, INITIAL_BALANCE);
    }

    // ==================== Initialization Tests ====================

    function test_InitializeState() public view {
        assertEq(address(manager.ypusdToken()), address(ypusd));
        assertTrue(manager.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(manager.hasRole(PAUSER_ROLE, admin));
        assertTrue(manager.hasRole(REWARD_MANAGER_ROLE, admin));
        assertTrue(manager.hasRole(FUND_MANAGER_ROLE, admin));
    }

    function test_InitializeConfig() public view {
        (uint256 minClaim, uint256 maxReward, uint256 maxReferrals) = manager.getConfig();
        assertEq(minClaim, DEFAULT_MIN_CLAIM);
        assertEq(maxReward, DEFAULT_MAX_REWARD);
        assertEq(maxReferrals, DEFAULT_MAX_REFERRALS);
    }

    function test_InitializeOnlyOnce() public {
        vm.expectRevert();
        manager.initialize(admin, address(ypusd));
    }

    function test_InitializeRevertInvalidAdmin() public {
        ReferralRewardManager impl = new ReferralRewardManager();
        vm.expectRevert("Invalid admin address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (address(0), address(ypusd)))
        );
    }

    function test_InitializeRevertInvalidToken() public {
        ReferralRewardManager impl = new ReferralRewardManager();
        vm.expectRevert("Invalid yPUSD address");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (admin, address(0)))
        );
    }

    // ==================== SetReferrer Tests ====================

    function test_SetReferrer() public {
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit ReferrerSet(user1, user2);
        manager.setReferrer(user2);

        (address ref, uint256 count, , ) = manager.getUserReferralInfo(user1);
        assertEq(ref, user2);
        
        (, uint256 referrerCount, , ) = manager.getUserReferralInfo(user2);
        assertEq(referrerCount, 1);
    }

    function test_SetReferrer_UpdatesStatistics() public {
        vm.prank(user1);
        manager.setReferrer(user2);

        (uint256 totalUsersCount, uint256 totalReferrersCount, , ) = manager.getSystemStats();
        assertEq(totalUsersCount, 1);
        assertEq(totalReferrersCount, 1);

        // Second user sets same referrer
        vm.prank(user3);
        manager.setReferrer(user2);

        (totalUsersCount, totalReferrersCount, , ) = manager.getSystemStats();
        assertEq(totalUsersCount, 2);
        assertEq(totalReferrersCount, 1); // Still 1 referrer

        // Third user sets different referrer
        vm.prank(user4);
        manager.setReferrer(user1);

        (totalUsersCount, totalReferrersCount, , ) = manager.getSystemStats();
        assertEq(totalUsersCount, 3);
        assertEq(totalReferrersCount, 2); // Now 2 referrers
    }

    function test_SetReferrer_RevertInvalidAddress() public {
        vm.prank(user1);
        vm.expectRevert("Invalid referrer address");
        manager.setReferrer(address(0));
    }

    function test_SetReferrer_RevertSelfReferral() public {
        vm.prank(user1);
        vm.expectRevert("Cannot refer yourself");
        manager.setReferrer(user1);
    }

    function test_SetReferrer_RevertAlreadySet() public {
        vm.startPrank(user1);
        manager.setReferrer(user2);
        
        vm.expectRevert("Referrer already set");
        manager.setReferrer(user3);
        vm.stopPrank();
    }

    function test_SetReferrer_RevertMaxReferrals() public {
        // Update config to allow only 2 referrals
        vm.prank(admin);
        manager.updateConfig(DEFAULT_MIN_CLAIM, DEFAULT_MAX_REWARD, 2);

        // Set 2 referrals
        vm.prank(user1);
        manager.setReferrer(admin);
        vm.prank(user2);
        manager.setReferrer(admin);

        // Third should fail
        vm.prank(user3);
        vm.expectRevert("Referrer has reached max referrals");
        manager.setReferrer(admin);
    }

    function test_SetReferrer_RevertWhenPaused() public {
        vm.prank(pauser);
        manager.pause();

        vm.prank(user1);
        vm.expectRevert();
        manager.setReferrer(user2);
    }

    function test_GetReferrals() public {
        vm.prank(user1);
        manager.setReferrer(admin);
        vm.prank(user2);
        manager.setReferrer(admin);

        address[] memory referrals = manager.getReferrals(admin);
        assertEq(referrals.length, 2);
        assertEq(referrals[0], user1);
        assertEq(referrals[1], user2);
    }

    // ==================== Batch Add Rewards Tests ====================

    function test_BatchAddRewards() public {
        bytes32[] memory recordIds = _genRecordIds("add", 2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 100 * 1e6;
        amounts[1] = 200 * 1e6;

        vm.prank(rewardManager);
        vm.expectEmit(true, true, true, true);
        emit RewardAdded(recordIds[0], user1, 100 * 1e6, rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        assertEq(manager.pendingRewards(user1), 100 * 1e6);
        assertEq(manager.pendingRewards(user2), 200 * 1e6);
        assertEq(manager.totalPendingRewards(), 300 * 1e6);
    }

    function test_BatchAddRewards_RevertDuplicateRecordId() public {
        bytes32[] memory recordIds = _genRecordIds("add-dup", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        // Try to use same recordId again
        vm.prank(rewardManager);
        vm.expectRevert("Record already processed");
        manager.batchAddRewards(recordIds, users, amounts);
    }

    function test_BatchAddRewards_RevertArrayMismatch() public {
        bytes32[] memory recordIds = _genRecordIds("mismatch", 2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        vm.expectRevert("Array length mismatch");
        manager.batchAddRewards(recordIds, users, amounts);
    }

    function test_BatchAddRewards_RevertEmptyArray() public {
        bytes32[] memory recordIds = new bytes32[](0);
        address[] memory users = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(rewardManager);
        vm.expectRevert("Empty arrays");
        manager.batchAddRewards(recordIds, users, amounts);
    }

    function test_BatchAddRewards_RevertInvalidUserAddress() public {
        bytes32[] memory recordIds = _genRecordIds("invalid-user", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = address(0);
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        vm.expectRevert("Invalid user address");
        manager.batchAddRewards(recordIds, users, amounts);
    }

    function test_BatchAddRewards_RevertZeroAmount() public {
        bytes32[] memory recordIds = _genRecordIds("zero-amount", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 0;

        vm.prank(rewardManager);
        vm.expectRevert("Invalid amount");
        manager.batchAddRewards(recordIds, users, amounts);
    }

    function test_BatchAddRewards_RevertExceedsMaxReward() public {
        bytes32[] memory recordIds = _genRecordIds("exceeds-max", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = DEFAULT_MAX_REWARD + 1;

        vm.prank(rewardManager);
        vm.expectRevert("Exceeds max reward per user");
        manager.batchAddRewards(recordIds, users, amounts);
    }

    function test_BatchAddRewards_RevertUnauthorized() public {
        bytes32[] memory recordIds = _genRecordIds("unauth", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(user1);
        vm.expectRevert();
        manager.batchAddRewards(recordIds, users, amounts);
    }

    // ==================== Batch Reduce Rewards Tests ====================

    function test_BatchReduceRewards() public {
        // First add rewards
        bytes32[] memory addRecordIds = _genRecordIds("reduce-add", 2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 100 * 1e6;
        amounts[1] = 200 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(addRecordIds, users, amounts);

        // Then reduce
        bytes32[] memory reduceRecordIds = _genRecordIds("reduce-sub", 2);
        uint256[] memory reduceAmounts = new uint256[](2);
        reduceAmounts[0] = 50 * 1e6;
        reduceAmounts[1] = 100 * 1e6;

        vm.prank(rewardManager);
        vm.expectEmit(true, true, true, true);
        emit RewardReduced(reduceRecordIds[0], user1, 50 * 1e6, rewardManager);
        manager.batchReduceRewards(reduceRecordIds, users, reduceAmounts);

        assertEq(manager.pendingRewards(user1), 50 * 1e6);
        assertEq(manager.pendingRewards(user2), 100 * 1e6);
        assertEq(manager.totalPendingRewards(), 150 * 1e6);
    }

    function test_BatchReduceRewards_RevertArrayMismatch() public {
        bytes32[] memory recordIds = _genRecordIds("reduce-mismatch", 2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](1);

        vm.prank(rewardManager);
        vm.expectRevert("Array length mismatch");
        manager.batchReduceRewards(recordIds, users, amounts);
    }

    function test_BatchReduceRewards_RevertInvalidUserAddress() public {
        bytes32[] memory recordIds = _genRecordIds("reduce-invalid", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = address(0);
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        vm.expectRevert("Invalid user address");
        manager.batchReduceRewards(recordIds, users, amounts);
    }

    function test_BatchReduceRewards_RevertZeroAmount() public {
        bytes32[] memory recordIds = _genRecordIds("reduce-zero", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 0;

        vm.prank(rewardManager);
        vm.expectRevert("Invalid amount");
        manager.batchReduceRewards(recordIds, users, amounts);
    }

    function test_BatchReduceRewards_RevertInsufficientRewards() public {
        bytes32[] memory recordIds = _genRecordIds("reduce-insuff", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        vm.expectRevert("Insufficient pending rewards");
        manager.batchReduceRewards(recordIds, users, amounts);
    }

    function test_BatchReduceRewards_RevertUnauthorized() public {
        bytes32[] memory recordIds = _genRecordIds("reduce-unauth", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(user1);
        vm.expectRevert();
        manager.batchReduceRewards(recordIds, users, amounts);
    }

    // ==================== Batch Set Rewards Tests ====================

    function test_BatchSetRewards() public {
        bytes32[] memory recordIds = _genRecordIds("set", 2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 100 * 1e6;
        amounts[1] = 200 * 1e6;

        vm.prank(rewardManager);
        vm.expectEmit(true, true, false, true);
        emit RewardSet(recordIds[0], user1, 0, 100 * 1e6);
        manager.batchSetRewards(recordIds, users, amounts);

        assertEq(manager.pendingRewards(user1), 100 * 1e6);
        assertEq(manager.pendingRewards(user2), 200 * 1e6);
        assertEq(manager.totalPendingRewards(), 300 * 1e6);
    }

    function test_BatchSetRewards_UpdateExisting() public {
        // First set rewards
        bytes32[] memory recordIds1 = _genRecordIds("set-update-1", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        manager.batchSetRewards(recordIds1, users, amounts);
        assertEq(manager.totalPendingRewards(), 100 * 1e6);

        // Increase reward (need new recordId)
        bytes32[] memory recordIds2 = _genRecordIds("set-update-2", 1);
        amounts[0] = 150 * 1e6;
        vm.prank(rewardManager);
        manager.batchSetRewards(recordIds2, users, amounts);
        assertEq(manager.pendingRewards(user1), 150 * 1e6);
        assertEq(manager.totalPendingRewards(), 150 * 1e6);

        // Decrease reward (need new recordId)
        bytes32[] memory recordIds3 = _genRecordIds("set-update-3", 1);
        amounts[0] = 50 * 1e6;
        vm.prank(rewardManager);
        manager.batchSetRewards(recordIds3, users, amounts);
        assertEq(manager.pendingRewards(user1), 50 * 1e6);
        assertEq(manager.totalPendingRewards(), 50 * 1e6);
    }

    function test_BatchSetRewards_RevertArrayMismatch() public {
        bytes32[] memory recordIds = _genRecordIds("set-mismatch", 2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](1);

        vm.prank(rewardManager);
        vm.expectRevert("Array length mismatch");
        manager.batchSetRewards(recordIds, users, amounts);
    }

    function test_BatchSetRewards_RevertInvalidUserAddress() public {
        bytes32[] memory recordIds = _genRecordIds("set-invalid", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = address(0);
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        vm.expectRevert("Invalid user address");
        manager.batchSetRewards(recordIds, users, amounts);
    }

    function test_BatchSetRewards_RevertExceedsMaxReward() public {
        bytes32[] memory recordIds = _genRecordIds("set-exceeds", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = DEFAULT_MAX_REWARD + 1;

        vm.prank(rewardManager);
        vm.expectRevert("Exceeds max reward per user");
        manager.batchSetRewards(recordIds, users, amounts);
    }

    function test_BatchSetRewards_RevertUnauthorized() public {
        bytes32[] memory recordIds = _genRecordIds("set-unauth", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(user1);
        vm.expectRevert();
        manager.batchSetRewards(recordIds, users, amounts);
    }

    // ==================== Batch Clear Rewards Tests ====================

    function test_BatchClearRewards() public {
        // First add rewards
        bytes32[] memory addRecordIds = _genRecordIds("clear-add", 2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        amounts[0] = 100 * 1e6;
        amounts[1] = 200 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(addRecordIds, users, amounts);

        // Then clear
        bytes32[] memory clearRecordIds = _genRecordIds("clear-sub", 2);
        vm.prank(rewardManager);
        vm.expectEmit(true, true, false, true);
        emit RewardCleared(clearRecordIds[0], user1, 100 * 1e6);
        manager.batchClearRewards(clearRecordIds, users);

        assertEq(manager.pendingRewards(user1), 0);
        assertEq(manager.pendingRewards(user2), 0);
        assertEq(manager.totalPendingRewards(), 0);
    }

    function test_BatchClearRewards_NoOpForZeroRewards() public {
        bytes32[] memory recordIds = _genRecordIds("clear-noop", 1);
        address[] memory users = new address[](1);
        users[0] = user1;

        // Should not revert, just no-op
        vm.prank(rewardManager);
        manager.batchClearRewards(recordIds, users);

        assertEq(manager.pendingRewards(user1), 0);
    }

    function test_BatchClearRewards_RevertInvalidUserAddress() public {
        bytes32[] memory recordIds = _genRecordIds("clear-invalid", 1);
        address[] memory users = new address[](1);
        users[0] = address(0);

        vm.prank(rewardManager);
        vm.expectRevert("Invalid user address");
        manager.batchClearRewards(recordIds, users);
    }

    function test_BatchClearRewards_RevertUnauthorized() public {
        bytes32[] memory recordIds = _genRecordIds("clear-unauth", 1);
        address[] memory users = new address[](1);
        users[0] = user1;

        vm.prank(user1);
        vm.expectRevert();
        manager.batchClearRewards(recordIds, users);
    }

    // ==================== Claim Reward Tests ====================

    function test_ClaimReward() public {
        // Fund the reward pool
        vm.startPrank(admin);
        ypusd.approve(address(manager), 1000 * 1e6);
        manager.fundRewardPool(1000 * 1e6);
        vm.stopPrank();

        // Add rewards to user1
        bytes32[] memory recordIds = _genRecordIds("claim", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        // Claim
        uint256 balanceBefore = ypusd.balanceOf(user1);

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit RewardClaimed(user1, 100 * 1e6);
        manager.claimReward();

        assertEq(ypusd.balanceOf(user1), balanceBefore + 100 * 1e6);
        assertEq(manager.pendingRewards(user1), 0);
        assertEq(manager.totalClaimedRewards(user1), 100 * 1e6);
        assertEq(manager.totalClaimedRewardsGlobal(), 100 * 1e6);
        assertEq(manager.totalPendingRewards(), 0);
    }

    function test_ClaimReward_RevertBelowMinimum() public {
        // Add small reward below minimum
        bytes32[] memory recordIds = _genRecordIds("claim-below-min", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = DEFAULT_MIN_CLAIM - 1;

        vm.prank(rewardManager);
        manager.batchSetRewards(recordIds, users, amounts);

        vm.prank(user1);
        vm.expectRevert("Below minimum claim amount");
        manager.claimReward();
    }

    function test_ClaimReward_RevertInsufficientBalance() public {
        // Add rewards but don't fund the pool
        bytes32[] memory recordIds = _genRecordIds("claim-no-fund", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        vm.prank(user1);
        vm.expectRevert("Insufficient balance in contract. Please contact admin.");
        manager.claimReward();
    }

    function test_ClaimReward_RevertWhenPaused() public {
        // Fund and add rewards
        vm.startPrank(admin);
        ypusd.approve(address(manager), 1000 * 1e6);
        manager.fundRewardPool(1000 * 1e6);
        vm.stopPrank();

        bytes32[] memory recordIds = _genRecordIds("claim-paused", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        // Pause
        vm.prank(pauser);
        manager.pause();

        vm.prank(user1);
        vm.expectRevert();
        manager.claimReward();
    }

    // ==================== Fund Reward Pool Tests ====================

    function test_FundRewardPool() public {
        vm.startPrank(user1);
        ypusd.approve(address(manager), 500 * 1e6);

        vm.expectEmit(true, false, false, true);
        emit RewardPoolFunded(user1, 500 * 1e6);
        manager.fundRewardPool(500 * 1e6);
        vm.stopPrank();

        assertEq(ypusd.balanceOf(address(manager)), 500 * 1e6);
    }

    function test_FundRewardPool_RevertZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("Invalid amount");
        manager.fundRewardPool(0);
    }

    function test_FundRewardPool_RevertNoApproval() public {
        vm.prank(user1);
        vm.expectRevert();
        manager.fundRewardPool(100 * 1e6);
    }

    // ==================== Withdraw Funds Tests ====================

    function test_WithdrawFunds() public {
        // Fund first
        vm.startPrank(admin);
        ypusd.approve(address(manager), 1000 * 1e6);
        manager.fundRewardPool(1000 * 1e6);

        uint256 balanceBefore = ypusd.balanceOf(admin);
        manager.withdrawFunds(500 * 1e6);
        vm.stopPrank();

        assertEq(ypusd.balanceOf(admin), balanceBefore + 500 * 1e6);
        assertEq(ypusd.balanceOf(address(manager)), 500 * 1e6);
    }

    function test_WithdrawFunds_RevertZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert("Invalid amount");
        manager.withdrawFunds(0);
    }

    function test_WithdrawFunds_RevertInsufficientBalance() public {
        vm.prank(admin);
        vm.expectRevert("Insufficient balance");
        manager.withdrawFunds(100 * 1e6);
    }

    function test_WithdrawFunds_RevertUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        manager.withdrawFunds(100 * 1e6);
    }

    // ==================== Update Config Tests ====================

    function test_UpdateConfig() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit ConfigUpdated(5 * 1e6, 5000 * 1e6, 500);
        manager.updateConfig(5 * 1e6, 5000 * 1e6, 500);

        (uint256 minClaim, uint256 maxReward, uint256 maxReferrals) = manager.getConfig();
        assertEq(minClaim, 5 * 1e6);
        assertEq(maxReward, 5000 * 1e6);
        assertEq(maxReferrals, 500);
    }

    function test_UpdateConfig_RevertInvalidMinClaim() public {
        vm.prank(admin);
        vm.expectRevert("Invalid min claim amount");
        manager.updateConfig(0, DEFAULT_MAX_REWARD, DEFAULT_MAX_REFERRALS);
    }

    function test_UpdateConfig_RevertInvalidMaxReward() public {
        vm.prank(admin);
        vm.expectRevert("Invalid max reward");
        manager.updateConfig(100 * 1e6, 50 * 1e6, DEFAULT_MAX_REFERRALS); // max < min
    }

    function test_UpdateConfig_RevertInvalidMaxReferralsZero() public {
        vm.prank(admin);
        vm.expectRevert("Invalid max referrals");
        manager.updateConfig(DEFAULT_MIN_CLAIM, DEFAULT_MAX_REWARD, 0);
    }

    function test_UpdateConfig_RevertInvalidMaxReferralsOverflow() public {
        vm.prank(admin);
        vm.expectRevert("Invalid max referrals");
        manager.updateConfig(DEFAULT_MIN_CLAIM, DEFAULT_MAX_REWARD, uint256(type(uint16).max) + 1);
    }

    function test_UpdateConfig_RevertUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        manager.updateConfig(5 * 1e6, 5000 * 1e6, 500);
    }

    // ==================== Pause/Unpause Tests ====================

    function test_Pause() public {
        vm.prank(pauser);
        manager.pause();
        assertTrue(manager.paused());
    }

    function test_Unpause() public {
        vm.prank(pauser);
        manager.pause();

        vm.prank(pauser);
        manager.unpause();
        assertFalse(manager.paused());
    }

    function test_Pause_RevertUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        manager.pause();
    }

    function test_Unpause_RevertUnauthorized() public {
        vm.prank(pauser);
        manager.pause();

        vm.prank(user1);
        vm.expectRevert();
        manager.unpause();
    }

    // ==================== Query Functions Tests ====================

    function test_GetUserReferralInfo() public {
        // Setup referral
        vm.prank(user1);
        manager.setReferrer(user2);

        // Add rewards
        bytes32[] memory recordIds = _genRecordIds("info", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        // Fund and claim some
        vm.startPrank(admin);
        ypusd.approve(address(manager), 1000 * 1e6);
        manager.fundRewardPool(1000 * 1e6);
        vm.stopPrank();

        vm.prank(user1);
        manager.claimReward();

        (address ref, uint256 count, uint256 pending, uint256 claimed) = manager.getUserReferralInfo(user1);
        assertEq(ref, user2);
        assertEq(count, 0); // user1 has no referrals
        assertEq(pending, 0); // claimed everything
        assertEq(claimed, 100 * 1e6);

        // Check user2 (the referrer)
        (, uint256 referrerCount, , ) = manager.getUserReferralInfo(user2);
        assertEq(referrerCount, 1);
    }

    function test_GetRewardPoolStatus() public {
        // Fund
        vm.startPrank(admin);
        ypusd.approve(address(manager), 1000 * 1e6);
        manager.fundRewardPool(1000 * 1e6);
        vm.stopPrank();

        // Add pending rewards
        bytes32[] memory recordIds = _genRecordIds("pool-status", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        // Claim
        vm.prank(user1);
        manager.claimReward();

        (address poolAddress, uint256 balance, uint256 totalPending, uint256 totalClaimed) = manager.getRewardPoolStatus();
        assertEq(poolAddress, address(manager));
        assertEq(balance, 900 * 1e6); // 1000 - 100
        assertEq(totalPending, 0);
        assertEq(totalClaimed, 100 * 1e6);
    }

    function test_GetSystemStats() public {
        // Setup referrals
        vm.prank(user1);
        manager.setReferrer(admin);
        vm.prank(user2);
        manager.setReferrer(admin);

        // Fund and claim
        vm.startPrank(admin);
        ypusd.approve(address(manager), 1000 * 1e6);
        manager.fundRewardPool(1000 * 1e6);
        vm.stopPrank();

        bytes32[] memory recordIds = _genRecordIds("sys-stats", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 50 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        vm.prank(user1);
        manager.claimReward();

        (uint256 totalUsersCount, uint256 totalReferrersCount, uint256 totalPending, uint256 totalClaimed) = manager.getSystemStats();
        assertEq(totalUsersCount, 2);
        assertEq(totalReferrersCount, 1);
        assertEq(totalPending, 0);
        assertEq(totalClaimed, 50 * 1e6);
    }

    // ==================== Upgrade Tests ====================

    function test_UpgradeAuthorization() public {
        // Deploy new implementation
        ReferralRewardManager newImpl = new ReferralRewardManager();

        // Non-admin cannot upgrade
        vm.prank(user1);
        vm.expectRevert();
        manager.upgradeToAndCall(address(newImpl), "");

        // Admin can upgrade
        vm.prank(admin);
        manager.upgradeToAndCall(address(newImpl), "");
    }

    // ==================== Integration Tests ====================

    function test_FullReferralFlow() public {
        // 1. User1 sets User2 as referrer
        vm.prank(user1);
        manager.setReferrer(user2);

        // 2. Admin funds the reward pool
        vm.startPrank(admin);
        ypusd.approve(address(manager), 10000 * 1e6);
        manager.fundRewardPool(10000 * 1e6);
        vm.stopPrank();

        // 3. Reward manager adds rewards for referrer (user2)
        bytes32[] memory recordIds = _genRecordIds("full-flow", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user2;
        amounts[0] = 500 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        // 4. User2 claims rewards
        uint256 user2BalanceBefore = ypusd.balanceOf(user2);
        
        vm.prank(user2);
        manager.claimReward();

        // Verify
        assertEq(ypusd.balanceOf(user2), user2BalanceBefore + 500 * 1e6);
        assertEq(manager.totalClaimedRewards(user2), 500 * 1e6);

        // 5. Check system stats
        (uint256 totalUsersCount, uint256 totalReferrersCount, uint256 totalPending, uint256 totalClaimed) = manager.getSystemStats();
        assertEq(totalUsersCount, 1);
        assertEq(totalReferrersCount, 1);
        assertEq(totalPending, 0);
        assertEq(totalClaimed, 500 * 1e6);
    }

    function test_MultipleReferralsAndRewards() public {
        // Setup multiple referrals
        vm.prank(user1);
        manager.setReferrer(admin);
        vm.prank(user2);
        manager.setReferrer(admin);
        vm.prank(user3);
        manager.setReferrer(user1);

        // Fund
        vm.startPrank(admin);
        ypusd.approve(address(manager), 50000 * 1e6);
        manager.fundRewardPool(50000 * 1e6);
        vm.stopPrank();

        // Add rewards to multiple users
        bytes32[] memory recordIds = _genRecordIds("multi", 3);
        address[] memory users = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        users[0] = admin;
        users[1] = user1;
        users[2] = user2;
        amounts[0] = 1000 * 1e6;
        amounts[1] = 500 * 1e6;
        amounts[2] = 250 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        assertEq(manager.totalPendingRewards(), 1750 * 1e6);

        // All users claim
        vm.prank(admin);
        manager.claimReward();
        vm.prank(user1);
        manager.claimReward();
        vm.prank(user2);
        manager.claimReward();

        assertEq(manager.totalPendingRewards(), 0);
        assertEq(manager.totalClaimedRewardsGlobal(), 1750 * 1e6);
    }

    // ==================== Edge Cases ====================

    function test_SetRewardToZero() public {
        // Add reward first
        bytes32[] memory addRecordIds = _genRecordIds("set-zero-add", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(addRecordIds, users, amounts);

        // Set to zero
        bytes32[] memory setRecordIds = _genRecordIds("set-zero-set", 1);
        amounts[0] = 0;
        vm.prank(rewardManager);
        manager.batchSetRewards(setRecordIds, users, amounts);

        assertEq(manager.pendingRewards(user1), 0);
        assertEq(manager.totalPendingRewards(), 0);
    }

    function test_AccumulateRewards() public {
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;

        // Add rewards multiple times (each needs unique recordId)
        bytes32[] memory recordIds1 = _genRecordIds("accum-1", 1);
        amounts[0] = 100 * 1e6;
        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds1, users, amounts);

        bytes32[] memory recordIds2 = _genRecordIds("accum-2", 1);
        amounts[0] = 200 * 1e6;
        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds2, users, amounts);

        assertEq(manager.pendingRewards(user1), 300 * 1e6);
    }

    function test_ClaimTwice() public {
        // Fund
        vm.startPrank(admin);
        ypusd.approve(address(manager), 10000 * 1e6);
        manager.fundRewardPool(10000 * 1e6);
        vm.stopPrank();

        // Add and claim first time
        bytes32[] memory recordIds1 = _genRecordIds("claim-twice-1", 1);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = 100 * 1e6;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds1, users, amounts);

        vm.prank(user1);
        manager.claimReward();
        assertEq(manager.totalClaimedRewards(user1), 100 * 1e6);

        // Add more rewards and claim again (need new recordId)
        bytes32[] memory recordIds2 = _genRecordIds("claim-twice-2", 1);
        amounts[0] = 200 * 1e6;
        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds2, users, amounts);

        vm.prank(user1);
        manager.claimReward();
        assertEq(manager.totalClaimedRewards(user1), 300 * 1e6);
    }

    // ==================== Fuzz Tests ====================

    function testFuzz_AddReward(uint256 amount) public {
        vm.assume(amount > 0 && amount <= DEFAULT_MAX_REWARD);

        bytes32[] memory recordIds = new bytes32[](1);
        recordIds[0] = keccak256(abi.encodePacked("fuzz-add", amount));
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        users[0] = user1;
        amounts[0] = amount;

        vm.prank(rewardManager);
        manager.batchAddRewards(recordIds, users, amounts);

        assertEq(manager.pendingRewards(user1), amount);
    }

    function testFuzz_SetReferrer(address referrerAddr) public {
        vm.assume(referrerAddr != address(0));
        vm.assume(referrerAddr != user1);

        vm.prank(user1);
        manager.setReferrer(referrerAddr);

        (address ref, , , ) = manager.getUserReferralInfo(user1);
        assertEq(ref, referrerAddr);
    }
}
