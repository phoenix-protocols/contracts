// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStakingVault
 * @notice Interface for the StakingVault contract
 * @dev Manages staked PUSD principal and reward reserves separately from Treasury (Vault)
 */
interface IStakingVault {
    /* ========== Events ========== */
    
    event StakeDeposited(address indexed from, uint256 amount, uint256 totalStaked);
    event StakeWithdrawn(address indexed to, uint256 amount, uint256 totalStaked);
    event RewardReserveAdded(address indexed from, uint256 amount, uint256 newTotal);
    event RewardReserveWithdrawn(address indexed to, uint256 amount, uint256 newTotal);
    event RewardDistributed(address indexed to, uint256 amount, uint256 remaining);
    event RewardCompounded(uint256 amount, uint256 remaining);
    event InsufficientRewardReserve(uint256 required, uint256 available);
    event FarmUpdated(address indexed oldFarm, address indexed newFarm);

    /* ========== Stake Principal Management ========== */

    /**
     * @notice Deposit PUSD stake from user
     * @dev Only callable by Farm contract
     * @param from User address (must have approved this contract)
     * @param amount Amount to deposit
     */
    function depositStake(address from, uint256 amount) external;

    /**
     * @notice Withdraw staked PUSD to user
     * @dev Only callable by Farm contract
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawStake(address to, uint256 amount) external;

    /* ========== Reward Reserve Management ========== */

    /**
     * @notice Add PUSD to reward reserve
     * @dev Caller must approve this contract first
     * @param amount Amount to add
     */
    function addRewardReserve(uint256 amount) external;

    /**
     * @notice Withdraw from reward reserve (emergency)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawRewardReserve(address to, uint256 amount) external;

    /**
     * @notice Distribute reward to user (for unstake)
     * @dev Only callable by Farm contract
     * @param to Recipient address
     * @param amount Reward amount
     * @return success Whether distribution succeeded
     */
    function distributeReward(address to, uint256 amount) external returns (bool success);

    /**
     * @notice Compound reward into stake (for renewal)
     * @dev Only callable by Farm contract. Decreases rewardReserve, increases totalStaked
     * @param amount Reward amount to compound
     * @return success Whether compound succeeded
     */
    function compoundReward(uint256 amount) external returns (bool success);

    /* ========== View Functions ========== */

    /**
     * @notice Get total staked PUSD amount
     * @return Total staked amount
     */
    function getTotalStaked() external view returns (uint256);

    /**
     * @notice Get current reward reserve balance
     * @return Reward reserve amount
     */
    function getRewardReserve() external view returns (uint256);

    /**
     * @notice Get PUSD token address
     * @return PUSD token address
     */
    function pusdToken() external view returns (address);

    /**
     * @notice Get Farm contract address
     * @return Farm contract address
     */
    function farm() external view returns (address);
}
