// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {yPUSD} from "src/token/yPUSD/yPUSD.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract yPUSD_Deployer_Base {
    function _deploy(IERC20 pusd_, uint256 cap_, address admin_, bytes32 salt) internal returns (yPUSD token) {
        yPUSD impl = new yPUSD();

        bytes memory initData = abi.encodeCall(
            yPUSD.initialize,
            (
                pusd_,
                cap_, 
                admin_
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(impl), initData);

        token = yPUSD(address(proxy));
    }

    // UUPS upgrade
    function _upgrade(address proxyAddr, bytes memory initData) internal returns (yPUSD tokenNew) {
        yPUSD implNew = new yPUSD();

        yPUSD proxy = yPUSD(proxyAddr); // old version

        proxy.upgradeToAndCall(address(implNew), initData);

        tokenNew = yPUSD(proxyAddr);
    }
}
