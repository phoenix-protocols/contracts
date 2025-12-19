// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/Vault/Vault.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/**
 * @title UpgradeVault
 * @notice Script to upgrade Vault implementation via UUPS proxy
 * 
 * Usage:
 *   # Testnet (BSC Testnet)
 *   forge script script/Vault/UpgradeVault.s.sol:UpgradeVault \
 *     --rpc-url $RPC_BSC_TESTNET \
 *     --broadcast \
 *     --verify
 * 
 *   # Mainnet (BSC)
 *   forge script script/Vault/UpgradeVault.s.sol:UpgradeVault \
 *     --rpc-url $RPC_BSC \
 *     --broadcast \
 *     --verify
 */
contract UpgradeVault is Script {
    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address vaultProxy = vm.envAddress("VAULT");
        
        require(vaultProxy != address(0), "VAULT address not set in .env");
        
        console.log("=== Vault Upgrade ===");
        console.log("Chain ID:", block.chainid);
        console.log("Vault Proxy:", vaultProxy);
        
        // Get current implementation
        address currentImpl = _getImplementation(vaultProxy);
        console.log("Current Implementation:", currentImpl);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy new implementation
        Vault newImplementation = new Vault();
        console.log("New Implementation deployed:", address(newImplementation));
        
        // 2. Upgrade proxy to new implementation
        Vault vault = Vault(vaultProxy);
        vault.upgradeToAndCall(address(newImplementation), "");
        
        vm.stopBroadcast();
        
        // Verify upgrade
        address upgradedImpl = _getImplementation(vaultProxy);
        console.log("Upgraded Implementation:", upgradedImpl);
        
        require(upgradedImpl == address(newImplementation), "Upgrade failed!");
        console.log("=== Vault Upgrade Successful! ===");
    }
    
    function _getImplementation(address proxy) internal view returns (address) {
        // ERC1967 implementation slot
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 value = vm.load(proxy, slot);
        return address(uint160(uint256(value)));
    }
}
