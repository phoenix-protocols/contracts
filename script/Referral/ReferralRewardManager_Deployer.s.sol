// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ReferralRewardManager_Deployer_Base} from "./base/ReferralRewardManager_Deployer_Base.sol";

contract ReferralRewardManager_Deployer is Script, ReferralRewardManager_Deployer_Base {
    function run() external {
        address admin_      = vm.envAddress("ADMIN");
        address ypusdToken_ = vm.envAddress("YPUSD_TOKEN");

        bytes32 salt = vm.envBytes32("SALT");

        vm.startBroadcast();
        address managerAddr = address(_deploy(admin_, ypusdToken_, salt));
        vm.stopBroadcast();

        console.log("ReferralRewardManager proxy address:", managerAddr);

        // If you want to upgrade, please uncomment the following line
        // upgrade();
    }

    function upgrade() external {
        address proxyAddr = vm.envAddress("REFERRAL_MANAGER_PROXY");

        bytes memory initData = ""; // If you have reinitializer, you can encode it here

        vm.startBroadcast();
        address managerV2Addr = address(_upgrade(proxyAddr, initData));
        vm.stopBroadcast();

        console.log("ReferralRewardManager proxy address:", proxyAddr);
        console.log("ReferralRewardManagerV2 proxy address:", managerV2Addr);
    }
}
