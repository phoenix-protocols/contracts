// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Vault_Deployer_Base} from "./base/Vault_Deployer_Base.sol";

contract Vault_Deployer is Script, Vault_Deployer_Base {
    function run() external {
        address admin_      = vm.envAddress("ADMIN");
        address pusdToken_  = vm.envAddress("PUSD_TOKEN");
        address nftManager_ = vm.envAddress("NFT_MANAGER");

        bytes32 salt = vm.envBytes32("SALT");

        vm.startBroadcast();
        address vaultAddr = address(_deploy(admin_, pusdToken_, nftManager_, salt));
        vm.stopBroadcast();

        console.log("Vault proxy address:", vaultAddr);

        // If you want to upgrade, please uncomment the following line
        // upgrade();
    }

    function upgrade() external{
        address proxyAddr = vm.envAddress("VAULT_PROXY");

        bytes memory initData = ""; // If you have reinitializer, you can encode it here

        vm.startBroadcast();
        address vaultV2Addr = address(_upgrade(proxyAddr, initData));
        vm.stopBroadcast();

        console.log("Vault proxy address:", proxyAddr);
        console.log("VaultV2 proxy address:", vaultV2Addr);
    }
}
