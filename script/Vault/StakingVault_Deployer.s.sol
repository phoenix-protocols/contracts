// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {StakingVault_Deployer_Base} from "./base/StakingVault_Deployer_Base.sol";

/**
 * @title StakingVault_Deployer
 * @notice Deployment script for StakingVault contract
 * @dev StakingVault holds staked PUSD principal and reward reserves separately from Treasury
 *
 * Environment Variables:
 *   ADMIN - Admin address
 *   PUSD_TOKEN - PUSD token address
 *   FARM - Farm contract address
 *   SALT - Deployment salt for CREATE2
 *   STAKING_VAULT - (for upgrade) Existing StakingVault proxy address
 */
contract StakingVault_Deployer is Script, StakingVault_Deployer_Base {
    function run() external {
        address admin = vm.envAddress("ADMIN");
        address pusdToken = vm.envAddress("PUSD_TOKEN");
        address farm = vm.envAddress("FARM");
        bytes32 salt = vm.envBytes32("SALT");

        console.log("=== StakingVault Deployment ===");
        console.log("Admin:", admin);
        console.log("PUSD Token:", pusdToken);
        console.log("Farm:", farm);

        vm.startBroadcast();
        address stakingVaultAddr = address(_deploy(admin, pusdToken, farm, salt));
        vm.stopBroadcast();

        console.log("StakingVault proxy deployed at:", stakingVaultAddr);
        console.log("");
        console.log("Post-deployment actions:");
        console.log("1. Call farm.setStakingVault(stakingVault)");
        console.log("2. Add reward reserve: stakingVault.addRewardReserve(amount)");
    }

    function upgrade() external {
        address proxyAddr = vm.envAddress("STAKING_VAULT");
        bytes32 salt = vm.envBytes32("SALT");

        bytes memory initData = ""; // If you have reinitializer, encode it here

        vm.startBroadcast();
        address stakingVaultV2Addr = address(_upgrade(proxyAddr, initData, salt));
        vm.stopBroadcast();

        console.log("StakingVault proxy address:", proxyAddr);
        console.log("StakingVaultV2 implementation upgraded");
    }
}
