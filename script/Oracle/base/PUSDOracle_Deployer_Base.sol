// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PUSDOracleUpgradeable} from "src/Oracle/PUSDOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// New contract for upgrade or you can import from other file
contract PUSDOracleV2 is PUSDOracleUpgradeable {
    uint256 public version;

    function setVersion(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        version = v;
    }
}

abstract contract PUSDOracle_Deployer_Base {
    function _deploy(address vault_, address pusdToken_, address admin_, bytes32 salt) internal returns (PUSDOracleUpgradeable oracle) {
        PUSDOracleUpgradeable impl = new PUSDOracleUpgradeable();

        bytes memory initData = abi.encodeCall(
            PUSDOracleUpgradeable.initialize,
            (
                vault_,
                pusdToken_,
                admin_
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(impl), initData);

        oracle = PUSDOracleUpgradeable(address(proxy));
    }

    // UUPS upgrade
    function _upgrade(address proxyAddr, bytes memory initData) internal returns (PUSDOracleV2 oracleV2) {
        PUSDOracleV2 implV2 = new PUSDOracleV2();

        PUSDOracleUpgradeable proxy = PUSDOracleUpgradeable(proxyAddr);

        proxy.upgradeToAndCall(address(implV2), initData);

        oracleV2 = PUSDOracleV2(proxyAddr);
    }
}
