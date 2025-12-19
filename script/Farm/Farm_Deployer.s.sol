// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Farm_Deployer_Base} from "./base/Farm_Deployer_Base.sol";

contract Farm_Deployer is Script, Farm_Deployer_Base {
    function run() external {
        address admin_      = vm.envAddress("ADMIN");
        address pusdToken_  = vm.envAddress("PUSD_TOKEN");
        address ypusdToken_ = vm.envAddress("YPUSD_TOKEN");
        address vault_      = vm.envAddress("VAULT");

        bytes32 salt = vm.envBytes32("SALT");

        vm.startBroadcast();
        address farmAddr = address(_deploy(admin_, pusdToken_, ypusdToken_, vault_, salt));
        vm.stopBroadcast();

        console.log("Farm proxy address:", farmAddr);

        // If you want to upgrade, please uncomment the following line
        // upgrade();
    }

    function upgrade() external {
        address proxyAddr = vm.envAddress("FARM_PROXY");

        bytes memory initData = ""; // If you have reinitializer, you can encode it here

        vm.startBroadcast();
        address farmV2Addr = address(_upgrade(proxyAddr, initData));
        vm.stopBroadcast();

        console.log("Farm proxy address:", proxyAddr);
        console.log("Farm upgraded, new impl deployed");
    }
}
