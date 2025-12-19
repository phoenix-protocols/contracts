// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {FarmLend_Deployer_Base} from "./base/FarmLend_Deployer_Base.sol";

contract FarmLend_Deployer is Script, FarmLend_Deployer_Base {
    function run() external {
        address admin_      = vm.envAddress("ADMIN");
        address nftManager_ = vm.envAddress("NFT_MANAGER");
        address vault_      = vm.envAddress("VAULT");
        address pusdOracle_ = vm.envAddress("PUSD_ORACLE");
        address farm_       = vm.envAddress("FARM");

        bytes32 salt = vm.envBytes32("SALT");

        vm.startBroadcast();
        address farmLendAddr = address(_deployFarmLend(admin_, nftManager_, vault_, pusdOracle_, farm_, salt));
        vm.stopBroadcast();

        console.log("FarmLend proxy address:", farmLendAddr);

        // If you want to upgrade, please uncomment the following line
        // upgrade();
    }

    function upgrade() external {
        address proxyAddr = vm.envAddress("FARMLEND_PROXY");

        bytes memory initData = ""; // If you have reinitializer, you can encode it here

        vm.startBroadcast();
        address farmLendAddr = address(_upgradeFarmLend(proxyAddr, initData));
        vm.stopBroadcast();

        console.log("FarmLend proxy address:", proxyAddr);
        console.log("FarmLend upgraded, new impl deployed");
    }
}
