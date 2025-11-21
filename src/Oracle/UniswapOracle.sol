// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IUniswapPair.sol";
import "../libraries/UQ112x112.sol";
import "./UniswapOracleStorage.sol";
import "../interfaces/IUniswapOracle.sol";

/// @title UniswapOracle
/// @notice A TWAP oracle based on Uniswap Pair (time-weighted average price)
contract UniswapOracle is UniswapOracleStorage {
    using UQ112x112 for uint224;

    constructor(address _pair, uint256 _minTwapPeriod) {
        require(_pair != address(0), "Oracle: ZERO_PAIR");
        require(_minTwapPeriod > 0, "Oracle: ZERO_PERIOD");

        pair = IUniswapPair(_pair);
        MIN_TWAP_PERIOD = _minTwapPeriod;

        address _token0 = pair.token0();
        address _token1 = pair.token1();
        if (_token0 == address(0) || _token1 == address(0)) {
            revert UniswapOracle_InvalidPair();
        }
        token0 = _token0;
        token1 = _token1;
        // Initialize: read the current cumulative prices and timestamp from the pair
        price0CumulativeLast = pair.price0CumulativeLast();
        price1CumulativeLast = pair.price1CumulativeLast();

        (, , uint32 _blockTimestampLast) = pair.getReserves();
        blockTimestampLast = _blockTimestampLast;
    }

    /// @notice Update the TWAP, advancing one time window
    /// @dev Typically called periodically by a keeper, frontend, or other contract, to avoid price manipulation
    /// MUST advance at least MIN_TWAP_PERIOD seconds to succeed
    function update() external {
        // 1. Read the current cumulative prices and timestamp
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = currentCumulativePrices();

        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // solidity 0.8 automatically checks for overflow

        // Require the time interval to be sufficiently long to prevent manipulation of too short windows
        if (timeElapsed < MIN_TWAP_PERIOD) {
            revert UniswapOracle_InsufficientElapsedTime();
        }

        // 2. Calculate the average price over this time window: (Δcumulative price) / (Δtime)
        // priceXAverage is a UQ112x112 fixed point number
        price0Average = uint224((price0Cumulative - price0CumulativeLast) / timeElapsed);
        price1Average = uint224((price1Cumulative - price1CumulativeLast) / timeElapsed);

        // 3. Write back the latest state
        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;
    }

    /// @notice Given tokenIn and amountIn, returns the estimated output amount based on the TWAP
    /// @dev Uses the average price stored after the last update(), not the real-time price
    function consult(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        require(amountIn > 0, "Oracle: ZERO_INPUT");

        if (tokenIn == token0) {
            // price0Average: price of token0 in terms of token1 (UQ112x112)
            // amountOut = price0Average * amountIn (then decode)
            uint256 result = price0Average.mul(amountIn);
            amountOut = uint256(UQ112x112.decode144(uint224(result)));
        } else if (tokenIn == token1) {
            // price1Average: price of token1 in terms of token0 (UQ112x112)
            uint256 result = price1Average.mul(amountIn);
            amountOut = uint256(UQ112x112.decode144(uint224(result)));
        } else {
            revert UniswapOracle_InvalidToken();
        }
    }

    /// @notice Calculate the current cumulative prices (does not modify state), simulating the pair's internal accumulation logic
    function currentCumulativePrices() public view returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) {
        price0Cumulative = pair.price0CumulativeLast();
        price1Cumulative = pair.price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast_) = pair.getReserves();
        blockTimestamp = uint32(block.timestamp);

        // If the block timestamp has advanced, linearly extrapolate the cumulative prices based on the current price
        if (blockTimestamp != blockTimestampLast_) {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast_;

            // Current price = reserve1 / reserve0 (for price0)
            // and reserve0 / reserve1 (for price1), accumulated in UQ112x112 format
            price0Cumulative += uint256(UQ112x112.encode(reserve1).uqdiv(reserve0)) * timeElapsed;
            price1Cumulative += uint256(UQ112x112.encode(reserve0).uqdiv(reserve1)) * timeElapsed;
        }
    }

    /// @notice Returns the TWAP price of `token` in terms of the other token.
    /// For example:
    /// - If token == token0, returns price0Average = token0 priced in token1
    /// - If token == token1, returns price1Average = token1 priced in token0
    function twapPrice1e18(address token) external view returns (uint256 price, uint256 timestamp) {
        uint224 p = (token == token0 ? price0Average : price1Average);
        price = (uint256(p) * 1e18) >> 112;
        timestamp = blockTimestampLast;
    }

    function getMinTWAPPeriod() external view returns (uint256) {
        return MIN_TWAP_PERIOD;
    }
}
