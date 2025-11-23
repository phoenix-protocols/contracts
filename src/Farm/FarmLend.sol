// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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

    function initialize(address admin, address _nftManager, address _lendingVault, address _pusdOracle, address _farm) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        __ReentrancyGuard_init();

        require(_nftManager != address(0), "FarmLend: zero NFTManager address");
        require(_lendingVault != address(0), "FarmLend: zero vault address");
        require(_pusdOracle != address(0), "FarmLend: zero PUSD Oracle address");
        nftManager = NFTManager(_nftManager);
        vault = IVault(_lendingVault);
        farm = _farm;
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

    /// @notice Update penalty ratio in basis points (e.g. 100 = 1%)
    function setPenaltyRatio(uint256 _penaltyRatio) external onlyRole(DEFAULT_ADMIN_ROLE) {
        penaltyRatio = _penaltyRatio;
    }

    /// @notice Update loan duration in seconds
    function setLoanDurationInterestRatios(uint256 loanDuration, uint256 _loanDurationInterestRatios) external onlyRole(DEFAULT_ADMIN_ROLE) {
        loanDurationInterestRatios[loanDuration] = _loanDurationInterestRatios;
    }

    /// @notice Update loan grace period in seconds
    function setLoanGracePeriod(uint256 _loanGracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        loanGracePeriod = _loanGracePeriod;
    }

    // ---------- View helpers ----------

    /// @notice Maximum borrowable amount for a given NFT and debt token
    function maxBorrowable(uint256 tokenId, address debtToken) public view returns (uint256) {
        IFarm.StakeRecord memory record = nftManager.getStakeRecord(tokenId);
        require(record.active, "FarmLend: stake not active");

        // 1. Fetch oracle price
        //    tokenPrice = PUSD per 1 token (1e18 precision)
        (uint256 tokenPrice, uint256 lastTs) = pusdOracle.getTokenPUSDPrice(debtToken);
        require(tokenPrice > 0 && lastTs != 0, "FarmLend: invalid debt token price");
        require(block.timestamp - lastTs <= MAX_PRICE_AGE, "FarmLend: stale debt token price");

        // 2. Normalize collateral (PUSD) to 1e18
        //    PUSD uses 6 decimals → scale by 1e12
        uint256 collateralPUSD_18 = record.amount * 1e12;

        // 3. Convert collateral PUSD → token units (still 1e18 precision)
        //
        //    collateralTokens_18 = collateralPUSD_18 / tokenPrice
        uint256 collateralTokens_18 = (collateralPUSD_18 * 1e18) / tokenPrice;

        // 4. Apply liquidation ratio (bps)
        //
        //    maxBorrow_18 = collateralTokens_18 * 10000 / liquidationRatio
        uint256 maxBorrow_18 = (collateralTokens_18 * 10000) / liquidationRatio;

        // 5. Convert from 1e18 decimals → debt token decimals
        uint8 debtDecimals = IERC20Metadata(debtToken).decimals();
        uint256 maxBorrow = maxBorrow_18 / (10 ** (18 - debtDecimals));

        return maxBorrow;
    }

    /// @notice Check if loan is active for a given NFT
    function isLoanActive(uint256 tokenId) public view returns (bool) {
        return loans[tokenId].active;
    }

    /// @notice Get current total debt (principal + interest + penalty) for a given NFT
    function getLoanDebt(uint256 tokenId) public view returns (uint256 principal, uint256 interest, uint256 penalty, uint256 total) {
        Loan storage loan = loans[tokenId];
        if (!loan.active) return (0, 0, 0, 0);

        principal = loan.borrowedAmount;

        interest = _currentInterestView(loan);
        penalty = _currentPenaltyView(loan);

        total = principal + interest + penalty;
    }

    function getHealthFactor(uint256 tokenId) external view returns (uint256 healthFactor18) {
        Loan storage loan = loans[tokenId];
        if (!loan.active) return type(uint256).max;

        // 1. Fetch oracle price
        //    tokenPrice = PUSD per 1 token (1e18 precision)
        (uint256 tokenPrice, uint256 lastTs) = pusdOracle.getTokenPUSDPrice(loan.debtToken);
        require(tokenPrice > 0 && lastTs != 0, "FarmLend: invalid debt token price");
        require(block.timestamp - lastTs <= MAX_PRICE_AGE, "FarmLend: stale debt token price");

        // 2. Compute collateral in debt token units (1e18)
        uint256 collateralPUSD_18 = loan.remainingCollateralAmount * 1e12;
        uint256 collateralTokens_18 = (collateralPUSD_18 * 1e18) / tokenPrice;
        uint256 decimal = IERC20Metadata(loan.debtToken).decimals();
        uint256 borrowedAmount_e18 = loan.borrowedAmount * (10 ** (18 - decimal));

        // 3. healthFactor18 = collateralTokens_18 * liquidationRatio / (totalDebt * 10000)
        healthFactor18 = (collateralTokens_18 * 10000 * 1e18) / (borrowedAmount_e18 * liquidationRatio);
    }

    /// @notice View current accrued interest (including from lastAccrual to now)
    function _currentInterestView(Loan storage loan) internal view returns (uint256) {
        if (!loan.active) return 0;

        uint256 interest = loan.accruedInterest;

        uint256 from = loan.lastInterestAccrualTime;
        if (from == 0) {
            from = loan.startTime;
        }
        if (block.timestamp <= from) {
            return interest;
        }

        uint256 interestRatio = loanDurationInterestRatios[loan.loanDuration];

        uint256 timeElapsed = block.timestamp - from;
        uint256 interestDelta = (loan.borrowedAmount * interestRatio * timeElapsed) / 1e18;

        return interest + interestDelta;
    }

    /// @notice View current accrued penalty (including from lastPenaltyAccrual to now)
    function _currentPenaltyView(Loan storage loan) internal view returns (uint256) {
        if (!loan.active) return 0;

        uint256 penalty = loan.accruedPenalty;

        if (block.timestamp <= loan.endTime + 3 days) {
            return penalty;
        }

        uint256 penaltyStart = loan.endTime;
        uint256 from = loan.lastPenaltyAccrualTime;

        if (from == 0 || from < penaltyStart) {
            from = penaltyStart;
        }
        if (block.timestamp <= from) {
            return penalty;
        }

        uint256 overdueSeconds = block.timestamp - from;
        uint256 overdueDays = (overdueSeconds + 1 days - 1) / 1 days;

        uint256 base = loan.borrowedAmount;

        uint256 delta = (base * penaltyRatio * overdueDays) / 10000;

        return penalty + delta;
    }

    // ---------- Core: borrow using NFT stake as collateral ----------

    /// @notice Borrow USDT/USDC based on staked PUSD amount represented by NFT
    /// @param tokenId NFT token ID used as collateral
    /// @param debtToken Address of the debt token (must be in allowedDebtTokens)
    /// @param amount Amount to borrow (cannot exceed maxBorrowable)
    /// @param loanDuration Loan duration in seconds
    function borrowWithNFT(uint256 tokenId, address debtToken, uint256 amount, uint256 loanDuration) external nonReentrant {
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
        uint256 maxAmount = maxBorrowable(tokenId, debtToken);
        require(amount <= maxAmount, "FarmLend: amount exceeds max borrowable");

        // 5. Transfer lending asset from vault to borrower
        vault.withdrawTo(msg.sender, debtToken, amount);

        // 6. Move NFT to the vault as collateral
        //    User must approve the contract to transfer this NFT
        nftManager.safeTransferFrom(msg.sender, address(vault), tokenId);

        // 7. Record loan information
        loan.active = true;
        loan.borrower = msg.sender;
        loan.remainingCollateralAmount = record.amount;
        loan.debtToken = debtToken;
        loan.borrowedAmount = amount;
        loan.startTime = block.timestamp;
        loan.endTime = block.timestamp + loanDuration;
        loan.loanDuration = loanDuration;
        loan.lastInterestAccrualTime = block.timestamp;
        loan.accruedInterest = 0;
        loan.lastPenaltyAccrualTime = 0; // No penalty yet
        loan.accruedPenalty = 0;

        emit Borrow(msg.sender, tokenId, debtToken, amount);
    }

    // ---------- Repayment flow ----------

    /// @notice Repay loan (full or partial)
    /// @param tokenId NFT token ID
    /// @param amount Amount to repay
    function repay(uint256 tokenId, uint256 amount) external nonReentrant {
        Loan storage loan = loans[tokenId];
        require(loan.active, "FarmLend: no active loan");
        require(amount > 0, "FarmLend: zero amount");

        // Accrue interest and penalty up to now at first
        _accrueInterest(loan);
        _accruePenalty(loan);
        // Overdue check: if current time exceeds loanGracePeriod, user cannot operate
        require(block.timestamp < loan.endTime + loanGracePeriod, "FarmLend: loan overdue, cannot repay");

        // Calculate total debt
        uint256 principal = loan.borrowedAmount;
        uint256 interest = loan.accruedInterest;
        uint256 penalty = loan.accruedPenalty;
        uint256 totalDebt = principal + interest + penalty;

        if (amount > totalDebt) {
            amount = totalDebt;
        }

        address debtToken = loan.debtToken;
        require(IERC20(debtToken).balanceOf(msg.sender) >= amount, "FarmLend: insufficient balance");

        // Transfer tokens
        IERC20(debtToken).transferFrom(msg.sender, address(vault), amount);

        // Repay prior: Penalty -> Interest -> Principal
        uint256 remaining = amount;

        // 1. Repay Penalty
        if (penalty > 0) {
            if (remaining <= penalty) {
                // repay partial penalty
                loan.accruedPenalty -= remaining;
                emit Repay(msg.sender, tokenId, debtToken, 0, 0, remaining, block.timestamp);
                return;
            } else {
                // repay full penalty
                remaining -= penalty;
                loan.accruedPenalty = 0;
            }
        }

        // 2. Repay Interest
        if (interest > 0) {
            if (remaining <= interest) {
                // repay partial interest
                loan.accruedInterest -= remaining;
                emit Repay(msg.sender, tokenId, debtToken, 0, remaining, penalty, block.timestamp);
                return;
            } else {
                // repay full interest
                remaining -= interest;
                loan.accruedInterest = 0;
            }
        }

        // 3. Repay Principal
        if (remaining < principal) {
            loan.borrowedAmount -= remaining;
            emit Repay(msg.sender, tokenId, debtToken, remaining, interest, penalty, block.timestamp);
            return;
        }

        // Full repayment and release NFT to borrower
        loan.borrowedAmount = 0;
        loan.active = false;
        vault.releaseNFT(tokenId, loan.borrower);
        emit FullyRepaid(msg.sender, tokenId, debtToken, amount, block.timestamp);
    }

    /// @notice Repay full loan
    function repay(uint256 tokenId) external {
        (, , , uint256 totalDebt) = getLoanDebt(tokenId);
        this.repay(tokenId, totalDebt);
    }

    /// @notice Accrue interest for a loan (internal use)
    function _accrueInterest(Loan storage loan) internal {
        if (!loan.active) return;

        // Calculate interest since last accrual
        uint256 from = loan.lastInterestAccrualTime;
        if (from == 0) {
            from = loan.startTime;
        }

        uint256 interestRatio = loanDurationInterestRatios[loan.loanDuration];

        if (block.timestamp <= from) return;

        uint256 timeElapsed = block.timestamp - from;

        uint256 interestAccrued = (loan.borrowedAmount * interestRatio * timeElapsed) / (1e4 * 365 days);

        loan.accruedInterest += interestAccrued;
        loan.lastInterestAccrualTime = block.timestamp;
    }

    /// @notice Accrue penalty for a loan (internal use)
    function _accruePenalty(Loan storage loan) internal {
        if (!loan.active) return;

        if (block.timestamp <= loan.endTime + 3 days) {
            return;
        }

        uint256 penaltyStart = loan.endTime;

        // Calculate penalty from max(lastPenaltyAccrualTimestamp, penaltyStart)
        uint256 from = loan.lastPenaltyAccrualTime;
        if (from == 0 || from < penaltyStart) {
            from = penaltyStart;
        }

        if (block.timestamp <= from) {
            return;
        }

        uint256 overdueSeconds = block.timestamp - from;
        uint256 overdueDays = (overdueSeconds + 1 days - 1) / 1 days;

        uint256 base = loan.borrowedAmount; // principal

        uint256 delta = (base * penaltyRatio * overdueDays) / 10000;

        loan.accruedPenalty += delta;
        loan.lastPenaltyAccrualTime = block.timestamp;
    }

    /// @notice Admin seize NFT after loan is overdue beyond grace period
    function seizeOverdueNFT(uint256 tokenId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Loan storage loan = loans[tokenId];
        require(loan.active, "FarmLend: no active loan");
        require(block.timestamp > loan.endTime + loanGracePeriod, "FarmLend: not overdue enough");

        vault.releaseNFT(tokenId, msg.sender);
        loan.active = false;
    }

    /**
     * @notice Liquidate an under-collateralized loan backed by a staking NFT.
     * @dev Liquidation happens when maxBorrowable(tokenId, debtToken) <= borrowedAmount.
     *      Liquidator repays x amount of debtTokens (USDT/USDC/DAI),
     *      receives (1 + bonus) * x worth of collateral in PUSD,
     *      and the system adjusts collateral so that final CR reaches targetCR.
     *
     *      Formula (after aligning decimals):
     *
     *      x18 = (B18 * t - C18/P) / (t - 1 - bonus)
     *
     *      Where:
     *      C18: collateral in 1e18
     *      B18: debt in 1e18
     *      t:   targetCR in 1e18 (e.g., 13000 bps → 1.3e18)
     *      bonus: liquidation bonus in 1e18 (e.g., 500 bps → 0.05e18)
     *
     *      rewardPUSD = (1 + bonus) * x * tokenPrice
     */
    function liquidate(uint256 tokenId, uint256 maxRepayAmount) external nonReentrant {
        Loan storage loan = loans[tokenId];
        require(loan.active, "FarmLend: no active loan");

        // 1. Check if loan is liquidatable:
        //    maxBorrowable(tokenId) <= borrowedAmount
        uint256 maxBorrow = maxBorrowable(tokenId, loan.debtToken);
        require(maxBorrow <= loan.borrowedAmount, "FarmLend: not liquidatable");

        // 2. Read stake/collateral data
        uint256 C = loan.remainingCollateralAmount; // PUSD (6 decimals)
        uint256 B = loan.borrowedAmount; // debt tokens (token decimals)

        // 3. Fetch oracle price:
        //    P = PUSD per 1 debtToken (1e18 precision)
        (uint256 tokenPrice, uint256 lastTs) = pusdOracle.getTokenPUSDPrice(loan.debtToken);
        require(tokenPrice > 0 && lastTs != 0, "FarmLend: invalid price");
        require(block.timestamp - lastTs <= MAX_PRICE_AGE, "FarmLend: stale price");

        // 4. Normalize C and B into unified 1e18 precision
        // PUSD is 6 decimals → convert to 1e18
        uint256 C18 = C * 1e12;

        // debtTokens may have varying decimals
        uint8 debtDecimals = IERC20Metadata(loan.debtToken).decimals();
        uint256 B18 = B * (10 ** (18 - debtDecimals));

        // 5. Prepare CR-related ratios (convert bps → 1e18)
        uint256 t = targetRatio * 1e14; // e.g. 13000 bps → 1.3e18
        uint256 bonus = liquidationBonus * 1e14; // e.g. 500 bps → 0.05e18

        require(t > 1e18 + bonus, "FarmLend: targetCR too low");

        //------------------------------------------------------------
        // 6. Compute liquidation amount x in 18 decimals
        //
        // Formula:
        //   x18 = (B18 * t - C18 / tokenPrice) / (t - 1 - bonus)
        //
        // Derivation (all 1e18 aligned):
        //   collateralTokens = C18 / tokenPrice
        //   x18 = (t * B18 - collateralTokens) / (t - 1 - bonus)
        //------------------------------------------------------------

        // collateral in debtToken units: C / P
        uint256 collateralTokens = (C18 * 1e18) / tokenPrice;

        // tB = B * t
        uint256 tB = (B18 * t) / 1e18;

        // numerator = tB - collateralTokens
        require(tB > collateralTokens, "FarmLend: already >= targetCR");
        uint256 numerator = tB - collateralTokens;

        // denominator = t - 1 - bonus
        uint256 denominator = t - 1e18 - bonus; // > 0 guaranteed by earlier require

        uint256 x18 = (numerator * 1e18) / denominator;
        require(x18 > 0, "FarmLend: x=0");

        // 7. Convert x18 back to debtToken decimals
        uint256 x = x18 / (10 ** (18 - debtDecimals));

        // Liquidator may cap max repayment
        require(x > 0, "FarmLend: repay amount too small");
        require(x <= B, "FarmLend: repay exceeds debt");
        require(x <= maxRepayAmount, "FarmLend: exceeds liquidator's maxRepayAmount");

        // 8. Liquidator pays x debtTokens into Vault
        vault.depositFor(msg.sender, loan.debtToken, x);

        //------------------------------------------------------------
        // 9. Compute how much PUSD to seize from collateral:
        //    rewardPUSD = (1 + bonus) * x * tokenPrice
        //------------------------------------------------------------
        //
        //    (1 + bonus) = (10000 + bonusBps)/10000
        //
        uint256 rewardPUSDRaw = (x * (10000 + liquidationBonus) * tokenPrice) / (10000 * 1e18);
        // rewardPUSDRaw uses tokenPrice (1e18) → adjust to PUSD(6)
        uint256 rewardPUSD = (rewardPUSDRaw * 1e6) / (10 ** debtDecimals);
        require(rewardPUSD <= C, "FarmLend: reward exceeds collateral");

        // 10. Update loan collateral & debt
        _accrueInterest(loan);
        _accruePenalty(loan);
        loan.borrowedAmount = B - x;
        loan.remainingCollateralAmount = C - rewardPUSD;

        if (loan.borrowedAmount == 0) {
            loan.active = false;
        }

        // 11. Sync NFT collateral data
        IFarm(farm).updateByFarmLend(tokenId, loan.remainingCollateralAmount);

        // 12. Vault pays PUSD reward to liquidator
        vault.withdrawPUSDTo(msg.sender, rewardPUSD);

        //------------------------------------------------------------
        // 13. Emit event
        //------------------------------------------------------------
        emit Liquidated(tokenId, loan.borrower, msg.sender, loan.debtToken, x, block.timestamp);
    }
}
