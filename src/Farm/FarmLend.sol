// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../token/NFTManager/NFTManager.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IFarm.sol";
import "./FarmLendStorage.sol";
import "../interfaces/IPUSDOracle.sol";

contract FarmLend is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, FarmLendStorage {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_PRICE_AGE = 3600; // 1 hour

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address _nftManager, address _lendingVault, address _pusdOracle, address _farm) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        require(_nftManager != address(0), "FarmLend: zero NFTManager address");
        require(_lendingVault != address(0), "FarmLend: zero vault address");
        require(_pusdOracle != address(0), "FarmLend: zero PUSD Oracle address");
        nftManager = NFTManager(_nftManager);
        vault = IVault(_lendingVault);
        farm = _farm;
        pusdOracle = IPUSDOracle(_pusdOracle);

        // Set default collateral ratios (must be set here for upgradeable contracts)
        liquidationRatio = 12500; // 125%
        targetCollateralRatio = 13000; // 130%
        liquidationBonus = 300; // 3%
        penaltyRatio = 50; // 0.5% per day (was 4%, too aggressive)
        loanGracePeriod = 7 days;
        penaltyGracePeriod = 3 days;
        
        // Set default loan duration interest ratios
        loanDurationInterestRatios[30 days] = 110; // 1.1% for 30 days
        loanDurationInterestRatios[60 days] = 200; // 2% for 60 days
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
        require(newLiquidationRatio < targetCollateralRatio, "FarmLend: must be < targetCollateralRatio");

        uint16 old = liquidationRatio;
        liquidationRatio = newLiquidationRatio;

        emit LiquidationRatioUpdated(old, newLiquidationRatio);
    }

    /// @notice Update target healthy collateral ratio (e.g. 13000 = 130%)
    function setTargetCollateralRatio(uint16 newTargetCollateralRatio) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTargetCollateralRatio >= liquidationRatio, "FarmLend: must be >= liquidationRatio");
        require(newTargetCollateralRatio >= 10000, "FarmLend: CR below 100%");

        uint16 old = targetCollateralRatio;
        targetCollateralRatio = newTargetCollateralRatio;

        emit TargetCollateralRatioUpdated(old, newTargetCollateralRatio);
    }

    /// @notice Update both CR parameters in a single call (recommended)
    function setCollateralRatios(uint16 newLiquidationRatio, uint16 newTargetCollateralRatio) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newLiquidationRatio >= 10000, "FarmLend: liquidationRatio < 100%");
        require(newTargetCollateralRatio >= 10000, "FarmLend: targetCollateralRatio < 100%");
        require(newLiquidationRatio < newTargetCollateralRatio, "FarmLend: liquidation < target");

        uint16 oldLiq = liquidationRatio;
        uint16 oldTar = targetCollateralRatio;

        liquidationRatio = newLiquidationRatio;
        targetCollateralRatio = newTargetCollateralRatio;

        emit LiquidationRatioUpdated(oldLiq, newLiquidationRatio);
        emit TargetCollateralRatioUpdated(oldTar, newTargetCollateralRatio);
    }

    /// @notice Update penalty ratio in basis points (e.g. 100 = 1%)
    function setPenaltyRatio(uint256 _penaltyRatio) external onlyRole(DEFAULT_ADMIN_ROLE) {
        penaltyRatio = _penaltyRatio;
    }

    /// @notice Set interest ratios for loan durations to make loan durations valid
    function setLoanDurationInterestRatios(uint256 loanDuration, uint256 _loanDurationInterestRatios) external onlyRole(DEFAULT_ADMIN_ROLE) {
        loanDurationInterestRatios[loanDuration] = _loanDurationInterestRatios;
    }

    /// @notice Update loan grace period in seconds
    function setLoanGracePeriod(uint256 _loanGracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        loanGracePeriod = _loanGracePeriod;
    }

    /// @notice Update penalty grace period in seconds
    function setPenaltyGracePeriod(uint256 _penaltyGracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_penaltyGracePeriod <= loanGracePeriod, "FarmLend: penalty grace > loan grace");
        penaltyGracePeriod = _penaltyGracePeriod;
    }

    /// @notice Update liquidation bonus in basis points (e.g. 300 = 3%)
    function setLiquidationBonus(uint16 _liquidationBonus) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_liquidationBonus <= 1000, "FarmLend: bonus too high"); // max 10%
        liquidationBonus = _liquidationBonus;
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

        // 4. Apply liquidation ratio (bps, explicit uint256 cast for consistency)
        //
        //    maxBorrow_18 = collateralTokens_18 * 10000 / liquidationRatio
        uint256 maxBorrow_18 = (collateralTokens_18 * 10000) / uint256(liquidationRatio);

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

    /// @notice Get health factor for a given NFT
    /// @dev healthFactor < 1e18 means the loan is liquidatable
    ///      Uses total debt (principal + interest + penalty) for calculation
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

        // 3. Get total debt (principal + interest + penalty)
        (, , , uint256 totalDebt) = getLoanDebt(tokenId);
        uint256 totalDebt_e18 = totalDebt * (10 ** (18 - decimal));

        // 4. healthFactor18 = collateralTokens_18 * 10000 / (totalDebt * liquidationRatio)
        //    healthFactor < 1e18 means collateral ratio < liquidationRatio, i.e. liquidatable
        healthFactor18 = (collateralTokens_18 * 10000 * 1e18) / (totalDebt_e18 * uint256(liquidationRatio));
    }

    /// @notice Get tokenIds for a given borrower
    function getTokenIdsForDebt(address borrower) external view returns (uint256[] memory) {
        return tokenIdsForDebt[borrower];
    }

    /// @notice Get full loan details for a given NFT
    /// @param tokenId NFT token ID
    /// @return loan The complete Loan struct
    function getLoan(uint256 tokenId) external view returns (Loan memory) {
        return loans[tokenId];
    }

    /// @notice Get all loans for a given borrower with full details
    /// @param borrower Address of the borrower
    /// @return tokenIds Array of NFT token IDs
    /// @return loanDetails Array of Loan structs
    function getLoansForBorrower(address borrower) external view returns (uint256[] memory tokenIds, Loan[] memory loanDetails) {
        tokenIds = tokenIdsForDebt[borrower];
        uint256 len = tokenIds.length;
        loanDetails = new Loan[](len);
        
        for (uint256 i = 0; i < len; i++) {
            loanDetails[i] = loans[tokenIds[i]];
        }
    }

    /// @notice Get all active loans summary for a borrower
    /// @param borrower Address of the borrower
    /// @return tokenIds Array of NFT token IDs with active loans
    /// @return principals Array of principal amounts
    /// @return totalDebts Array of total debts (principal + interest + penalty)
    /// @return healthFactors Array of health factors (1e18 precision)
    function getBorrowerLoansSummary(address borrower) external view returns (
        uint256[] memory tokenIds,
        uint256[] memory principals,
        uint256[] memory totalDebts,
        uint256[] memory healthFactors
    ) {
        uint256[] memory allTokenIds = tokenIdsForDebt[borrower];
        uint256 len = allTokenIds.length;
        
        tokenIds = new uint256[](len);
        principals = new uint256[](len);
        totalDebts = new uint256[](len);
        healthFactors = new uint256[](len);
        
        for (uint256 i = 0; i < len; i++) {
            uint256 tokenId = allTokenIds[i];
            Loan storage loan = loans[tokenId];
            
            tokenIds[i] = tokenId;
            principals[i] = loan.borrowedAmount;
            
            (, , , totalDebts[i]) = getLoanDebt(tokenId);
            
            // Get health factor (returns max uint256 if inactive)
            if (loan.active) {
                (uint256 tokenPrice, ) = pusdOracle.getTokenPUSDPrice(loan.debtToken);
                if (tokenPrice > 0) {
                    uint256 collateralPUSD_18 = loan.remainingCollateralAmount * 1e12;
                    uint256 collateralTokens_18 = (collateralPUSD_18 * 1e18) / tokenPrice;
                    uint256 decimal = IERC20Metadata(loan.debtToken).decimals();
                    uint256 totalDebt_e18 = totalDebts[i] * (10 ** (18 - decimal));
                    if (totalDebt_e18 > 0) {
                        healthFactors[i] = (collateralTokens_18 * 10000 * 1e18) / (totalDebt_e18 * uint256(liquidationRatio));
                    } else {
                        healthFactors[i] = type(uint256).max;
                    }
                }
            } else {
                healthFactors[i] = type(uint256).max;
            }
        }
    }

    /// @notice Get liquidation price for a loan
    /// @dev Returns the debt token price (in PUSD, 1e18 precision) at which the loan becomes liquidatable
    ///      When token price rises above this threshold, loan will be liquidatable
    /// @param tokenId NFT token ID
    /// @return liquidationPrice The price threshold (1e18 precision, PUSD per 1 debt token)
    /// @return currentPrice Current debt token price (1e18 precision)
    /// @return safetyMargin How far current price is from liquidation (percentage, 1e18 = 100%)
    function getLiquidationPrice(uint256 tokenId) external view returns (
        uint256 liquidationPrice,
        uint256 currentPrice,
        uint256 safetyMargin
    ) {
        Loan storage loan = loans[tokenId];
        require(loan.active, "FarmLend: no active loan");

        // Get total debt
        (, , , uint256 totalDebt) = getLoanDebt(tokenId);
        require(totalDebt > 0, "FarmLend: no debt");

        // Get current price
        (currentPrice, ) = pusdOracle.getTokenPUSDPrice(loan.debtToken);
        require(currentPrice > 0, "FarmLend: invalid price");

        // Get collateral and debt decimals
        uint256 collateralPUSD = loan.remainingCollateralAmount; // 6 decimals
        uint8 debtDecimals = IERC20Metadata(loan.debtToken).decimals();

        // Liquidation occurs when:
        //   collateral (in debt token units) <= totalDebt * liquidationRatio / 10000
        //
        // collateral in debt token units = collateralPUSD / tokenPrice
        // So liquidation price = (collateralPUSD * 10000) / (totalDebt * liquidationRatio)
        //
        // Normalize to 1e18:
        //   liquidationPrice = (collateralPUSD * 1e12 * 10000 * 1e18) / (totalDebt * (10^(18-debtDecimals)) * liquidationRatio)
        
        uint256 collateralPUSD_18 = collateralPUSD * 1e12;
        uint256 totalDebt_18 = totalDebt * (10 ** (18 - debtDecimals));

        // liquidationPrice (1e18) = collateral (1e18) * 10000 / (debt (1e18) * liquidationRatio)
        liquidationPrice = (collateralPUSD_18 * 10000 * 1e18) / (totalDebt_18 * uint256(liquidationRatio));

        // Safety margin: how much room before liquidation
        // safetyMargin = (liquidationPrice - currentPrice) / liquidationPrice
        // If currentPrice >= liquidationPrice, margin is 0 (already liquidatable)
        if (currentPrice >= liquidationPrice) {
            safetyMargin = 0;
        } else {
            safetyMargin = ((liquidationPrice - currentPrice) * 1e18) / liquidationPrice;
        }
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
        uint256 interestDelta = (loan.borrowedAmount * interestRatio * timeElapsed) / (10000 * loan.loanDuration);

        return interest + interestDelta;
    }

    /// @notice View current accrued penalty (including from lastPenaltyAccrualTime to now)
    function _currentPenaltyView(Loan storage loan) internal view returns (uint256) {
        if (!loan.active) return 0;

        uint256 penalty = loan.accruedPenalty;

        if (block.timestamp <= loan.endTime + penaltyGracePeriod) {
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

        // 4. Ensure loan duration is valid, by checking if it exists in loanDurationInterestRatios
        require(loanDurationInterestRatios[loanDuration] > 0, "FarmLend: invalid loan duration");

        // 5. Compute max borrowable
        uint256 maxAmount = maxBorrowable(tokenId, debtToken);
        require(amount <= maxAmount, "FarmLend: amount exceeds max borrowable");

        // 6. Transfer lending asset from vault to borrower
        vault.withdrawTo(msg.sender, debtToken, amount);

        // 7. Move NFT to the vault as collateral
        //    User must approve the contract to transfer this NFT
        require(
            nftManager.getApproved(tokenId) == address(this) || nftManager.isApprovedForAll(msg.sender, address(this)),
            "FarmLend: Please approve NFT first"
        );
        nftManager.safeTransferFrom(msg.sender, address(vault), tokenId);

        // 8. Record borrower's nft tokenId
        tokenIdsForDebt[msg.sender].push(tokenId);

        // 9. Record loan information
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
        _repay(tokenId, amount);
    }

    /// @notice Repay full loan
    function repayFull(uint256 tokenId) external nonReentrant {
        (, , , uint256 totalDebt) = getLoanDebt(tokenId);
        require(totalDebt > 0, "FarmLend: no debt");
        _repay(tokenId, totalDebt);
    }

    /// @notice Internal repay logic
    /// @param tokenId NFT token ID
    /// @param amount Amount to repay
    function _repay(uint256 tokenId, uint256 amount) internal {
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

        // Transfer tokens via Vault (user only needs to approve Vault)
        vault.depositFor(msg.sender, debtToken, amount);

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

        // Remove borrower's nft tokenId
        bool success = _removeTokenIdFromDebt(loan.borrower, tokenId);
        require(success, "FarmLend: tokenId of borrower not found");

        emit FullyRepaid(msg.sender, tokenId, debtToken, amount, block.timestamp);
    }

    /// @notice Remove tokenId from borrower's debt list
    function _removeTokenIdFromDebt(address borrower, uint256 tokenId) internal returns (bool) {
        uint256[] storage arr = tokenIdsForDebt[borrower];
        uint256 len = arr.length;

        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == tokenId) {
                uint256 lastIndex = len - 1;
                if (i != lastIndex) {
                    arr[i] = arr[lastIndex];
                }
                arr.pop();
                return true;
            }
        }
        return false;
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

        uint256 interestAccrued = (loan.borrowedAmount * interestRatio * timeElapsed) / (10000 * loan.loanDuration);

        loan.accruedInterest += interestAccrued;
        loan.lastInterestAccrualTime = block.timestamp;
    }

    /// @notice Accrue penalty for a loan (internal use)
    function _accruePenalty(Loan storage loan) internal {
        if (!loan.active) return;

        if (block.timestamp <= loan.endTime + penaltyGracePeriod) {
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

        // 1. Accrue interest and penalty first to get accurate total debt
        _accrueInterest(loan);
        _accruePenalty(loan);

        // 2. Get total debt (principal + interest + penalty)
        uint256 principal = loan.borrowedAmount;
        uint256 interest = loan.accruedInterest;
        uint256 penalty = loan.accruedPenalty;
        uint256 totalDebt = principal + interest + penalty;

        // 3. Check if loan is liquidatable:
        //    maxBorrowable(tokenId) <= totalDebt (not just principal)
        uint256 maxBorrow = maxBorrowable(tokenId, loan.debtToken);
        require(maxBorrow <= totalDebt, "FarmLend: not liquidatable");

        // 4. Read stake/collateral data
        uint256 C = loan.remainingCollateralAmount; // PUSD (6 decimals)
        uint256 B = totalDebt; // total debt in debt tokens (token decimals)

        // 5. Fetch oracle price:
        //    P = PUSD per 1 debtToken (1e18 precision)
        (uint256 tokenPrice, uint256 lastTs) = pusdOracle.getTokenPUSDPrice(loan.debtToken);
        require(tokenPrice > 0 && lastTs != 0, "FarmLend: invalid price");
        require(block.timestamp - lastTs <= MAX_PRICE_AGE, "FarmLend: stale price");

        // 6. Normalize C and B into unified 1e18 precision
        // PUSD is 6 decimals → convert to 1e18
        uint256 C18 = C * 1e12;

        // debtTokens may have varying decimals
        uint8 debtDecimals = IERC20Metadata(loan.debtToken).decimals();
        uint256 B18 = B * (10 ** (18 - debtDecimals));

        // 7. Prepare CR-related ratios (convert bps → 1e18)
        uint256 t = uint256(targetCollateralRatio) * 1e14; // e.g. 13000 bps → 1.3e18
        uint256 bonus = uint256(liquidationBonus) * 1e14; // e.g. 500 bps → 0.05e18

        require(t > 1e18 + bonus, "FarmLend: targetCollateralRatio too low");

        //------------------------------------------------------------
        // 8. Compute liquidation amount x in 18 decimals
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

        // 9. Convert x18 back to debtToken decimals
        uint256 x = x18 / (10 ** (18 - debtDecimals));

        // Liquidator may cap max repayment
        require(x > 0, "FarmLend: repay amount too small");
        require(x <= B, "FarmLend: repay exceeds debt");
        require(x <= maxRepayAmount, "FarmLend: exceeds liquidator's maxRepayAmount");

        // 10. Liquidator pays x debtTokens into Vault
        vault.depositFor(msg.sender, loan.debtToken, x);

        //------------------------------------------------------------
        // 11. Compute how much PUSD to seize from collateral:
        //    rewardPUSD = (1 + bonus) * x * tokenPrice
        //------------------------------------------------------------
        //
        //    (1 + bonus) = (10000 + bonusBps)/10000
        //
        uint256 rewardPUSDRaw = (x * (10000 + uint256(liquidationBonus)) * tokenPrice) / (10000 * 1e18);
        // rewardPUSDRaw uses tokenPrice (1e18) → adjust to PUSD(6)
        uint256 rewardPUSD = (rewardPUSDRaw * 1e6) / (10 ** debtDecimals);
        require(rewardPUSD <= C, "FarmLend: reward exceeds collateral");

        //------------------------------------------------------------
        // 10. Distribute repayment across penalty, interest, principal
        //     Priority: penalty first, then interest, then principal
        //------------------------------------------------------------
        uint256 remaining = x;

        // Pay off penalty first
        if (remaining > 0 && penalty > 0) {
            uint256 penaltyPaid = remaining >= penalty ? penalty : remaining;
            loan.accruedPenalty -= penaltyPaid;
            remaining -= penaltyPaid;
        }

        // Then pay off interest
        if (remaining > 0 && interest > 0) {
            uint256 interestPaid = remaining >= interest ? interest : remaining;
            loan.accruedInterest -= interestPaid;
            remaining -= interestPaid;
        }

        // Finally pay off principal
        if (remaining > 0) {
            loan.borrowedAmount -= remaining;
        }

        // 12. Update collateral
        loan.remainingCollateralAmount = C - rewardPUSD;

        // 13. Check if loan is fully paid off
        if (loan.borrowedAmount == 0 && loan.accruedInterest == 0 && loan.accruedPenalty == 0) {
            loan.active = false;
        }

        // 14. Sync NFT collateral data
        IFarm(farm).updateByFarmLend(tokenId, loan.remainingCollateralAmount);

        // 15. Vault pays PUSD reward to liquidator
        vault.withdrawPUSDTo(msg.sender, rewardPUSD);

        //------------------------------------------------------------
        // 16. Emit event
        //------------------------------------------------------------
        emit Liquidated(tokenId, loan.borrower, msg.sender, loan.debtToken, x, block.timestamp);
    }

    /// @notice Claim remaining collateral after loan is fully liquidated (debt = 0)
    /// @dev When a loan is fully liquidated, the borrower can claim the remaining NFT collateral
    /// @param tokenId NFT token ID
    function claimCollateral(uint256 tokenId) external nonReentrant {
        Loan storage loan = loans[tokenId];
        
        // Loan must be inactive (fully liquidated) and caller must be the original borrower
        require(!loan.active, "FarmLend: loan still active");
        require(loan.borrower == msg.sender, "FarmLend: not the borrower");
        require(loan.remainingCollateralAmount > 0, "FarmLend: no collateral to claim");
        
        // Ensure debt is truly zero
        require(loan.borrowedAmount == 0, "FarmLend: principal not zero");
        require(loan.accruedInterest == 0, "FarmLend: interest not zero");
        require(loan.accruedPenalty == 0, "FarmLend: penalty not zero");
        
        uint256 remainingCollateral = loan.remainingCollateralAmount;
        
        // Clear the loan record
        loan.remainingCollateralAmount = 0;
        loan.borrower = address(0);
        
        // Remove from borrower's tokenId list
        _removeTokenIdFromDebt(msg.sender, tokenId);
        
        // Release NFT back to borrower
        vault.releaseNFT(tokenId, msg.sender);
        
        emit CollateralClaimed(tokenId, msg.sender, remainingCollateral);
    }

    // ========== UUPS Upgrade ==========

    /// @notice Authorize upgrade to new implementation
    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
