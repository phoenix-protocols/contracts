// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "../token/NFTManager/NFTManager.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IPUSDOracle.sol";

contract FarmLendStorage {
    /// @notice Information about a loan backed by one NFT
    struct Loan {
        bool    active; // Loan status
        address borrower;
        uint256 remainingCollateralAmount; // in PUSD
        address debtToken; // USDT / USDC etc.
        uint256 borrowedAmount; // Principal amount
        uint256 startTime; // Loan start timestamp
        uint256 endTime; // Loan due date
        uint256 lastInterestAccrualTime; // timestamp of last interest accrual
        uint256 accruedInterest;         // interest accrued but not yet settled
        uint256 lastPenaltyAccrualTime;  // timestamp of last penalty accrual
        uint256 accruedPenalty;          // penalty accrued but not yet settled
    }

    /// @notice NFT Manager contract which holds stake records
    NFTManager public nftManager;

    /// @notice Vault that actually holds liquidity and NFTs
    IVault public vault;

    /// @notice PUSD Oracle for price feeds
    IPUSDOracle public pusdOracle;

    /// @notice Allowed debt tokens (e.g. USDT/USDC)
    mapping(address => bool) public allowedDebtTokens;

    /// @notice Loan information by NFT tokenId
    mapping(uint256 => Loan) public loans;

    address public farm; // Farm contract address

    /// @notice Liquidation Collateral Ratio in basis points (e.g. 12500 = 125%)
    uint16 public liquidationRatio = 12500;

    /// @notice Target healthy Collateral Ratio in basis points (e.g. 13000 = 130%)
    uint16 public targetRatio = 13000;

    /// @notice Liquidation bonus in basis points (e.g. 300 = 3%)
    uint16 public liquidationBonus = 300; // 3% bonus to liquidators

    /// @notice Interest Ratio in basis points (e.g. 100 = 1%)
    uint256 public interestRatio = 100; 

    /// @notice Penalty Ratio in basis points (e.g. 100 = 1%)
    uint256 public penaltyRatio = 100; 

    /// @notice Loan duration in seconds, default 30 days
    uint256 public loanDuration = 2592000; // 30 days = 60 * 60 * 24 * 30 = 2592000

    /// @notice Grace period after due date before admin can seize NFT
    uint256 public loanGracePeriod = 7 days; // 7 days grace period after due date

    // PlaceHolder
    uint256[50] private __gap;

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
}
