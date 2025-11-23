// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFarmLend {
    /// @notice Information about a loan backed by one NFT
    struct Loan {
        bool active; // Loan status
        address borrower;
        uint256 remainingCollateralAmount; // in PUSD
        address debtToken; // USDT / USDC etc.
        uint256 borrowedAmount; // Principal amount
        uint256 loanDuration; // Loan duration in seconds
        uint256 startTime; // Loan start timestamp
        uint256 endTime; // Loan due date
        uint256 lastInterestAccrualTime; // timestamp of last interest accrual
        uint256 accruedInterest; // interest accrued but not yet settled
        uint256 lastPenaltyAccrualTime; // timestamp of last penalty accrual
        uint256 accruedPenalty; // penalty accrued but not yet settled
    }

    // ---------- Events ----------
    event DebtTokenAllowed(address token, bool allowed);
    event VtlUpdated(uint16 oldVtlBps, uint16 newVtlBps);
    event Borrow(address indexed borrower, uint256 indexed tokenId, address indexed debtToken, uint256 amount);
    event Repay(address indexed borrower, uint256 indexed tokenId, address indexed debtToken, uint256 repaidPrincipal, uint256 repaidInterest, uint256 repaidPenalty, uint256 timestamp);
    event FullyRepaid(address indexed borrower, uint256 indexed tokenId, address indexed debtToken, uint256 repaidAmount, uint256 timestamp);
    event Liquidation(address indexed liquidator, uint256 indexed tokenId, address indexed debtToken, uint256 repaidAmount);
    event LiquidationRatioUpdated(uint16 oldValue, uint16 newValue);
    event TargetRatioUpdated(uint16 oldValue, uint16 newValue);
    event PUSDOracleUpdated(address oldOracle, address newOracle);
    event Liquidated(uint256 indexed tokenId, address indexed borrower, address liquidator, address indexed debtToken, uint256 repaidAmount, uint256 timestamp);

    // -------- View functions --------

    /// @notice Maximum borrowable amount for a given NFT and debt token
    function maxBorrowable(uint256 tokenId, address debtToken) external view returns (uint256);

    /// @notice Check if loan is active for a given NFT
    function isLoanActive(uint256 tokenId) external view returns (bool);

    /// @notice Get current total debt (principal + interest + penalty) for a given NFT
    function getLoanDebt(uint256 tokenId) external view returns (uint256 principal, uint256 interest, uint256 penalty, uint256 total);

    // -------- Admin configuration --------

    /// @notice Configure which tokens can be used as debt assets
    function setAllowedDebtToken(address token, bool allowed) external;

    /// @notice Update PUSD Oracle address
    function setPUSDOracle(address newPUSDOracle) external;

    /// @notice Update liquidation collateral ratio (e.g. 12500 = 125%)
    function setLiquidationRatio(uint16 newLiquidationRatio) external;

    /// @notice Update target healthy collateral ratio (e.g. 13000 = 130%)
    function setTargetRatio(uint16 newTargetRatio) external;

    /// @notice Update both CR parameters in a single call (recommended)
    function setCollateralRatios(uint16 newLiquidationRatio, uint16 newTargetRatio) external;

    /// @notice Update penalty ratio in basis points (e.g. 100 = 1%)
    function setPenaltyRatio(uint256 _penaltyRatio) external;

    /// @notice Update loan duration interest ratios
    function setLoanDurationInterestRatios(uint256 loanDuration, uint256 _loanDurationInterestRatios) external;

    /// @notice Update loan grace period in seconds
    function setLoanGracePeriod(uint256 _loanGracePeriod) external;

    // -------- Core user actions --------

    /// @notice Borrow USDT/USDC based on staked PUSD amount represented by NFT
    function borrowWithNFT(uint256 tokenId, address debtToken, uint256 amount, uint256 loanDuration) external;

    /// @notice Repay loan (full or partial)
    function repay(uint256 tokenId, uint256 amount) external;

    /// @notice Repay full loan
    function repay(uint256 tokenId) external;

    /// @notice Admin seize NFT after loan is overdue beyond grace period
    function seizeOverdueNFT(uint256 tokenId) external;

    /// @notice Liquidate an under-collateralized loan backed by a staking NFT
    function liquidate(uint256 tokenId, uint256 maxRepayAmount) external;
}
