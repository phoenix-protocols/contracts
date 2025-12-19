// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReferralRewardManager} from "src/Referral/ReferralRewardManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// New contract for upgrade or you can import from other file
contract ReferralRewardManagerV2 is ReferralRewardManager {
    uint256 public version;

    function setVersion(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        version = v;
    }
}

abstract contract ReferralRewardManager_Deployer_Base {
    function _deploy(address admin_, address ypusdToken_, bytes32 salt) internal returns (ReferralRewardManager manager) {
        ReferralRewardManager impl = new ReferralRewardManager();

        bytes memory initData = abi.encodeCall(
            ReferralRewardManager.initialize,
            (
                admin_,
                ypusdToken_
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(impl), initData);

        manager = ReferralRewardManager(address(proxy));
    }

    // UUPS upgrade
    function _upgrade(address proxyAddr, bytes memory initData) internal returns (ReferralRewardManagerV2 managerV2) {
        ReferralRewardManagerV2 implV2 = new ReferralRewardManagerV2();

        ReferralRewardManager proxy = ReferralRewardManager(proxyAddr);

        proxy.upgradeToAndCall(address(implV2), initData);

        managerV2 = ReferralRewardManagerV2(proxyAddr);
    }
}
