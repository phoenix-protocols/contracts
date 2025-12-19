// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockFarm
 * @notice Mock implementation of IFarm for FarmLend testing
 */
contract MockFarm {
    mapping(uint256 => uint256) public updatedAmounts;

    /// @notice Mock updateByFarmLend - called by FarmLend after liquidation
    function updateByFarmLend(uint256 tokenId, uint256 newAmount) external {
        updatedAmounts[tokenId] = newAmount;
    }

    /// @notice Get the updated amount for a tokenId
    function getUpdatedAmount(uint256 tokenId) external view returns (uint256) {
        return updatedAmounts[tokenId];
    }
}
