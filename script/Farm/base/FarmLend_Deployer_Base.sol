// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FarmLend} from "src/Farm/FarmLend.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// New contract for upgrade testing
contract FarmLendV2 is FarmLend {
    uint256 public version;

    function setVersion(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        version = v;
    }
}

abstract contract FarmLend_Deployer_Base {
    /**
     * @notice Deploy FarmLend contract with proxy
     * @param admin_ Administrator address
     * @param nftManager_ NFTManager contract address
     * @param vault_ Vault contract address
     * @param pusdOracle_ PUSDOracle contract address
     * @param farm_ Farm contract address
     * @param salt Salt for CREATE2 deployment
     * @return farmLend Deployed FarmLend contract instance
     */
    function _deployFarmLend(
        address admin_,
        address nftManager_,
        address vault_,
        address pusdOracle_,
        address farm_,
        bytes32 salt
    ) internal returns (FarmLend farmLend) {
        FarmLend impl = new FarmLend();

        bytes memory initData = abi.encodeCall(
            FarmLend.initialize,
            (
                admin_,
                nftManager_,
                vault_,
                pusdOracle_,
                farm_
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(impl), initData);

        farmLend = FarmLend(address(proxy));
    }

    /**
     * @notice Upgrade FarmLend contract to V2
     * @param proxyAddr Existing proxy address
     * @param initData Initialization data for V2 (can be empty)
     * @return farmLend Upgraded FarmLend contract instance
     */
    function _upgradeFarmLend(address proxyAddr, bytes memory initData) internal returns (FarmLend farmLend) {
        FarmLend impl = new FarmLend();

        FarmLend proxy = FarmLend(proxyAddr);

        proxy.upgradeToAndCall(address(impl), initData);

        farmLend = FarmLend(proxyAddr);
    }
}
