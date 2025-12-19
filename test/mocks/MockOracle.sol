// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPUSDOracle} from "src/interfaces/IPUSDOracle.sol";

contract MockOracle {
    // token => price
    mapping(address => uint256) public tokenUsdPrice;
    mapping(address => uint256) public tokenPusdPrice;
    uint256 public pusdUsdPrice;

    bool public revertTokenUSD;
    bool public revertTokenPUSD;
    bool public revertPUSDUSD;

    uint256 public lastTokenPriceTimestamp = 123;
    uint256 public lastPusdPriceTimestamp = 456;

    function setTokenUSDPrice(address token, uint256 price) external {
        tokenUsdPrice[token] = price;
    }

    function setTokenPUSDPrice(address token, uint256 price) external {
        tokenPusdPrice[token] = price;
    }

    function setPUSDUSDPrice(uint256 price) external {
        pusdUsdPrice = price;
    }

    function setReverts(
        bool _revertTokenUSD,
        bool _revertTokenPUSD,
        bool _revertPUSDUSD
    ) external {
        revertTokenUSD = _revertTokenUSD;
        revertTokenPUSD = _revertTokenPUSD;
        revertPUSDUSD = _revertPUSDUSD;
    }

    function getTokenUSDPrice(address token)
        external
        view
        returns (uint256 price, uint256 timestamp)
    {
        if (revertTokenUSD) revert("oracle tokenUSD revert");
        return (tokenUsdPrice[token], lastTokenPriceTimestamp);
    }

    function getPUSDUSDPrice()
        external
        view
        returns (uint256 price, uint256 timestamp)
    {
        if (revertPUSDUSD) revert("oracle pusdUSD revert");
        return (pusdUsdPrice, lastPusdPriceTimestamp);
    }

    function getTokenPUSDPrice(address token)
        external
        view
        returns (uint256 price, uint256 timestamp)
    {
        if (revertTokenPUSD) revert("oracle tokenPUSD revert");
        return (tokenPusdPrice[token], lastTokenPriceTimestamp);
    }

    function getTokenPUSDValue(address token, uint256 amount) external view returns (uint256 value, uint256 timestamp) {
        uint256 price = tokenPusdPrice[token];
        // price is PUSD per 1 token (1e18 precision)
        // For USDT (6 decimals): value = amount * price / 1e18
        value = (amount * price) / 1e18;
        return (value, block.timestamp);
    }
    
    function getPUSDAssetValue(address token, uint256 pusdAmount) external view returns (uint256 assetAmount, uint256 timestamp) {
        uint256 price = tokenPusdPrice[token];
        // Reverse: assetAmount = pusdAmount * 1e18 / price
        assetAmount = (pusdAmount * 1e18) / price;
        return (assetAmount, block.timestamp);
    }

    function setLastTokenPriceTimestamp(uint256 ts) external {
        lastTokenPriceTimestamp = ts;
    }

    function setLastPusdPriceTimestamp(uint256 ts) external {
        lastPusdPriceTimestamp = ts;
    }
}
