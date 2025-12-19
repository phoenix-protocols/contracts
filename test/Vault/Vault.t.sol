// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {Vault} from "src/Vault/Vault.sol";
import {VaultStorage} from "src/Vault/VaultStorage.sol";
import {IFarm} from "src/interfaces/IFarm.sol";
import {IPUSDOracle} from "src/interfaces/IPUSDOracle.sol";
import {MockNFTManager} from "test/mocks/MockNFTManager.sol";
import {MockOracle} from "test/mocks/MockOracle.sol";
import {Vault_Deployer_Base, VaultV2} from "script/vault/base/Vault_Deployer_Base.sol";

contract VaultTest is Test, Vault_Deployer_Base {
    Vault vault;
    VaultV2 vaultV2;

    ERC20Mock usdt;
    ERC20Mock usdc;
    ERC20Mock pusd;
    ERC20Mock otherToken;

    MockOracle oracle;
    MockNFTManager nft;

    address admin    = address(0xAAAD);
    address farm     = address(0xFAF1);
    address farmLend = address(0xFAF2);
    address user     = address(0xBEEF);

    address feeTo    = admin;
    address sweepTo  = admin;

    function setUp() public {
        bytes32 salt = vm.envBytes32("SALT");
        
        // Mocks ERC20 tokens
        usdt = new ERC20Mock("USDT", "USDT", 6);
        usdc = new ERC20Mock("USDC", "USDC", 6);
        pusd = new ERC20Mock("PUSD", "PUSD", 6);
        otherToken = new ERC20Mock("OTHER", "OTHER", 6);

        // Mocks contracts
        oracle = new MockOracle();
        nft = new MockNFTManager();

        // Deploy Vault
        vault = _deploy(admin, address(pusd), address(nft), salt);

        // Set admin roles
        vm.prank(admin);
        vault.setFarmAddress(farm);

        vm.prank(admin);
        vault.setFarmLendAddress(farmLend);

        vm.prank(admin);
        vault.setOracleManager(address(oracle));

        vm.prank(admin);
        vault.addAsset(address(usdt), "USDT");

        vm.prank(admin);
        vault.addAsset(address(usdc), "USDC");

        usdt.mint(user, 1_000_000e6);
        usdc.mint(user, 1_000_000e6);
        pusd.mint(address(vault), 1_000_000e6);
    }

    // ---------- Initialization related ----------

    function test_Initialize_RevertsOnInvalidParams() public {
        address impl = address(new Vault());

        vm.startPrank(admin);
        bytes memory initData = abi.encodeCall(
            Vault.initialize,
            (
                address(0),
                address(pusd),
                address(nft)
            )
        );
        vm.expectRevert("Vault: Invalid admin address");
        new ERC1967Proxy(impl, initData);
        vm.stopPrank();

        vm.startPrank(admin);
        initData = abi.encodeCall(
            Vault.initialize,
            (
                admin,
                address(0),
                address(nft)
            )
        );
        vm.expectRevert("Vault: Invalid PUSD address");
        new ERC1967Proxy(impl, initData);
        vm.stopPrank();
    }

    function test_Initialize_OnlyOnce() public {
        vm.expectRevert(); // Initializable: already initialized
        vm.prank(admin);
        vault.initialize(admin, address(pusd), address(nft));
    }

    function test_SetFarmAddress_OnlyAdmin_AndOnlyOnce() public {
        vm.expectRevert(); // AccessControl
        vm.prank(user);
        vault.setFarmAddress(address(123));

        vm.prank(admin);
        vm.expectRevert("Vault: Farm address already set");
        vault.setFarmAddress(address(123));
    }

    function test_SetFarmLendAddress_OnlyAdmin_AndOnlyOnce() public {
        vm.expectRevert();
        vm.prank(user);
        vault.setFarmLendAddress(address(123));

        vm.prank(admin);
        vm.expectRevert("Vault: FarmLend address already set");
        vault.setFarmLendAddress(address(123));
    }

    function test_SetOracleManager_OnlyAdmin_AndOnlyOnce() public {
        vm.startPrank(admin);
        vm.expectRevert("Vault: Oracle Manager already set");
        vault.setOracleManager(address(123));
        vm.stopPrank();
    }

    // ---------- Asset Management add/remove ----------

    function test_AddAsset_OnlyManager_AndNoPUSD() public {
        vm.startPrank(user);
        vm.expectRevert();
        vault.addAsset(address(otherToken), "OTHER");
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert("Vault: PUSD cannot be collateral assetToken");
        vault.addAsset(address(pusd), "PUSD");
        vm.stopPrank();

        vm.startPrank(admin);
        vault.addAsset(address(otherToken), "OTHER");
        vm.stopPrank();

        assertTrue(vault.isValidAsset(address(otherToken)));
        assertEq(vault.getAssetName(address(otherToken)), "OTHER");
    }

    function test_RemoveAsset_BasicFlow_AndSwapPop() public {
        // Give vault some usdt and fee, let the first remove fail
        usdt.mint(address(vault), 100e6);
        vm.startPrank(farm);
        vault.addFee(address(usdt), 10e6);
        vm.stopPrank();

        // Did not claim fees, remove should fail
        vm.startPrank(admin);
        vm.expectRevert("Vault: Asset has unclaimed fees");
        vault.removeAsset(address(usdt));
        vm.stopPrank();

        // Claim fees after accumulatedFees is cleared, then remove
        vm.startPrank(admin);
        vault.claimFees(address(usdt), feeTo);
        vm.stopPrank();

        // still has balance, remove should fail
        vm.startPrank(admin);
        vm.expectRevert("Vault: Asset has balance");
        vault.removeAsset(address(usdt));
        vm.stopPrank();

        // Asset balance set 0
        usdt.burn(address(vault), 90e6);

        vm.startPrank(admin);
        vault.removeAsset(address(usdt));
        vm.stopPrank();

        assertFalse(vault.isValidAsset(address(usdt)));
    }

    // ---------- depositFromFarm helper ----------

    function _depositFromFarm(address asset, uint256 amount, address fromUser) internal {
        vm.prank(fromUser);
        IERC20(asset).approve(address(vault), amount);

        vm.warp(block.timestamp + 10);

        vm.prank(farm);
        vault.depositFor(fromUser, asset, amount);
    }

    // ---------- depositFor test ----------

    function test_DepositFor_Flow_AndRequireChecks() public {
        uint256 amount = 100e6;

        vm.prank(user);
        vm.expectRevert("Vault: Caller is not the farm or farmLend");
        vault.depositFor(user, address(usdt), amount);

        // allowance 不足
        vm.prank(farm);
        vm.expectRevert("Vault: Please approve tokens first");
        vault.depositFor(user, address(usdt), amount);

        vm.prank(user);
        usdt.approve(address(vault), amount);

        // Oracle 超时
        vm.warp(block.timestamp + vault.HEALTH_CHECK_TIMEOUT() + 1);
        vm.prank(farm);
        vm.expectRevert("Vault: Oracle system offline");
        vault.depositFor(user, address(usdt), amount);

        // 正常存款（farm）
        vm.warp(block.timestamp - 100);
        vm.prank(farm);
        vault.depositFor(user, address(usdt), amount);

        assertEq(usdt.balanceOf(address(vault)), amount);

        // farmLend 也可以
        vm.prank(user);
        usdt.approve(address(vault), amount);
        vm.prank(farmLend);
        vault.depositFor(user, address(usdt), amount);

        assertEq(usdt.balanceOf(address(vault)), amount * 2);
    }

    function test_WithdrawTo_Flow() public {
        uint256 amount = 100e6;
        _depositFromFarm(address(usdt), amount, user);

        vm.prank(user);
        vm.expectRevert("Vault: Caller is not the farm or farmLend");
        vault.withdrawTo(user, address(usdt), amount);

        vm.warp(block.timestamp + vault.HEALTH_CHECK_TIMEOUT() + 1);
        vm.prank(farm);
        vm.expectRevert("Vault: Oracle system offline");
        vault.withdrawTo(user, address(usdt), amount);

        vm.warp(block.timestamp - 100);
        vm.prank(farm);
        vault.withdrawTo(user, address(usdt), amount);

        assertEq(usdt.balanceOf(user), 1_000_000e6 - amount + amount);
    }

    function test_WithdrawPUSDTo_OnlyFarm() public {
        uint256 amount = 100e6;

        vm.prank(user);
        vm.expectRevert("Vault: Caller is not the farm");
        vault.withdrawPUSDTo(user, amount);

        vm.warp(block.timestamp + vault.HEALTH_CHECK_TIMEOUT() + 1);
        vm.prank(farm);
        vm.expectRevert("Vault: Oracle system offline");
        vault.withdrawPUSDTo(user, amount);

        vm.warp(block.timestamp - 100);
        vm.prank(farm);
        vault.withdrawPUSDTo(user, amount);

        assertEq(pusd.balanceOf(user), amount);
    }

    // ---------- addFee / claimFees ----------

    function test_AddFee_And_ClaimFees() public {
        uint256 feeAmount = 10e6;

        vm.prank(user);
        vm.expectRevert("Vault: Caller is not the farm");
        vault.addFee(address(usdt), feeAmount);

        vm.prank(farm);
        vm.expectRevert("Vault: Unsupported assetToken");
        vault.addFee(address(otherToken), feeAmount);

        vm.prank(farm);
        vm.expectRevert("Vault: Invalid fee amount");
        vault.addFee(address(usdt), 0);

        vm.prank(farm);
        vault.addFee(address(usdt), feeAmount);

        assertEq(vault.getClaimableFees(address(usdt)), feeAmount);

        vm.prank(user);
        vm.expectRevert();
        vault.claimFees(address(usdt), feeTo);

        vm.prank(admin);
        vm.expectRevert("Vault: Unsupported assetToken");
        vault.claimFees(address(otherToken), feeTo);

        _depositFromFarm(address(usdt), 100e6, user);
        vm.prank(admin);
        vault.claimFees(address(usdt), feeTo);

        vm.prank(admin);
        vm.expectRevert("Vault: No fees to claim");
        vault.claimFees(address(usdt), feeTo);
    }

    // ---------- timelock withdraw ----------

    function test_ProposeWithdrawal_Execute_And_Cancel() public {
        _depositFromFarm(address(usdt), 200e6, user);
        _depositFromFarm(address(usdc), 300e6, user);

        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        assets[0] = address(usdt);
        assets[1] = address(usdc);
        amounts[0] = 50e6;
        amounts[1] = 60e6;

        vm.prank(user);
        vm.expectRevert();
        vault.proposeWithdrawal(user, assets, amounts);

        vm.prank(admin);
        vm.expectRevert("Vault: Cannot withdraw to zero address");
        vault.proposeWithdrawal(address(0), assets, amounts);

        address[] memory emptyAssets = new address[](0);
        uint256[] memory emptyAmounts = new uint256[](0);
        vm.prank(admin);
        vm.expectRevert("Vault: Empty assetTokens array");
        vault.proposeWithdrawal(user, emptyAssets, amounts);

        vm.prank(admin);
        vm.expectRevert("Vault: Empty amounts array");
        vault.proposeWithdrawal(user, assets, emptyAmounts);

        address[] memory onlyOne = new address[](1);
        onlyOne[0] = address(usdt);
        vm.prank(admin);
        vm.expectRevert("Vault: Assets and amounts length mismatch");
        vault.proposeWithdrawal(user, onlyOne, amounts);

        amounts[1] = 0;
        vm.prank(admin);
        vm.expectRevert("Vault: Amount must be greater than 0");
        vault.proposeWithdrawal(user, assets, amounts);
        amounts[1] = 60e6;

        amounts[0] = 1_000_000_000e6;
        vm.prank(admin);
        vm.expectRevert("Vault: Insufficient funds for proposal");
        vault.proposeWithdrawal(user, assets, amounts);
        amounts[0] = 50e6;

        vm.prank(admin);
        vault.proposeWithdrawal(user, assets, amounts);

        vm.prank(admin);
        vm.expectRevert("Vault: Pending withdrawal exists");
        vault.proposeWithdrawal(user, assets, amounts);

        (
            address to,
            address[] memory retAssets,
            string[] memory retNames,
            uint256[] memory retAmounts,
            uint256 unlockTime,
            uint256 remainingTime,
            bool canExecute
        ) = vault.getPendingWithdrawalInfo();

        assertEq(to, user);
        assertEq(retAssets.length, 2);
        assertEq(retAmounts[0], 50e6);
        assertEq(retNames[0], vault.getAssetName(address(usdt)));
        assertFalse(canExecute);
        assertTrue(unlockTime > block.timestamp);
        assertEq(unlockTime - block.timestamp, remainingTime);
        assertTrue(vault.getRemainingWithdrawalTime() > 0);

        vm.prank(admin);
        vm.expectRevert("Vault: Timelock has not expired");
        vault.executeWithdrawal();

        vm.prank(admin);
        vault.cancelWithdrawal();

        (, retAssets, , , unlockTime, ,) = vault.getPendingWithdrawalInfo();
        assertEq(retAssets.length, 0);
        assertEq(unlockTime, 0);

        vm.prank(admin);
        vm.expectRevert("Vault: No pending withdrawal");
        vault.executeWithdrawal();

        vm.prank(admin);
        vault.proposeWithdrawal(user, assets, amounts);

        vm.warp(block.timestamp + vault.TIMELOCK_DELAY() + 1);
        vm.prank(admin);
        vault.executeWithdrawal();

        vm.prank(admin);
        vm.expectRevert("Vault: No pending withdrawal");
        vault.executeWithdrawal();
    }

    // ---------- emergencySweep ----------

    function test_EmergencySweep_OnlyAdmin_AndNotSupported() public {
        otherToken.mint(address(vault), 100e18);

        vm.prank(user);
        vm.expectRevert();
        vault.emergencySweep(address(otherToken), sweepTo, 10e18);

        vm.prank(admin);
        vm.expectRevert("Vault: Use timelock for supported assetToken");
        vault.emergencySweep(address(usdt), sweepTo, 10e18);

        vm.prank(admin);
        vm.expectRevert("Vault: Cannot sweep PUSD");
        vault.emergencySweep(address(pusd), sweepTo, 10e18);

        vm.prank(admin);
        vault.emergencySweep(address(otherToken), sweepTo, 10e18);

        assertEq(otherToken.balanceOf(sweepTo), 10e18);
    }

    /*---------------- heartbeat / isHealthy ----------------*/

    function test_Heartbeat_And_IsHealthy() public {
        vm.prank(user);
        vm.expectRevert("Vault: Only Oracle Manager can send heartbeat");
        vault.heartbeat();

        vm.prank(address(oracle));
        vault.heartbeat();

        assertTrue(vault.isHealthy());

        vm.warp(block.timestamp + vault.HEALTH_CHECK_TIMEOUT() + 1);
        assertFalse(vault.isHealthy());
    }

    /*---------------- NFT related ----------------*/

    function _setNFTRecord(uint256 tokenId, bool active, uint256 startTime, uint256 lockPeriod) internal {
        MockNFTManager m = nft;
        m.setOwner(tokenId, address(vault));

        IFarm.StakeRecord memory r;
        r.amount = 0;
        r.startTime = startTime;
        r.lockPeriod = lockPeriod;
        r.lastClaimTime = startTime;
        r.rewardMultiplier = 0;
        r.active = active;
        r.pendingReward = 0;

        m.setStakeRecord(tokenId, r);
    }

    function test_WithdrawNFT_ByAdmin_WithLockCheck() public {
        uint256 tokenId = 1;
        uint256 lockPeriod = 10 days;

        _setNFTRecord(tokenId, true, block.timestamp, lockPeriod);

        vm.prank(admin);
        vm.expectRevert("Vault: stake is still locked");
        vault.withdrawNFT(tokenId, user);

        vm.warp(block.timestamp + lockPeriod + vault.MAX_DELAY_PERIOD() + 1);

        vm.prank(admin);
        vault.withdrawNFT(tokenId, user);

        assertEq(nft.ownerOf(tokenId), user);
    }

    function test_WithdrawNFT_RevertOnInactive() public {
        uint256 tokenId = 2;
        vm.warp(12345678910);
        _setNFTRecord(tokenId, false, block.timestamp - 100 days, 10 days);

        vm.prank(admin);
        vm.expectRevert("NFTManager: stake already withdrawn");
        vault.withdrawNFT(tokenId, user);
    }

    function test_ReleaseNFT_OnlyFarmLend() public {
        uint256 tokenId = 3;
        vm.warp(12345678910);
        _setNFTRecord(tokenId, true, block.timestamp - 100 days, 10 days);

        vm.prank(user);
        vm.expectRevert("Not From FarmLend");
        vault.releaseNFT(tokenId, user);

        vm.prank(farmLend);
        vault.releaseNFT(tokenId, user);
        assertEq(nft.ownerOf(tokenId), user);
    }

    function test_WithdrawNFTByFarm_OnlyFarm() public {
        uint256 tokenId = 4;
        uint256 lockPeriod = 5 days;

        vm.warp(12345678910);

        _setNFTRecord(tokenId, true, block.timestamp - 100 days, lockPeriod);

        vm.prank(user);
        vm.expectRevert("Not From Farm");
        vault.withdrawNFTByFarm(tokenId, user);

        // 用一个比较早的 startTime 来保证还没到期
        _setNFTRecord(tokenId, true, block.timestamp, lockPeriod);
        vm.prank(farm);
        vm.expectRevert("Vault: stake is still locked");
        vault.withdrawNFTByFarm(tokenId, user);

        vm.warp(block.timestamp + lockPeriod + vault.MAX_DELAY_PERIOD() + 1);
        vm.prank(farm);
        vault.withdrawNFTByFarm(tokenId, user);
        assertEq(nft.ownerOf(tokenId), user);
    }

    // ---------- pause / unpause ----------

    function test_Pause_Unpause() public {
        uint256 amount = 100e6;
        vm.prank(user);
        usdt.approve(address(vault), amount);

        vm.prank(user);
        vm.expectRevert();
        vault.pause();

        vm.prank(admin);
        vault.pause();

        vm.prank(farm);
        vm.expectRevert();
        vault.depositFor(user, address(usdt), amount);

        vm.prank(admin);
        vault.unpause();

        vm.prank(farm);
        vault.depositFor(user, address(usdt), amount);
    }

    // ---------- TVL / price query ----------

    function test_GetTVL_WithOracleOk_AndOracleRevert_Fallback() public {
        uint256 amount = 123e6;
        _depositFromFarm(address(usdt), amount, user);

        oracle.setTokenUSDPrice(address(usdt), 2e18);
        (uint256 tvl, uint256 marketValue) = vault.getTVL(address(usdt));
        assertEq(tvl, amount);
        assertEq(marketValue, amount * 2e18 / 1e6);

        oracle.setReverts(true, false, false);
        (tvl, marketValue) = vault.getTVL(address(usdt));
        assertEq(marketValue, tvl);
    }

    function test_GetTVL_WithoutOracle() public {
        Vault newVault = _deploy(admin, address(pusd), address(nft), bytes32(0));

        vm.startPrank(admin);
        newVault.setFarmAddress(farm);
        newVault.addAsset(address(usdt), "USDT");
        vm.stopPrank();

        usdt.mint(user, 100e6);

        vm.startPrank(user);
        usdt.approve(address(newVault), 100e6);
        vm.stopPrank();

        vm.startPrank(farm);
        newVault.depositFor(user, address(usdt), 100e6);
        vm.stopPrank();

        (uint256 tvl, uint256 mv) = newVault.getTVL(address(usdt));
        assertEq(mv, tvl);
    }

    function test_GetTotalTVL() public {
        _depositFromFarm(address(usdt), 100e6, user);
        _depositFromFarm(address(usdc), 200e6, user);

        oracle.setTokenUSDPrice(address(usdt), 1e18);
        oracle.setTokenUSDPrice(address(usdc), 2e18);

        uint256 total = vault.getTotalTVL();
        uint256 expected =
            (100e6 * 1e18 / 1e6) +
            (200e6 * 2e18 / 1e6);
        assertEq(total, expected);
    }

    function test_GetPUSDMarketCap_WithAndWithoutOracle() public {
        oracle.setPUSDUSDPrice(2e18);
        uint256 cap = vault.getPUSDMarketCap();
        uint256 expected = pusd.totalSupply() * 2e18 / 1e18;
        assertEq(cap, expected);

        oracle.setReverts(false, false, true);
        cap = vault.getPUSDMarketCap();
        assertEq(cap, pusd.totalSupply());
    }

    function test_GetTokenPUSDValue_And_GetPUSDAssetValue() public {
        _depositFromFarm(address(usdt), 100e6, user);
        oracle.setTokenPUSDPrice(address(usdt), 2e18);

        (uint256 pusdAmount, uint256 ts) = vault.getTokenPUSDValue(address(usdt), 100e6);
        assertEq(ts, oracle.lastTokenPriceTimestamp());
        uint8 decimals = usdt.decimals();
        uint256 expected = (100e6 * 2e18) / (10 ** (decimals + 12));
        assertEq(pusdAmount, expected);

        (uint256 assetAmount, uint256 ts2) = vault.getPUSDAssetValue(address(usdt), pusdAmount);
        assertEq(ts2, oracle.lastTokenPriceTimestamp());
        assertEq(assetAmount, 100e6);

        vm.expectRevert("Vault: Unsupported assetToken");
        vault.getTokenPUSDValue(address(otherToken), 1);

        vm.expectRevert("Vault: Unsupported assetToken");
        vault.getPUSDAssetValue(address(otherToken), 1);

        // amount = 0 is allowed, should return (0, timestamp)
        (uint256 zeroAmount, uint256 zeroTs) = vault.getTokenPUSDValue(address(usdt), 0);
        assertEq(zeroAmount, 0);
        assertEq(zeroTs, oracle.lastTokenPriceTimestamp());

        // New Vault that did not set OracleManager
        vm.startPrank(admin);
        Vault newVault = _deploy(admin, address(pusd), address(nft), bytes32(0));
        newVault.addAsset(address(usdt), "USDT");
        vm.stopPrank();

        vm.expectRevert("Vault: Oracle not set");
        newVault.getTokenPUSDValue(address(usdt), 1);

        vm.expectRevert("Vault: Oracle not set");
        newVault.getPUSDAssetValue(address(usdt), 1);

        oracle.setTokenPUSDPrice(address(usdt), 0);
        vm.expectRevert("Vault: Invalid token price");
        vault.getTokenPUSDValue(address(usdt), 1);

        vm.expectRevert("Vault: Invalid token price");
        vault.getPUSDAssetValue(address(usdt), 1);
    }

    function test_GetFormattedTVL_And_BasicGetters() public {
        _depositFromFarm(address(usdt), 123e6, user);
        oracle.setTokenUSDPrice(address(usdt), 1e18);

        (uint256 tokenAmt, uint256 usdAmt, uint8 decs, string memory sym) =
            vault.getFormattedTVL(address(usdt));

        assertEq(tokenAmt, 123e6);
        assertEq(decs, usdt.decimals());
        assertEq(sym, usdt.symbol());
        assertGt(usdAmt, 0);

        assertTrue(vault.isValidAsset(address(usdt)));

        address[] memory assets = vault.getSupportedAssets();
        assertGt(assets.length, 0);

        assertEq(vault.getAssetName(address(usdt)), usdt.name());
        assertEq(vault.getAssetSymbol(address(usdt)), usdt.symbol());
        assertEq(vault.getTokenDecimals(address(usdt)), usdt.decimals());
    }

    function test_GetRemainingWithdrawalTime_NoPending() public {
        assertEq(vault.getRemainingWithdrawalTime(), 0);

        (
            address to,
            address[] memory assetTokens,
            ,
            ,
            uint256 unlockTime,
            uint256 remainingTime,
            bool canExecute
        ) = vault.getPendingWithdrawalInfo();

        assertEq(to, address(0));
        assertEq(assetTokens.length, 0);
        assertEq(unlockTime, 0);
        assertEq(remainingTime, 0);
        assertFalse(canExecute);
    }

    // ---------- Admin Management: grant/revoke/transfer ----------

    function test_GrantRole_RevokeRole_OverrideForAdmin() public {
        bytes32 ADMIN_ROLE = vault.DEFAULT_ADMIN_ROLE();

        vm.prank(admin);
        vm.expectRevert("Vault: Use transferAdmin() instead");
        vault.grantRole(ADMIN_ROLE, user);

        vm.prank(admin);
        vm.expectRevert("Vault: Use transferAdmin() instead");
        vault.revokeRole(ADMIN_ROLE, admin);
    }

    function test_TransferAdmin() public {
        bytes32 ADMIN_ROLE = vault.DEFAULT_ADMIN_ROLE();

        assertEq(vault.getCurrentAdmin(), admin);
        assertTrue(vault.hasRole(ADMIN_ROLE, admin));

        vm.prank(user);
        vm.expectRevert();
        vault.transferAdmin(user);

        vm.prank(admin);
        vm.expectRevert("Vault: Invalid admin address");
        vault.transferAdmin(address(0));

        vm.prank(admin);
        vm.expectRevert("Vault: Already the admin");
        vault.transferAdmin(admin);

        vm.prank(admin);
        vault.transferAdmin(user);

        assertEq(vault.getCurrentAdmin(), user);
        assertTrue(vault.hasRole(ADMIN_ROLE, user));
        assertFalse(vault.hasRole(ADMIN_ROLE, admin));
    }

    // ---------- onERC721Received ----------

    function test_OnERC721Received_ReturnsSelector() public {
        bytes4 ret = vault.onERC721Received(address(this), user, 1, "");
        assertEq(ret, vault.onERC721Received.selector);
    }

    // ---------- Upgrade ----------

    function test_UUPSUpgradeAndNewLogic() public {
        // 1. Only admin can upgradeToAndCall
        vm.startPrank(admin);
        vaultV2 = _upgrade(address(vault), "");
        vm.stopPrank();

        // 2. Old data should be preserved
        vm.prank(admin);
        vaultV2.setVersion(2);
        assertEq(vaultV2.version(), 2);
    }

    function test_UpgradeOnlyAdmin() public {
        // Non admin should be rejected by _authorizeUpgrade
        VaultV2 implV2 = new VaultV2();

        vm.prank(user);
        vm.expectRevert();
        vault.upgradeToAndCall(address(implV2), "");
    }

    // ========== REWARD RESERVE TESTS ==========

    function test_AddRewardReserve_Success() public {
        uint256 amount = 1000 * 1e6;
        
        // Mint PUSD to admin
        pusd.mint(admin, amount);
        
        // Approve and add
        vm.startPrank(admin);
        pusd.approve(address(vault), amount);
        vault.addRewardReserve(amount);
        vm.stopPrank();
        
        assertEq(vault.getRewardReserve(), amount);
    }

    function test_AddRewardReserve_OnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        vault.addRewardReserve(100);
    }

    function test_AddRewardReserve_RevertZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert("Vault: Amount must be > 0");
        vault.addRewardReserve(0);
    }

    function test_WithdrawRewardReserve_Success() public {
        uint256 amount = 1000 * 1e6;
        
        // First add rewards
        pusd.mint(admin, amount);
        
        vm.startPrank(admin);
        pusd.approve(address(vault), amount);
        vault.addRewardReserve(amount);
        
        // Now withdraw
        uint256 balBefore = pusd.balanceOf(admin);
        vault.withdrawRewardReserve(admin, amount);
        vm.stopPrank();
        
        assertEq(vault.getRewardReserve(), 0);
        assertEq(pusd.balanceOf(admin) - balBefore, amount);
    }

    function test_WithdrawRewardReserve_OnlyAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        vault.withdrawRewardReserve(user, 100);
    }

    function test_WithdrawRewardReserve_RevertInvalidRecipient() public {
        vm.prank(admin);
        vm.expectRevert("Vault: Invalid recipient");
        vault.withdrawRewardReserve(address(0), 100);
    }

    function test_WithdrawRewardReserve_RevertInvalidAmount() public {
        // Zero amount
        vm.prank(admin);
        vm.expectRevert("Vault: Invalid amount");
        vault.withdrawRewardReserve(admin, 0);
        
        // Amount exceeds reserve
        vm.prank(admin);
        vm.expectRevert("Vault: Invalid amount");
        vault.withdrawRewardReserve(admin, 100);
    }

    function test_DistributeReward_OnlyFarm() public {
        vm.prank(user);
        vm.expectRevert("Vault: Caller is not the farm");
        vault.distributeReward(user, 100);
    }

    function test_DistributeReward_Success() public {
        uint256 amount = 1000 * 1e6;
        
        // Add rewards first
        pusd.mint(admin, amount);
        
        vm.startPrank(admin);
        pusd.approve(address(vault), amount);
        vault.addRewardReserve(amount);
        vm.stopPrank();
        
        // Farm distributes reward
        uint256 balBefore = pusd.balanceOf(user);
        vm.prank(farm);
        bool success = vault.distributeReward(user, 500 * 1e6);
        
        assertTrue(success);
        assertEq(pusd.balanceOf(user) - balBefore, 500 * 1e6);
        assertEq(vault.getRewardReserve(), 500 * 1e6);
    }

    function test_DistributeReward_ZeroAmount() public {
        vm.prank(farm);
        bool success = vault.distributeReward(user, 0);
        assertTrue(success); // Zero amount returns true immediately
    }

    function test_DistributeReward_InsufficientReserve() public {
        // No reserve, try to distribute
        vm.prank(farm);
        bool success = vault.distributeReward(user, 100);
        
        assertFalse(success); // Should return false, not revert
    }
}
