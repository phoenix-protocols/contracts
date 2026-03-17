// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StakingVault} from "src/Vault/StakingVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// New contract for upgrade
contract StakingVaultV2 is StakingVault {
    uint256 public version;

    function setVersion(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        version = v;
    }
}

abstract contract StakingVault_Deployer_Base {
    function _deploy(
        address admin_,
        address pusdToken_,
        address farm_,
        bytes32 salt
    ) internal returns (StakingVault stakingVault) {
        // Use CREATE2 for impl to ensure same address across all chains
        bytes32 implSalt = keccak256(abi.encodePacked(salt, "STAKING_VAULT_IMPL"));
        StakingVault impl = new StakingVault{salt: implSalt}();

        bytes memory initData = abi.encodeCall(
            StakingVault.initialize,
            (admin_, pusdToken_, farm_)
        );

        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(impl), initData);

        stakingVault = StakingVault(address(proxy));
    }

    // UUPS
    function _upgrade(address proxyAddr, bytes memory initData, bytes32 salt) internal returns (StakingVaultV2 stakingVaultV2) {
        // Use CREATE2 for impl to ensure same address across all chains
        bytes32 implSalt = keccak256(abi.encodePacked(salt, "STAKING_VAULT_V2_IMPL"));
        StakingVaultV2 implV2 = new StakingVaultV2{salt: implSalt}();

        StakingVault proxy = StakingVault(proxyAddr);

        proxy.upgradeToAndCall(address(implV2), initData);

        stakingVaultV2 = StakingVaultV2(proxyAddr);
    }
}
