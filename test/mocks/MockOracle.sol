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
}
