// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IyPUSD Interface
 * @notice ERC-4626 tokenized vault interface for yPUSD with linear yield vesting
 * @dev Yield is released linearly over time to prevent flash loan attacks
 */
interface IyPUSD is IERC4626 {
    /* ========== Events ========== */
    
    /// @notice Emitted when yield is injected
    event YieldAccrued(uint256 amount, uint256 duration, uint256 vestingRate);
    
    /// @notice Emitted when vesting state is updated
    event VestingUpdated(uint256 released, uint256 totalReleased);

    /* ========== View Functions ========== */
    
    /// @notice Get the current exchange rate (assets per share, scaled by 1e18)
    function exchangeRate() external view returns (uint256);
    
    /// @notice Get the underlying PUSD value of a user's yPUSD holdings
    function underlyingBalanceOf(address user) external view returns (uint256);
    
    /// @notice Maximum total supply of yPUSD shares
    function cap() external view returns (uint256);
    
    /// @notice Get current vesting information
    /// @return vestingEndTime When vesting ends
    /// @return vestingRate Rate of yield release per second
    /// @return unvestedYield Amount of yield not yet released
    /// @return releasedYield Total yield released so far
    function getVestingInfo() external view returns (
        uint256 vestingEndTime,
        uint256 vestingRate,
        uint256 unvestedYield,
        uint256 releasedYield
    );

    /* ========== External Functions ========== */
    
    /// @notice Inject yield into the vault with linear release (only YIELD_INJECTOR_ROLE)
    /// @param amount Amount of PUSD to inject as yield
    /// @param duration Duration over which yield will be released (in seconds)
    function accrueYield(uint256 amount, uint256 duration) external;
    
    /// @notice Settle vesting state (anyone can call)
    function settleVesting() external;
    
    /// @notice Update the cap (only admin)
    function setCap(uint256 newCap) external;
}
