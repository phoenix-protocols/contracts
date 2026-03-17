// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vault} from "src/Vault/Vault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// import {VaultV2} from "";
// New contract for upgrade or you can import from other file
contract VaultV2 is Vault {
    uint256 public version;

    function setVersion(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        version = v;
    }
}

abstract contract Vault_Deployer_Base {
    function _deploy(address admin_, address pusdToken_, address nftManager_, bytes32 salt) internal returns (Vault vault) {
        // Use CREATE2 for impl to ensure same address across all chains
        bytes32 implSalt = keccak256(abi.encodePacked(salt, "VAULT_IMPL"));
        Vault impl = new Vault{salt: implSalt}();

        bytes memory initData = abi.encodeCall(
            Vault.initialize,
            (
                admin_,
                pusdToken_,
                nftManager_
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(impl), initData);

        vault = Vault(address(proxy));
    }

    // UUPS
    function _upgrade(address proxyAddr, bytes memory initData, bytes32 salt) internal returns (VaultV2 vaultV2) {
        // Use CREATE2 for impl to ensure same address across all chains
        bytes32 implSalt = keccak256(abi.encodePacked(salt, "VAULT_V2_IMPL"));
        VaultV2 implV2 = new VaultV2{salt: implSalt}();

        Vault proxy = Vault(proxyAddr);

        proxy.upgradeToAndCall(address(implV2), initData);

        vaultV2 = VaultV2(proxyAddr);
    }
}
