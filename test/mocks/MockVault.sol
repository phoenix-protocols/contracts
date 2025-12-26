// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockVault
 * @notice Mock implementation of IVault for testing
 */
contract MockVault {
    bool private _paused;
    uint256 public lastHeartbeat;
    IERC20 public pusdToken;

    constructor() {}
    
    /// @notice Initialize with PUSD token (for Farm tests)
    function initialize(address _pusd) external {
        pusdToken = IERC20(_pusd);
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function pause() external {
        _paused = true;
    }

    function unpause() external {
        _paused = false;
    }

    function heartbeat() external {
        lastHeartbeat = block.timestamp;
    }

    // Helper function for test assertions
    function isPaused() external view returns (bool) {
        return _paused;
    }

    /// @notice Mock distributeReward - just transfer PUSD to recipient
    function distributeReward(address to, uint256 amount) external returns (bool) {
        if (address(pusdToken) != address(0) && pusdToken.balanceOf(address(this)) >= amount) {
            pusdToken.transfer(to, amount);
            return true;
        }
        return false;
    }
    
    /// @notice Mock withdrawPUSDTo - transfer PUSD to recipient
    function withdrawPUSDTo(address to, uint256 amount) external {
        if (address(pusdToken) != address(0) && pusdToken.balanceOf(address(this)) >= amount) {
            pusdToken.transfer(to, amount);
        }
    }
    
    /// @notice Mock getRewardReserve
    function getRewardReserve() external view returns (uint256) {
        if (address(pusdToken) == address(0)) return 0;
        return pusdToken.balanceOf(address(this));
    }

    /// @notice Mock withdrawTo - for FarmLend
    function withdrawTo(address to, address token, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }

    /// @notice Mock depositFor - for FarmLend
    function depositFor(address from, address token, uint256 amount) external {
        IERC20(token).transferFrom(from, address(this), amount);
    }

    /// @notice Mock releaseNFT - for FarmLend
    function releaseNFT(uint256 /*tokenId*/, address /*to*/) external {
        // Mock: In real impl this would transfer NFT back
    }

    /// @notice Mock addFee - for FarmLend fee recording
    function addFee(address /*token*/, uint256 /*amount*/) external {
        // Mock: In real impl this would record fees
    }
}
