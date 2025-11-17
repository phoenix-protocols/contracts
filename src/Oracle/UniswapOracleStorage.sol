// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "../interfaces/IUniswapPair.sol";

contract UniswapOracleStorage {
    /// @notice The factory contract that deployed the pair

    /// @notice The observed trading pair
    IUniswapPair public immutable pair;

    /// @notice The two tokens in the trading pair
    address public immutable token0;
    address public immutable token1;

    /// @notice The last recorded cumulative price
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    /// @notice The last recorded timestamp (uint32, consistent with the pair)
    uint32 public blockTimestampLast;

    /// @notice The average price over the past window period (stored as UQ112x112)
    /// price0Average represents: how many token1 for 1 token0
    /// price1Average represents: how many token0 for 1 token1
    uint224 public price0Average;
    
    uint224 public price1Average;

    /// @notice The minimum update interval to prevent manipulation of too short windows (e.g., 10 minutes)
    uint256 public immutable MIN_TWAP_PERIOD;

    error UniswapOracle_InvalidPair();
    error UniswapOracle_InsufficientElapsedTime();
    error UniswapOracle_InvalidToken();
}
