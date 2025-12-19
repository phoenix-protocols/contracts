// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {PUSDOracle_Deployer_Base} from "./base/PUSDOracle_Deployer_Base.sol";

contract PUSDOracle_Deployer is Script, PUSDOracle_Deployer_Base {
    function run() external {
        address vault_     = vm.envAddress("VAULT");
        address pusdToken_ = vm.envAddress("PUSD_TOKEN");
        address admin_     = vm.envAddress("ADMIN");

        bytes32 salt = vm.envBytes32("SALT");

        vm.startBroadcast();
        address oracleAddr = address(_deploy(vault_, pusdToken_, admin_, salt));
        vm.stopBroadcast();

        console.log("PUSDOracle proxy address:", oracleAddr);

        // If you want to upgrade, please uncomment the following line
        // upgrade();
    }

    function upgrade() external {
        address proxyAddr = vm.envAddress("PUSD_ORACLE_PROXY");

        bytes memory initData = ""; // If you have reinitializer, you can encode it here

        vm.startBroadcast();
        address oracleV2Addr = address(_upgrade(proxyAddr, initData));
        vm.stopBroadcast();

        console.log("PUSDOracle proxy address:", proxyAddr);
        console.log("PUSDOracleV2 proxy address:", oracleV2Addr);
    }
}
