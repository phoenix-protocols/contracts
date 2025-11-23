// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "../token/NFTManager/NFTManager.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IPUSDOracle.sol";
import "../interfaces/IFarmLend.sol";

abstract contract FarmLendStorage is IFarmLend {
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

    /// @notice Penalty Ratio in basis points (e.g. 400 = 4%)
    uint256 public penaltyRatio = 400;

    /// @notice Loan duration in seconds, default 30 days
    mapping(uint256 => uint256) public loanDurationInterestRatios;

    /// @notice Grace period after due date before admin can seize NFT
    uint256 public loanGracePeriod = 7 days; // 7 days grace period after due date

    // PlaceHolder
    uint256[50] private __gap;
}
