// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

contract UniswapV3OracleStorage {
   IUniswapV3Pool public immutable pool;
    address public immutable token0;
    address public immutable token1;

    /// @notice TWAP interval in seconds (e.g., 600 = 10 minutes)
    uint32 public immutable twapInterval;

    error OracleV3_InvalidPool();
    error OracleV3_InvalidToken();
    error OracleV3_ZeroInterval();
}