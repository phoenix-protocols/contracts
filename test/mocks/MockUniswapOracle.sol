// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockUniswapOracle
 * @notice Mock implementation of IUniswapOracle for testing
 */
contract MockUniswapOracle {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public timestamps;

    function setPrice(address token, uint256 price, uint256 timestamp) external {
        prices[token] = price;
        timestamps[token] = timestamp;
    }

    function twapPrice1e18(address token) external view returns (uint256 price, uint256 timestamp) {
        return (prices[token], timestamps[token]);
    }
}
