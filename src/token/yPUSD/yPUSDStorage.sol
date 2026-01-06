// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title yPUSD Storage
 * @notice Storage layout for yPUSD ERC-4626 Vault
 * @dev Yield is released linearly over time to prevent flash loan attacks
 */
contract yPUSDStorage {
    /* ========== Constants ========== */
    
    /// @notice Role for injecting yield into the vault
    bytes32 public constant YIELD_INJECTOR_ROLE = keccak256("YIELD_INJECTOR_ROLE");

    /// @notice Minimum vesting duration (1 day)
    uint256 public constant MIN_VESTING_DURATION = 1 days;

    /// @notice Maximum vesting duration (30 days)
    uint256 public constant MAX_VESTING_DURATION = 30 days;

    /* ========== Storage Variables ========== */
    
    /// @notice Maximum total supply of yPUSD shares
    uint256 public cap;

    /// @notice Timestamp when current vesting period ends
    uint256 public vestingEndTime;

    /// @notice Amount of yield being released per second
    uint256 public vestingRate;

    /// @notice Timestamp of last vesting update
    uint256 public lastVestingUpdate;

    /// @notice Total yield that has been released (accumulated)
    uint256 public releasedYield;

    /// @notice Total yield still unvested (pending release)
    uint256 public unvestedYield;

    /* ========== Events ========== */
    
    /// @notice Emitted when yield is injected into the vault
    /// @param amount Amount of yield injected
    /// @param duration Vesting duration in seconds
    /// @param vestingRate Rate of yield release per second
    event YieldAccrued(uint256 amount, uint256 duration, uint256 vestingRate);

    /// @notice Emitted when vesting state is updated
    /// @param released Amount of yield released in this update
    /// @param totalReleased Total cumulative released yield
    event VestingUpdated(uint256 released, uint256 totalReleased);

    /* ========== Storage Gap ========== */
    
    /// @dev Reserved storage space for future upgrades
    uint256[44] private __gap;
}
