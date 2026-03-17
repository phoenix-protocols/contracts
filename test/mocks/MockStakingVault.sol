// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockStakingVault
 * @notice Mock implementation of IStakingVault for testing
 */
contract MockStakingVault {
    IERC20 public pusdToken;
    uint256 public totalStaked;
    uint256 public rewardReserve;

    constructor() {}

    /// @notice Initialize with PUSD token
    function initialize(address _pusd) external {
        pusdToken = IERC20(_pusd);
    }

    /// @notice Deposit stake from user
    function depositStake(address from, uint256 amount) external {
        if (address(pusdToken) != address(0)) {
            pusdToken.transferFrom(from, address(this), amount);
        }
        totalStaked += amount;
    }

    /// @notice Withdraw stake to user
    function withdrawStake(address to, uint256 amount) external {
        if (address(pusdToken) != address(0) && pusdToken.balanceOf(address(this)) >= amount) {
            pusdToken.transfer(to, amount);
        }
        if (totalStaked >= amount) {
            totalStaked -= amount;
        }
    }

    /// @notice Add reward reserve
    function addRewardReserve(uint256 amount) external {
        if (address(pusdToken) != address(0)) {
            pusdToken.transferFrom(msg.sender, address(this), amount);
        }
        rewardReserve += amount;
    }

    /// @notice Withdraw reward reserve
    function withdrawRewardReserve(address to, uint256 amount) external {
        if (rewardReserve >= amount) {
            rewardReserve -= amount;
            if (address(pusdToken) != address(0)) {
                pusdToken.transfer(to, amount);
            }
        }
    }

    /// @notice Distribute reward to user
    function distributeReward(address to, uint256 amount) external returns (bool) {
        if (rewardReserve >= amount) {
            rewardReserve -= amount;
            if (address(pusdToken) != address(0) && pusdToken.balanceOf(address(this)) >= amount) {
                pusdToken.transfer(to, amount);
            }
            return true;
        }
        return false;
    }

    /// @notice Compound reward into stake
    function compoundReward(uint256 amount) external returns (bool) {
        if (rewardReserve >= amount) {
            rewardReserve -= amount;
            totalStaked += amount;
            return true;
        }
        return false;
    }

    /// @notice Get total staked
    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }

    /// @notice Get reward reserve
    function getRewardReserve() external view returns (uint256) {
        return rewardReserve;
    }
}
