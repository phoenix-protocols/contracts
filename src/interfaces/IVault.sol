// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVault {
    function depositFor(address user, address asset, uint256 amount) external;

    function withdrawTo(address user, address asset, uint256 amount) external;

    function addFee(address asset, uint256 amount) external;

    function getTVL(address asset) external view returns (uint256 tvl, uint256 marketValue);

    function getTotalTVL() external view returns (uint256 totalTVL);

    function getPUSDMarketCap() external view returns (uint256 pusdMarketCap);

    function isValidAsset(address asset) external view returns (bool);

    function getTokenPUSDValue(address asset, uint256 amount) external view returns (uint256 pusdAmount, uint256 referenceTimestamp);

    function getPUSDAssetValue(address asset, uint256 pusdAmount) external view returns (uint256 amount, uint256 referenceTimestamp);

    function pause() external view returns (bool);

    function paused() external view returns (bool);

    function unpause() external view returns (bool);

    function heartbeat() external;
}
