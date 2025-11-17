// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "./UniswapV3OracleStorage.sol";

/// @title UniswapV3Oracle
/// @notice Pure TWAP oracle based on Uniswap V3 pool observation data.
/// @dev One oracle instance corresponds to exactly one Uniswap V3 pool (token0-token1 pair).
contract UniswapV3Oracle is UniswapV3OracleStorage {

    constructor(address _pool, uint32 _twapInterval) {
        if (_pool == address(0)) revert OracleV3_InvalidPool();
        if (_twapInterval == 0) revert OracleV3_ZeroInterval();

        pool = IUniswapV3Pool(_pool);
        twapInterval = _twapInterval;

        address _token0 = pool.token0();
        address _token1 = pool.token1();
        if (_token0 == address(0) || _token1 == address(0)) {
            revert OracleV3_InvalidPool();
        }

        token0 = _token0;
        token1 = _token1;
    }

    /// @notice Internal: returns average tick over the TWAP interval
    function _getTwapTick() internal view returns (int24 avgTick) {
        uint32 interval = twapInterval;

        // Prepare secondsAgos array: [twapInterval, 0]
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = interval;
        secondsAgos[1] = 0;

        // tickCumulatives[0] = cumulative tick at (now - interval)
        // tickCumulatives[1] = cumulative tick at now
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int56 intervalSigned = int56(uint56(interval));

        // Compute average tick (floor towards negative infinity)
        int24 tick = int24(tickDelta / intervalSigned);
        if (tickDelta < 0 && (tickDelta % intervalSigned != 0)) {
            tick--; // round down
        }

        avgTick = tick;
    }

    /// @notice Returns the average tick over the TWAP interval
    function consultTick() external view returns (int24 avgTick) {
        avgTick = _getTwapTick();
    }

    /// @notice Given tokenIn and amountIn, returns expected amountOut using Uniswap V3 TWAP
    /// @dev Uses sqrtPriceX96 derived from average tick
    function consult(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        require(amountIn > 0, "OracleV3: ZERO_INPUT");

        int24 avgTick = _getTwapTick();
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(avgTick);

        if (tokenIn == token0) {
            
            // token0 → token1
            // amountOut = amountIn * (sqrtP^2 / 2^192)
            uint256 amountInX192 = FullMath.mulDiv(amountIn, sqrtPriceX96, 1 << 96);
            amountOut = FullMath.mulDiv(amountInX192, sqrtPriceX96, 1 << 96);
        } else if (tokenIn == token1) {
            // token1 → token0
            // amountOut = amountIn * (2^192 / sqrtP^2)
            uint256 amountInX96 = FullMath.mulDiv(amountIn, 1 << 96, sqrtPriceX96);
            amountOut = FullMath.mulDiv(amountInX96, 1 << 96, sqrtPriceX96);
        } else {
            revert OracleV3_InvalidToken();
        }
    }
}
