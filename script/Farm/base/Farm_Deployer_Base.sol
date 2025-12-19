// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FarmUpgradeable} from "src/Farm/Farm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// New contract for upgrade or you can import from other file
contract FarmUpgradeableV2 is FarmUpgradeable {
    uint256 public version;

    function setVersion(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        version = v;
    }
}

abstract contract Farm_Deployer_Base {
    /**
     * @notice Deploy Farm contract with proxy
     * @param admin_ Administrator address
     * @param pusdToken_ PUSD token contract address
     * @param ypusdToken_ yPUSD token contract address
     * @param vault_ Vault contract address
     * @param salt Salt for CREATE2 deployment
     * @return farm Deployed Farm contract instance
     */
    function _deploy(
        address admin_,
        address pusdToken_,
        address ypusdToken_,
        address vault_,
        bytes32 salt
    ) internal returns (FarmUpgradeable farm) {
        FarmUpgradeable impl = new FarmUpgradeable();

        bytes memory initData = abi.encodeCall(
            FarmUpgradeable.initialize,
            (
                admin_,
                pusdToken_,
                ypusdToken_,
                vault_
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(impl), initData);

        farm = FarmUpgradeable(address(proxy));
    }

    /**
     * @notice Upgrade Farm contract to V2
     * @param proxyAddr Existing proxy address
     * @param initData Initialization data for V2 (can be empty)
     * @return farmV2 Upgraded Farm V2 contract instance
     */
    function _upgrade(address proxyAddr, bytes memory initData) internal returns (FarmUpgradeable farmV2) {
        // Deploy new implementation
        FarmUpgradeable implV2 = new FarmUpgradeable();

        FarmUpgradeable proxy = FarmUpgradeable(proxyAddr);

        proxy.upgradeToAndCall(address(implV2), initData);

        farmV2 = FarmUpgradeable(proxyAddr);
    }
}
