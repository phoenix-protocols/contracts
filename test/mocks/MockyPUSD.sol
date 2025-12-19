// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockyPUSD
 * @notice Mock yPUSD for Farm unit tests
 */
contract MockyPUSD is ERC20 {
    IERC20 public pusd;
    uint8 private _decimals;
    
    constructor(address _pusd) ERC20("Mock yPUSD", "myPUSD") {
        pusd = IERC20(_pusd);
        _decimals = 6;
    }
    
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
    
    /// @notice Mock deposit - just mint yPUSD 1:1
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        pusd.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1 for simplicity
        _mint(receiver, shares);
    }
    
    /// @notice Mock withdraw
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = assets;
        _burn(owner, shares);
        pusd.transfer(receiver, assets);
    }
    
    /// @notice Mock redeem
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = shares; // 1:1
        _burn(owner, shares);
        pusd.transfer(receiver, assets);
    }
    
    /// @notice Mock convertToShares
    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets; // 1:1
    }
    
    /// @notice Mock convertToAssets
    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1
    }
    
    /// @notice Get underlying asset
    function asset() external view returns (address) {
        return address(pusd);
    }
}
