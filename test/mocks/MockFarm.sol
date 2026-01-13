// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockFarm
 * @notice Mock implementation of IFarm for testing
 */
contract MockFarm {
    mapping(uint256 => uint256) public updatedAmounts;

    // Lock periods and multipliers for testing anti-arbitrage rate calculation
    uint256[] private _lockPeriods;
    uint16[] private _multipliers;
    uint16 private _currentAPY;

    constructor() {
        // Default lock periods: 7d, 30d, 90d, 180d
        _lockPeriods = new uint256[](4);
        _lockPeriods[0] = 7 days;
        _lockPeriods[1] = 30 days;
        _lockPeriods[2] = 90 days;
        _lockPeriods[3] = 180 days;

        // Default multipliers: 1x, 1.2x, 1.5x, 2x
        _multipliers = new uint16[](4);
        _multipliers[0] = 10000;
        _multipliers[1] = 12000;
        _multipliers[2] = 15000;
        _multipliers[3] = 20000;

        // Default APY: 10%
        _currentAPY = 1000;
    }

    /// @notice Get the updated amount for a tokenId
    function getUpdatedAmount(uint256 tokenId) external view returns (uint256) {
        return updatedAmounts[tokenId];
    }

    /// @notice Get supported lock periods with their multipliers
    function getSupportedLockPeriodsWithMultipliers() external view returns (uint256[] memory, uint16[] memory) {
        return (_lockPeriods, _multipliers);
    }

    /// @notice Get current APY in basis points
    function currentAPY() external view returns (uint16) {
        return _currentAPY;
    }

    /// @notice Set lock periods and multipliers for testing
    function setLockPeriodsAndMultipliers(uint256[] calldata periods, uint16[] calldata mults) external {
        require(periods.length == mults.length, "Length mismatch");
        _lockPeriods = periods;
        _multipliers = mults;
    }

    /// @notice Set current APY for testing
    function setCurrentAPY(uint16 apy) external {
        _currentAPY = apy;
    }

    /// @notice Mock onNFTTransfer - called by NFTManager on transfer
    function onNFTTransfer(address, address, uint256) external pure {
        // No-op for testing
    }
}
