// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniswapOracle {
    // --------- Errors ---------
    error UniswapOracle_InvalidPair();
    error UniswapOracle_InvalidToken();
    error UniswapOracle_InsufficientElapsedTime();

    // --------- Core Methods ---------

    /// @notice Updates the stored TWAP values.
    /// @dev MUST advance at least MIN_TWAP_PERIOD seconds to succeed.
    function update() external;

    /// @notice Returns the estimated output amount based on the stored TWAP.
    /// @param tokenIn Input token address (must be token0 or token1)
    /// @param amountIn Amount of tokenIn
    /// @return amountOut Estimated amount of the other token based on TWAP
    function consult(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);

    /// @notice Returns the TWAP price of `token` in terms of the other token.
    /// @param token Address of token0 or token1
    /// @return price TWAP price (already decoded into uint256)
    /// @return timestamp Timestamp of the last TWAP update
    function twapPrice(address token) external view returns (uint256 price, uint256 timestamp);

    /// @notice Returns the instantaneous cumulative price values (not stored TWAP),
    ///         simulating UniswapV2Pair's internal cumulative logic.
    function currentCumulativePrices() external view returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp);

    // --------- View Methods ---------

    /// @notice Address of the Uniswap Pair
    function pair() external view returns (address);

    /// @notice TWAP minimum period
    function MIN_TWAP_PERIOD() external view returns (uint256);

    /// @notice token0 of the pair
    function token0() external view returns (address);

    /// @notice token1 of the pair
    function token1() external view returns (address);

    /// @notice Last cumulative price0 recorded during update
    function price0CumulativeLast() external view returns (uint256);

    /// @notice Last cumulative price1 recorded during update
    function price1CumulativeLast() external view returns (uint256);

    /// @notice Last block timestamp when TWAP was updated
    function blockTimestampLast() external view returns (uint32);

    /// @notice Stored TWAP average price: price0 = token0 in terms of token1
    function price0Average() external view returns (uint224);

    /// @notice Stored TWAP average price: price1 = token1 in terms of token0
    function price1Average() external view returns (uint224);
}
