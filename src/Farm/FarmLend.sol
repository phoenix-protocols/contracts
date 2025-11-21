// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../token/NFTManager/NFTManager.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IFarm.sol";
import "./FarmLendStorage.sol";
import "../interfaces/IPUSDOracle.sol";

contract FarmLend is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, FarmLendStorage {
    uint256 public constant MAX_PRICE_AGE = 3600; // 1 hour

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address _nftManager, address _lendingVault, address _pusdOracle) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        __ReentrancyGuard_init();

        require(_nftManager != address(0), "FarmLend: zero NFTManager address");
        require(_lendingVault != address(0), "FarmLend: zero vault address");
        require(_pusdOracle != address(0), "FarmLend: zero PUSD Oracle address");
        nftManager = NFTManager(_nftManager);
        vault = IVault(_lendingVault);
        pusdOracle = IPUSDOracle(_pusdOracle);
    }

    // ---------- Admin configuration ----------

    /// @notice Configure which tokens can be used as debt assets
    function setAllowedDebtToken(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowedDebtTokens[token] = allowed;
        emit DebtTokenAllowed(token, allowed);
    }

    /// @notice Update PUSD Oracle address
    function setPUSDOracle(address newPUSDOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPUSDOracle != address(0), "FarmLend: zero PUSD Oracle address");
        IPUSDOracle old = pusdOracle;
        pusdOracle = IPUSDOracle(newPUSDOracle);
        emit PUSDOracleUpdated(address(old), newPUSDOracle);
    }

    /// @notice Update liquidation collateral ratio (e.g. 12500 = 125%)
    function setLiquidationRatio(uint16 newLiquidationRatio) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newLiquidationRatio >= 10000, "FarmLend: CR below 100%");
        require(newLiquidationRatio < targetRatio, "FarmLend: must be < targetRatio");

        uint16 old = liquidationRatio;
        liquidationRatio = newLiquidationRatio;

        emit LiquidationRatioUpdated(old, newLiquidationRatio);
    }

    /// @notice Update target healthy collateral ratio (e.g. 13000 = 130%)
    function setTargetRatio(uint16 newTargetRatio) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTargetRatio >= liquidationRatio, "FarmLend: must be >= liquidationRatio");
        require(newTargetRatio >= 10000, "FarmLend: CR below 100%");

        uint16 old = targetRatio;
        targetRatio = newTargetRatio;

        emit TargetRatioUpdated(old, newTargetRatio);
    }

    /// @notice Update both CR parameters in a single call (recommended)
    function setCollateralRatios(uint16 newLiquidationRatio, uint16 newTargetRatio) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newLiquidationRatio >= 10000, "FarmLend: liquidationRatio < 100%");
        require(newTargetRatio >= 10000, "FarmLend: targetRatio < 100%");
        require(newLiquidationRatio < newTargetRatio, "FarmLend: liquidation < target");

        uint16 oldLiq = liquidationRatio;
        uint16 oldTar = targetRatio;

        liquidationRatio = newLiquidationRatio;
        targetRatio = newTargetRatio;

        emit LiquidationRatioUpdated(oldLiq, newLiquidationRatio);
        emit TargetRatioUpdated(oldTar, newTargetRatio);
    }

    // ---------- View helpers ----------

    /// @notice Maximum borrowable amount for a given NFT and debt token
    function maxBorrowable(uint256 tokenId, address debtToken) public view returns (uint256) {
        IFarm.StakeRecord memory record = nftManager.getStakeRecord(tokenId);
        require(record.active, "FarmLend: stake not active");

        (uint256 tokenPrice, uint256 lastTimestamp) = pusdOracle.getTokenPUSDPrice(debtToken);
        require(tokenPrice > 0 && lastTimestamp != 0, "FarmLend: invalid debt token price");
        require(block.timestamp - lastTimestamp <= MAX_PRICE_AGE, "FarmLend: stale debt token price");

        uint256 base = (record.amount * 1e18) / tokenPrice;
        return (base * 10000) / liquidationRatio;
    }

    /// @notice Check if loan is active for a given NFT
    function isLoanActive(uint256 tokenId) public view returns (bool) {
        return loans[tokenId].active;
    }

    // ---------- Core: borrow using NFT stake as collateral ----------

    /// @notice Borrow USDT/USDC based on staked PUSD amount represented by NFT
    /// @param tokenId NFT token ID used as collateral
    /// @param debtToken Address of the debt token (must be in allowedDebtTokens)
    /// @param amount Amount to borrow (cannot exceed maxBorrowable)
    function borrowWithNFT(uint256 tokenId, address debtToken, uint256 amount) external nonReentrant {
        require(allowedDebtTokens[debtToken], "FarmLend: debt token not allowed");
        require(amount > 0, "FarmLend: zero amount");

        // 1. Ensure caller is the owner of the NFT
        address owner = nftManager.ownerOf(tokenId);
        require(owner == msg.sender, "FarmLend: not NFT owner");

        // 2. Ensure NFT has active stake record
        IFarm.StakeRecord memory record = nftManager.getStakeRecord(tokenId);
        require(record.active, "FarmLend: stake not active");

        // 3. Ensure there is no active loan on this NFT
        Loan storage loan = loans[tokenId];
        require(!loan.active, "FarmLend: loan already active");

        // 4. Compute max borrowable
        uint256 maxAmount = (record.amount * liquidationRatio) / 10000;
        require(amount <= maxAmount, "FarmLend: amount exceeds max borrowable");

        // 5. Transfer lending asset from vault to borrower
        vault.transferLendingAsset(debtToken, msg.sender, amount);

        // 6. Move NFT to the vault as collateral
        //    User must approve the vault to transfer this NFT
        vault.pullAndLockNFT(address(nftManager), tokenId, msg.sender, msg.sender);

        // 7. Record loan information
        loan.borrower = msg.sender;
        loan.debtToken = debtToken;
        loan.borrowedAmount = amount;
        loan.active = true;

        emit Borrow(msg.sender, tokenId, debtToken, amount);
    }

    // ---------- Repayment flow (simple version) ----------

    /// @notice Repay full loan and get NFT back
    /// @dev Simple "all or nothing" repayment flow
    function repay(uint256 tokenId) external nonReentrant {
        Loan storage loan = loans[tokenId];
        require(loan.active, "FarmLend: no active loan");
        require(loan.borrower == msg.sender, "FarmLend: not borrower");

        uint256 debt = loan.borrowedAmount;
        address debtToken = loan.debtToken;

        // 1. Transfer debt token from borrower to vault
        IERC20(debtToken).transferFrom(msg.sender, address(vault), debt);

        // 2. Release NFT back to the borrower
        vault.releaseNFT(address(nftManager), tokenId, msg.sender);

        // 3. Clear loan state
        loan.borrowedAmount = 0;
        loan.active = false;

        emit Repay(msg.sender, tokenId, debtToken, debt);
    }

    // ---------- (Optional) Liquidation hook placeholder ----------

    /// @notice Placeholder for liquidation logic (not implemented yet)
    /// @dev You can later implement price check, overdue logic, etc.
    function liquidate(uint256 tokenId) external nonReentrant {
        Loan storage loan = loans[tokenId];
        require(loan.active, "FarmLend: no active loan");
        // TODO: Add health factor check / overdue time logic

        // For now we just leave a placeholder
        revert("FarmLend: liquidation not implemented");
    }
}
