// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "../token/NFTManager/NFTManager.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IPUSDOracle.sol";
import "../interfaces/IFarmLend.sol";

abstract contract FarmLendStorage is IFarmLend {
    /// @notice Operations admin role (configuration management)
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice NFT Manager contract which holds stake records
    NFTManager public nftManager;

    /// @notice Vault that actually holds liquidity and NFTs
    IVault public vault;

    /// @notice PUSD Oracle for price feeds
    IPUSDOracle public pusdOracle;

    /// @notice Record NFT tokenIds of borrower on borrow and repay
    mapping(address => uint256[]) public tokenIdsForDebt;

    /// @notice Allowed debt tokens (e.g. USDT/USDC)
    mapping(address => bool) public allowedDebtTokens;

    /// @notice Loan information by NFT tokenId
    mapping(uint256 => Loan) public loans;

    address public farm; // Farm contract address

    /// @notice Liquidation Collateral Ratio in basis points (e.g. 12500 = 125%)
    uint16 public liquidationRatio = 12500;

    /// @notice Target healthy Collateral Ratio in basis points (e.g. 13000 = 130%)
    uint16 public targetCollateralRatio = 13000;

    /// @notice Liquidation bonus in basis points (e.g. 300 = 3%)
    uint16 public liquidationBonus = 300; // 3% bonus to liquidators

    /// @notice Penalty Ratio in basis points per day (e.g. 50 = 0.5% per day)
    uint256 public penaltyRatio = 50;

    /// @notice Annual interest rate in basis points (e.g. 1000 = 10% APR)
    /// @dev Interest is calculated per second using simple interest
    uint256 public annualInterestRate = 1000; // 10% APR default

    /// @notice Grace period after due date before admin can seize NFT
    uint256 public loanGracePeriod = 7 days; // 7 days grace period after due date

    /// @notice Grace period after due date before penalty starts accruing
    uint256 public penaltyGracePeriod = 3 days; // 3 days grace period before penalty

    /// @notice Minimum collateral threshold for slash (dust threshold)
    /// @dev If remaining collateral < this value after liquidation, allow full slash and burn NFT
    uint256 public minCollateralThreshold = 20e6; // 20 PUSD default

    /// @notice Minimum borrow amount in PUSD equivalent (6 decimals)
    /// @dev Prevents dust loans that may become problematic after liquidation
    uint256 public minBorrowAmount = 20e6; // 20 PUSD worth minimum

    // PlaceHolder
    uint256[47] private __gap;
}
