// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IUniswapPair.sol";
import "../libraries/UniswapV2Library.sol";
import "../libraries/UQ112x112.sol";
import "./UniswapV2SlidingOracleStorage.sol";

/// @title Uniswap V2 Sliding Window TWAP Oracle
/// @notice Computes TWAP using multiple historical observations (sliding window)
contract UniswapV2SlidingOracle is UniswapV2SlidingOracleStorage {
    using UQ112x112 for uint224;

    constructor(address _factory, uint256 _windowSize, uint8 _granularity) {
        if (_granularity <= 1) revert SlidingOracle_InvalidGranularity();
        if ((_windowSize / _granularity) * _granularity != _windowSize) {
            revert SlidingOracle_WindowNotDivisible();
        }

        factory = _factory;
        windowSize = _windowSize;
        granularity = _granularity;
        periodSize = _windowSize / _granularity;
    }

    // ------------------------------------------------------------------------
    // INTERNAL HELPERS
    // ------------------------------------------------------------------------

    /// @notice Compute index for bucket in circular buffer
    function _observationIndexOf(uint256 timestamp) internal view returns (uint8) {
        uint256 epochPeriod = timestamp / periodSize;
        return uint8(epochPeriod % granularity);
    }

    /// @notice Returns the oldest observation in the sliding window
    function _firstObservation(address pair) internal view returns (Observation storage) {
        uint8 idx = _observationIndexOf(block.timestamp);
        uint8 firstIdx = (idx + 1) % granularity;
        return pairObservations[pair][firstIdx];
    }

    // ------------------------------------------------------------------------
    // PUBLIC UPDATE
    // ------------------------------------------------------------------------

    /// @notice Updates current bucket with cumulative prices
    function update(address tokenA, address tokenB) external {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);

        // Ensure bucket array is initialized
        while (pairObservations[pair].length < granularity) {
            pairObservations[pair].push();
        }

        uint8 idx = _observationIndexOf(block.timestamp);
        Observation storage obs = pairObservations[pair][idx];

        uint256 timeElapsed = block.timestamp - obs.timestamp;

        // Only update once per bucket interval
        if (timeElapsed > periodSize) {
            (uint256 p0, uint256 p1, ) = currentCumulativePrices(pair);
            obs.timestamp = block.timestamp;
            obs.price0Cumulative = p0;
            obs.price1Cumulative = p1;
        }
    }

    /// @notice Calculate the current cumulative prices (does not modify state), simulating the pair's internal accumulation logic
    function currentCumulativePrices(address pair) public view returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) {
        IUniswapPair uniswapPair = IUniswapPair(pair);
        price0Cumulative = uniswapPair.price0CumulativeLast();
        price1Cumulative = uniswapPair.price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast_) = uniswapPair.getReserves();
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

    // ------------------------------------------------------------------------
    // PRICE QUERY
    // ------------------------------------------------------------------------

    /// @dev computes amountOut using two cumulative values
    function _computeAmountOut(uint256 priceStart, uint256 priceEnd, uint256 timeElapsed, uint256 amountIn) internal pure returns (uint256 amountOut) {
        uint224 priceAvg = uint224((priceEnd - priceStart) / timeElapsed); // UQ112x112
        amountOut = UQ112x112.decode144(uint224(priceAvg.mul(amountIn)));
    }

    /// @notice Consults sliding window TWAP for tokenIn → tokenOut
    function consult(address tokenIn, uint256 amountIn, address tokenOut) external view returns (uint256 amountOut) {
        address pair = UniswapV2Library.pairFor(factory, tokenIn, tokenOut);
        Observation storage firstObs = _firstObservation(pair);

        uint256 timeElapsed = block.timestamp - firstObs.timestamp;

        if (timeElapsed > windowSize) revert SlidingOracle_MissingHistoricalData();
        if (timeElapsed < windowSize - periodSize * 2) revert SlidingOracle_UnexpectedTimeElapsed();

        (uint256 p0, uint256 p1, ) = currentCumulativePrices(pair);

        (address token0, ) = UniswapV2Library.sortTokens(tokenIn, tokenOut);

        if (token0 == tokenIn) {
            return _computeAmountOut(firstObs.price0Cumulative, p0, timeElapsed, amountIn);
        } else {
            return _computeAmountOut(firstObs.price1Cumulative, p1, timeElapsed, amountIn);
        }
    }

    // returns TWAP price of 1 tokenIn in terms of tokenOut, with 1e18 precision
    function twapPrice1e18(address tokenIn, address tokenOut) external view returns (uint256 price1e18) {
        address pair = UniswapV2Library.pairFor(factory, tokenIn, tokenOut);
        Observation storage firstObservation = _firstObservation(pair);

        uint timeElapsed = block.timestamp - firstObservation.timestamp;
        require(timeElapsed <= windowSize, "SlidingWindowOracle: MISSING_HISTORICAL_OBSERVATION");
        // should never happen.
        require(timeElapsed >= windowSize - periodSize * 2, "SlidingWindowOracle: UNEXPECTED_TIME_ELAPSED");

        // current cumulative prices
        (uint price0Cumulative, uint price1Cumulative, ) = currentCumulativePrices(pair);
        (address token0, ) = UniswapV2Library.sortTokens(tokenIn, tokenOut);

        uint224 priceX112;
        if (token0 == tokenIn) {
            // price of token0 in terms of token1: Δprice0Cumulative / Δtime → UQ112x112
            priceX112 = uint224((price0Cumulative - firstObservation.price0Cumulative) / timeElapsed);
        } else {
            // price of token1 in terms of token0: Δprice1Cumulative / Δtime → UQ112x112
            priceX112 = uint224((price1Cumulative - firstObservation.price1Cumulative) / timeElapsed);
        }

        // priceX112 is UQ112x112 (fixed point with 112 fractional bits)
        // convert to 1e18 precision: price1e18 = priceX112 * 1e18 / 2^112
        price1e18 = priceX112.mul(1e18) >> 112;
    }
}
