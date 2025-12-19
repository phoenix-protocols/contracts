// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/Oracle/PUSDOracle.sol";

/**
 * @title UpgradeOracle
 * @notice Script to upgrade Oracle implementation via UUPS proxy
 */
contract UpgradeOracle is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address oracleProxy = vm.envAddress("ORACLE");
        
        require(oracleProxy != address(0), "ORACLE address not set in .env");
        
        console.log("=== Oracle Upgrade ===");
        console.log("Chain ID:", block.chainid);
        console.log("Oracle Proxy:", oracleProxy);
        
        address currentImpl = _getImplementation(oracleProxy);
        console.log("Current Implementation:", currentImpl);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy new implementation
        PUSDOracleUpgradeable newImplementation = new PUSDOracleUpgradeable();
        console.log("New Implementation deployed:", address(newImplementation));
        
        // Upgrade proxy
        PUSDOracleUpgradeable oracle = PUSDOracleUpgradeable(oracleProxy);
        oracle.upgradeToAndCall(address(newImplementation), "");
        
        vm.stopBroadcast();
        
        address upgradedImpl = _getImplementation(oracleProxy);
        console.log("Upgraded Implementation:", upgradedImpl);
        
        require(upgradedImpl == address(newImplementation), "Upgrade failed!");
        console.log("=== Oracle Upgrade Successful! ===");
    }
    
    function _getImplementation(address proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 value = vm.load(proxy, slot);
        return address(uint160(uint256(value)));
    }
}
